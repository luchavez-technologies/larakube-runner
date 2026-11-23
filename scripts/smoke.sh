#!/usr/bin/env bash
# Checks the image the way a Kubernetes Job runs it: non-root, read-only, no capabilities.
#   scripts/smoke.sh <image>
set -euo pipefail

image="${1:?image to test}"
work="$(mktemp -d)"
chmod 755 "$work"
token=smoke-test-signing-token
port=18765
server=""
cleanup() { [ -z "$server" ] || kill "$server" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT

docker run --rm --entrypoint bash "$image" -c '
    set -e
    [ "$(id -u)" = 10001 ]
    ! command -v sudo
    ! command -v gcloud
    tofu version | head -1
    kubectl version --client | head -1
    ssh -V
    larakube --version | tail -1
    commands="$(larakube list --raw)"
    for verb in cloud:create cloud:destroy cloud:ssh-keys:sync cloud:access:connect cloud:access:disconnect; do
        grep -q "^$verb " <<< "$commands" || { echo "missing command: $verb" >&2; exit 1; }
    done
'

cat > "$work/larakube" <<'FAKE'
#!/bin/sh
echo "progress on stderr" >&2
case "$1" in
    cloud:create)
        key=""
        for arg in "$@"; do case "$arg" in --key=*) key="${arg#--key=}" ;; esac; done
        [ -f "$key" ] || exit 9
        [ -z "${LARAKUBE_CALLBACK_TOKEN:-}" ] || exit 8
        case " $* " in
            *" --stack-name=no-context "*) printf '{"success":true}\n' ;;
            *) printf 'noise\n{"success":true,"context":"example","kubeconfig":"FAKE-CREDENTIAL-VALUE"}\n' ;;
        esac
        ;;
    cloud:access:connect)
        [ "$2" = "--context=example" ] || exit 7
        printf '{"success":true,"kubeconfig":"FAKE-CREDENTIAL-VALUE"}\n'
        ;;
    cloud:destroy) echo '{"success":false,"error":"boom"}'; exit 3 ;;
    *) exit 0 ;;
esac
FAKE
chmod 755 "$work/larakube"

cat > "$work/server.py" <<'PY'
import hashlib, hmac, http.server, json, sys
token = sys.argv[1].encode()
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        stamp = self.headers["X-LaraKube-Timestamp"]
        expected = "sha256=" + hmac.new(token, stamp.encode() + b"." + body, hashlib.sha256).hexdigest()
        ok = hmac.compare_digest(expected, self.headers["X-LaraKube-Signature"])
        data = json.loads(body)
        print(json.dumps({"ok": ok, "verb": data["verb"], "exit": data["exitCode"], "success": data["result"].get("success"), "access": (data["result"].get("access") or {}).get("success")}), flush=True)
        self.send_response(204 if ok else 401)
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.ThreadingHTTPServer(("0.0.0.0", int(sys.argv[2])), Handler).serve_forever()
PY
python3 -I "$work/server.py" "$token" "$port" > "$work/received" &
server=$!
sleep 1

run() {
    docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges \
        --tmpfs /tmp:mode=1777 --tmpfs /home/runner:uid=10001,gid=10001,mode=700 \
        --add-host callback.svc.cluster.local:host-gateway \
        -v "$work/larakube:/usr/local/bin/larakube:ro" \
        -e "LARAKUBE_CALLBACK_URL=${url:-http://callback.svc.cluster.local:$port/result}" \
        -e "LARAKUBE_CALLBACK_TOKEN=$token" -e LARAKUBE_READ_ACCESS=true "$image" "$@"
}
expect() {
    local want="$1"; shift
    local got=0
    "$@" > "$work/output" 2>&1 || got=$?
    [ "$got" = "$want" ] || { echo "expected exit $want, got $got: $*" >&2; cat "$work/output" >&2; exit 1; }
}

expect 64 run plex:remove
url=http://example.com/result expect 64 run cloud:destroy
expect 0 run cloud:create --provider=gcp
if grep -q FAKE-CREDENTIAL "$work/output"; then echo "a credential reached the pod log" >&2; exit 1; fi
expect 0 run cloud:create --stack-name=no-context
expect 3 run cloud:destroy
expect 70 run cloud:access:disconnect

python3 -I - "$work/received" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
want = [("cloud:create", 0, True, True), ("cloud:create", 0, True, False), ("cloud:destroy", 3, False, None), ("cloud:access:disconnect", 70, False, None)]
got = [(r["verb"], r["exit"], r["success"], r["access"]) for r in rows]
assert all(r["ok"] for r in rows) and got == want, got
PY

echo "Smoke test passed."

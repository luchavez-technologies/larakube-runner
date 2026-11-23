#!/usr/bin/env bash
# Runs one allow-listed LaraKube CLI verb, keeps stdout (which can hold credentials) out of the
# pod log, and posts the JSON result to a signed callback.
set -euo pipefail
umask 077

fail() { echo "larakube-runner: $1" >&2; exit 64; }

verb="${1:-}"
[ "$#" -gt 0 ] && shift

case "$verb" in
    cloud:create | cloud:destroy | cloud:ssh-keys:sync | cloud:access:connect | cloud:access:disconnect) ;;
    *) fail "verb not allowed: ${verb:-none}" ;;
esac

callback_url="${LARAKUBE_CALLBACK_URL:-}"
callback_token="${LARAKUBE_CALLBACK_TOKEN:-}"
[ -n "$callback_token" ] || fail "LARAKUBE_CALLBACK_TOKEN is required"
unset LARAKUBE_CALLBACK_TOKEN

case "$callback_url" in
    https://*) ;;
    http://*.svc.cluster.local:* | http://*.svc.cluster.local/*) ;;
    *) fail "LARAKUBE_CALLBACK_URL must be https, or http inside the cluster" ;;
esac

work="$(mktemp -d /tmp/larakube-job.XXXXXX)"
trap 'rm -rf "$work"' EXIT
cd "$work"

if [ "$verb" = "cloud:create" ]; then
    ssh-keygen -q -t ed25519 -N '' -C larakube-provisioning -f "$work/provisioning"
    set -- "$@" "--key=$work/provisioning"
fi

set +e
larakube "$verb" "$@" --json --no-interaction > "$work/stdout"
exit_code=$?
set -e

if ! tail -n 1 "$work/stdout" | jq -ce 'type == "object"' > /dev/null 2>&1; then
    printf '{"success":false,"error":"The command produced no result."}\n' > "$work/stdout"
    [ "$exit_code" -ne 0 ] || exit_code=70
fi
tail -n 1 "$work/stdout" > "$work/result.json"

jq -cn --arg verb "$verb" --argjson exitCode "$exit_code" --slurpfile result "$work/result.json" \
    '{verb: $verb, exitCode: $exitCode, result: $result[0]}' > "$work/body.json"

timestamp="$(date +%s)"
signature="$( { printf '%s.' "$timestamp"; cat "$work/body.json"; } | openssl dgst -sha256 -hmac "$callback_token" -r | cut -d' ' -f1)"

if ! curl -fsS --proto '=https,http' --max-time 30 --retry 5 --retry-all-errors --retry-delay 3 \
    -H 'Content-Type: application/json' \
    -H "X-LaraKube-Timestamp: $timestamp" \
    -H "X-LaraKube-Signature: sha256=$signature" \
    --data-binary "@$work/body.json" -o /dev/null "$callback_url"; then
    echo "larakube-runner: could not deliver the result" >&2
    exit 70
fi

exit "$exit_code"

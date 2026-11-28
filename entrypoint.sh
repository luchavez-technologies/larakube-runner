#!/usr/bin/env bash
# Runs one allow-listed LaraKube CLI verb, keeps stdout (which can hold credentials) out of the
# pod log, and posts the JSON result to a signed callback.
set -euo pipefail
umask 077

fail() { echo "larakube-runner: $1" >&2; exit 64; }

verb="${1:-}"
[ "$#" -gt 0 ] && shift

case "$verb" in
    cloud:create | cloud:init | cloud:destroy | cloud:ssh-keys:sync | cloud:access:connect | cloud:access:disconnect | cloud:apps:install | cloud:apps:remove) ;;
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

# The LaraKube CLI's global email, as Desktop sets it: Traefik's Let's Encrypt account on a new server.
if [ -n "${LARAKUBE_ADMIN_EMAIL:-}" ]; then
    larakube config "--email=$LARAKUBE_ADMIN_EMAIL" > /dev/null 2>&1 || fail "the admin email could not be saved"
fi

if [ "$verb" = "cloud:create" ]; then
    ssh-keygen -q -t ed25519 -N '' -C larakube-provisioning -f "$work/provisioning"
    set -- "$@" "--key=$work/provisioning"
fi

# An existing server: LaraKube Cloud hands over a one-off key in the job's files Secret, mounted
# group-readable. ssh refuses a key others can read, so it is copied here, readable by this user only.
if [ "$verb" = "cloud:init" ]; then
    args=()
    for arg in "$@"; do
        case "$arg" in
            --ssh-key=*)
                src="${arg#--ssh-key=}"
                [ -f "$src" ] || fail "the SSH key for the existing server is missing"
                install -m 600 "$src" "$work/existing-server"
                args+=("--ssh-key=$work/existing-server")
                ;;
            *) args+=("$arg") ;;
        esac
    done
    set -- "${args[@]}"
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

# The admin kubeconfig only exists inside this job, so read access is created before it ends.
# A failure here is reported under `access` because the server itself was still created.
if { [ "$verb" = "cloud:create" ] || [ "$verb" = "cloud:init" ]; } && [ "$exit_code" -eq 0 ] && [ "${LARAKUBE_READ_ACCESS:-}" = "true" ]; then
    context="$(jq -r '.context // empty' "$work/result.json")"
    printf '{"success":false,"error":"Read access could not be set up."}\n' > "$work/access.json"
    if [ -n "$context" ]; then
        set +e
        larakube cloud:access:connect "--context=$context" --json --no-interaction > "$work/access.out"
        set -e
        if tail -n 1 "$work/access.out" | jq -ce 'type == "object"' > /dev/null 2>&1; then
            tail -n 1 "$work/access.out" > "$work/access.json"
        fi
    fi
    jq -c --slurpfile access "$work/access.json" '. + {access: $access[0]}' "$work/result.json" > "$work/merged.json"
    mv "$work/merged.json" "$work/result.json"
fi

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

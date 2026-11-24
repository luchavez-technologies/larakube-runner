#!/usr/bin/env bash
# Local-only helpers for the development runner (Dockerfile.dev). Nothing here is pushed anywhere.
#
#   scripts/dev.sh build [--cli=PATH] [--without=app1,app2]
#       Builds larakube-runner:dev from a LaraKube CLI checkout (default: ../cli). --without drops those
#       apps' built-in templates, so the runner must download them, and tags the image
#       larakube-runner:dev-no-<apps>.
#
#   scripts/dev.sh test-fetch <app> [--image=TAG] [--key=KEY_ID:BASE64_PUBLIC_KEY]
#       Runs `templates:fetch <app>` in a pod shaped like a real runner Job (same namespace, user,
#       read-only root filesystem) against local LaraKube Cloud. The key defaults to
#       LARAKUBE_RUNNER_DEV_TEMPLATE_KEY from ../cloud/.env.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
context="${KUBE_CONTEXT:-orbstack}"
namespace="${LARAKUBE_JOBS_NAMESPACE:-larakube-jobs}"
cloud_url="${LARAKUBE_RUNNER_CLOUD_URL:-http://web.cloud-local.svc.cluster.local}"

fail() { echo "dev.sh: $1" >&2; exit 1; }

build() {
    local cli="$here/../cli" without="" tag="larakube-runner:dev"
    for arg in "$@"; do
        case "$arg" in
            --cli=*) cli="${arg#--cli=}" ;;
            --without=*) without="${arg#--without=}" ;;
            *) fail "unknown option $arg" ;;
        esac
    done
    [ -f "$cli/larakube" ] || fail "$cli is not a LaraKube CLI checkout"
    [ -d "$cli/vendor" ] || fail "$cli has no vendor folder; run composer install there first"

    local copy
    copy="$(mktemp -d)"
    trap 'rm -rf "$copy"' RETURN

    local excludes=()
    if [ -n "$without" ]; then
        [[ "$without" =~ ^[a-z0-9,-]+$ ]] || fail "--without takes app slugs separated by commas"
        IFS=',' read -r -a apps <<< "$without"
        for app in "${apps[@]}"; do
            [ -d "$cli/resources/views/k8s/$app" ] || fail "$app has no built-in templates in $cli"
            excludes+=("--exclude=resources/views/k8s/$app")
        done
        tag="larakube-runner:dev-no-${without//,/-}"
    fi

    (cd "$cli" && rsync -a "${excludes[@]}" larakube composer.json app bootstrap config resources vendor "$copy/")
    docker build -f "$here/Dockerfile.dev" --build-context "cli=$copy" -t "$tag" "$here"
    echo "Built $tag"
}

test_fetch() {
    local app="${1:-}" image="" key=""
    [ -n "$app" ] || fail "usage: dev.sh test-fetch <app> [--image=TAG] [--key=ID:PUBLIC_KEY]"
    [[ "$app" =~ ^[a-z0-9-]+$ ]] || fail "not an app slug: $app"
    shift
    for arg in "$@"; do
        case "$arg" in
            --image=*) image="${arg#--image=}" ;;
            --key=*) key="${arg#--key=}" ;;
            *) fail "unknown option $arg" ;;
        esac
    done
    image="${image:-larakube-runner:dev-no-$app}"
    if [ -z "$key" ] && [ -f "$here/../cloud/.env" ]; then
        key="$(sed -n 's/^LARAKUBE_RUNNER_DEV_TEMPLATE_KEY=//p' "$here/../cloud/.env" | tail -n 1)"
    fi
    [ -n "$key" ] || fail "no development key: pass --key= or set LARAKUBE_RUNNER_DEV_TEMPLATE_KEY in ../cloud/.env"

    local pod="template-fetch-test"
    kubectl --context "$context" delete pod "$pod" -n "$namespace" --ignore-not-found --wait=true >/dev/null
    kubectl --context "$context" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $namespace
  labels: {app.kubernetes.io/managed-by: larakube-cloud}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, fsGroup: 10001, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: runner
      image: $image
      imagePullPolicy: Never
      command: ["sh", "-c"]
      args:
        - |
          echo "built-in $app templates: \$(test -d /opt/larakube-cli/resources/views/k8s/$app && echo present || echo absent)"
          larakube templates:fetch $app --json && larakube templates:list --json
      env:
        - {name: LARAKUBE_TEMPLATE_DEV_KEY, value: "$key"}
        - {name: LARAKUBE_CLOUD_URL, value: "$cloud_url"}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {memory: 512Mi}}
      volumeMounts: [{name: tmp, mountPath: /tmp}, {name: home, mountPath: /home/runner}]
  volumes: [{name: tmp, emptyDir: {}}, {name: home, emptyDir: {}}]
YAML
    trap 'kubectl --context "$context" delete pod "$pod" -n "$namespace" --wait=false >/dev/null 2>&1 || true' RETURN

    local phase=""
    for _ in $(seq 1 60); do
        phase="$(kubectl --context "$context" get pod "$pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        case "$phase" in Succeeded | Failed) break ;; esac
        sleep 2
    done
    kubectl --context "$context" logs "$pod" -n "$namespace"
    [ "$phase" = "Succeeded" ] || fail "the fetch did not succeed (pod phase: ${phase:-unknown})"
    echo "Fetched and verified $app inside a runner pod."
}

case "${1:-}" in
    build) shift; build "$@" ;;
    test-fetch) shift; test_fetch "$@" ;;
    *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac

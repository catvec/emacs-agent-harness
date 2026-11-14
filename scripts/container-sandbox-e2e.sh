#!/usr/bin/env bash
# Run a compose stack inside a real Harness sandbox, end to end.
#
#   scripts/container-sandbox-e2e.sh [DIR]
#
# The sandbox is the one `sandbox/wrap' builds for a container command
# (`:containers' t), so what this exercises is the harness's own jail and
# not a hand-written bwrap line.  It starts a service, waits until it
# answers, reaches it from a second container on the stack's network,
# removes the stack and checks that no container and no network is left.
#
# DIR is where the compose file is written (a fresh temporary directory by
# default); its output, and the exact commands, are printed as they run.
#
# It needs a Docker daemon the harness can reach.  Inside a sandbox that
# has none it says which stage is missing and exits 3, so a caller can tell
# "the sandbox cannot" from "the stack failed".
#
# Exit: 0 the stack started, answered, was reached and was removed;
#       1 the stack failed; 3 the sandbox cannot run one (with the stage).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${1:-$(mktemp -d "${TMPDIR:-/tmp}/harness-container-e2e.XXXXXX")}
NAME=$(basename "$WORK")
KEEP=${KEEP:-}
if [ -z "${KEEP:-}" ]; then
  trap 'rm -rf "$WORK"' EXIT
fi

mkdir -p "$WORK"
cat > "$WORK/docker-compose.yml" <<'YAML'
services:
  web:
    image: busybox:latest
    command: ["sh", "-c", "mkdir -p /www && echo READY > /www/index.html && httpd -f -p 8080 -h /www"]
  client:
    image: busybox:latest
    profiles: ["tools"]
    command: ["true"]
YAML

cat > "$WORK/run.sh" <<'SCRIPT'
set -u
P="docker compose -p harness-e2e -f docker-compose.yml"
step() { printf '\n== %s\n' "$*"; }
fail() { printf '\nE2E-FAIL: %s\n' "$*"; exit 1; }

step "engine"
docker info --format 'server={{.ServerVersion}} driver={{.Driver}}' || fail "no engine"

step "up"
$P up -d || fail "compose up"

step "readiness"
ready=
for i in $(seq 1 60); do
  if $P exec -T web wget -qO- http://127.0.0.1:8080/ 2>/dev/null | grep -q READY; then
    ready=$i; break
  fi
  sleep 1
done
[ -n "$ready" ] || fail "the service never answered"
printf 'answered after %ss\n' "$ready"

step "reachability from another container"
out=$($P --profile tools run --rm --entrypoint sh client \
        -c 'wget -qO- http://web:8080/ 2>&1' 2>&1 | tail -3)
printf '%s\n' "$out"
printf '%s' "$out" | grep -q READY || fail "a second container could not reach the service"

step "teardown"
$P down -v --remove-orphans || fail "compose down"

step "cleanup"
left_containers=$(docker ps -a --filter label=com.docker.compose.project=harness-e2e --format '{{.Names}}' | wc -l)
left_networks=$(docker network ls --filter label=com.docker.compose.project=harness-e2e --format '{{.Name}}' | wc -l)
printf 'containers=%s networks=%s\n' "$left_containers" "$left_networks"
[ "$left_containers" -eq 0 ] || fail "containers left behind"
[ "$left_networks" -eq 0 ] || fail "networks left behind"

printf '\nE2E-OK\n'
SCRIPT

HARNESS_E2E_WORK="$WORK" emacs -Q --batch \
  -L "$ROOT/lisp" -L "$ROOT/lisp/modules" \
  -l harness-core -l harness-util -l harness-config -l harness-sandbox \
  --eval '(progn
             (setq harness-sandbox--backend (quote bwrap))
             (setq harness-sandbox--programs (quote ((bwrap . "/usr/bin/bwrap"))))
             (let ((probe (harness-sandbox--container-probe)))
               (unless (plist-get probe :ok)
                 (princ (format "sandbox-unavailable: %s: %s\n"
                                (plist-get probe :stage) (plist-get probe :why)))
                 (kill-emacs 3)))
             (let* ((cwd (getenv "HARNESS_E2E_WORK"))
                    (script "sh run.sh")
                    (argv (harness-sandbox--bwrap-command
                           "/usr/bin/bwrap" cwd (list "/usr/bin/sh" "-c" script)
                           :containers t)))
               (princ (format "sandbox: %s\n\n" (string-join argv " ")))
               (let ((out (with-temp-buffer
                            (apply (quote call-process) (car argv) nil t nil (cdr argv))
                            (buffer-string))))
                 (princ out)
                 (kill-emacs (if (string-match-p "E2E-OK" out) 0 1)))))' \
  2>&1
exit $?

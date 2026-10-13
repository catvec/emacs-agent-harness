#!/usr/bin/env bash
# Byte-compile every source file out of tree and fail on errors.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
files=(harness.el lisp/*.el lisp/modules/*.el lisp/ui/*.el)
# The libraries vendored under lisp/vendor, a directory each: on the load
# path, and compiled with the rest, but not their tests (lisp/vendor/README.md).
vendored=()
for dir in lisp/vendor/*/; do
  [ -d "$dir" ] || continue
  vendored+=(-L "${dir%/}")
  for f in "$dir"*.el; do
    [ -f "$f" ] || continue
    case "$f" in *-test.el) ;; *) files+=("$f") ;; esac
  done
done
# A compile that wedges (a macro looping, an Emacs stuck in C) must not
# hang the script forever.
TIMEOUT=${HARNESS_LINT_TIMEOUT:-900}
timeout "$TIMEOUT" emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui ${vendored[@]+"${vendored[@]}"} -L . \
  --eval "(setq byte-compile-dest-file-function (lambda (f) (expand-file-name (concat (file-name-nondirectory f) \"c\") \"$tmp\")))" \
  --eval "(setq byte-compile-error-on-warn nil)" \
  -f batch-byte-compile "${files[@]}" 2>&1 | grep -v '^Wrote ' 
status=${PIPESTATUS[0]}
if [ "${1:-}" = "--checkdoc" ]; then
  timeout "$TIMEOUT" emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui ${vendored[@]+"${vendored[@]}"} -L . \
    --eval "(dolist (f (list $(printf '"%s" ' "${files[@]}"))) (checkdoc-file f))" 2>&1
fi
exit "$status"

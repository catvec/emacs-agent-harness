#!/usr/bin/env bash
# Byte-compile every source file out of tree and fail on errors.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
files=(harness.el lisp/*.el lisp/modules/*.el lisp/ui/*.el)
emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L . \
  --eval "(setq byte-compile-dest-file-function (lambda (f) (expand-file-name (concat (file-name-nondirectory f) \"c\") \"$tmp\")))" \
  --eval "(setq byte-compile-error-on-warn nil)" \
  -f batch-byte-compile "${files[@]}" 2>&1 | grep -v '^Wrote ' 
status=${PIPESTATUS[0]}
if [ "${1:-}" = "--checkdoc" ]; then
  emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L . \
    --eval "(dolist (f (list $(printf '"%s" ' "${files[@]}"))) (checkdoc-file f))" 2>&1
fi
exit "$status"

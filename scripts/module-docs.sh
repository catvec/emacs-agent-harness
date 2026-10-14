#!/usr/bin/env bash
# Write the module pages, read from the modules' source, into DIR
# (default docs/modules): a page per module and an index.  See
# lisp/harness-module-docs.el.  Run it after changing a module and commit
# what changed; --check exits non-zero, writing nothing, when the pages
# in DIR are not up to date.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
check=
if [ "${1:-}" = "--check" ]; then
  check=t
  shift
fi
DIR=${1:-docs/modules}
if [ -n "$check" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  [ -d "$DIR" ] && cp -R "$DIR"/. "$tmp"/
  target=$tmp
else
  target=$DIR
fi
emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L . \
  -l harness -l harness-module-docs \
  --eval "(let ((files (harness-module-docs-generate \"$target\" \"$DIR\")))
            (princ (format \"%d pages in %s\\n\" (length files) \"$DIR\")))" || exit 1
if [ -n "$check" ]; then
  if ! diff -r -q "$DIR" "$tmp" >/dev/null 2>&1; then
    echo "The module pages in $DIR are out of date: run scripts/module-docs.sh" >&2
    diff -r -q "$DIR" "$tmp" >&2
    exit 1
  fi
fi

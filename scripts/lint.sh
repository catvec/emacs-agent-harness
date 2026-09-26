#!/usr/bin/env bash
# Compile every elisp file out of tree; report the first failure per file.
#
# Emacs prefers a .elc that is newer than its .el, so compiling next to the
# sources would silently shadow edits.  This script always compiles to a
# temporary directory instead.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMACS="${EMACS:-emacs}"
TMPDIR_LINT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LINT"' EXIT

status=0
while IFS= read -r file; do
  out=$("$EMACS" -Q --batch -L "$REPO" -L "$REPO/lisp" -L "$REPO/lisp/modules" \
        -L "$REPO/lisp/transports" -L "$REPO/lisp/ui" \
        --eval "(progn (require 'bytecomp)
                   (let ((byte-compile-warnings nil)
                         (byte-compile-dest-file-function
                          (lambda (_f) (expand-file-name \"out.elc\" \"$TMPDIR_LINT\"))))
                     (condition-case err
                         (progn (byte-compile-file \"$file\")
                                (princ \"ok\"))
                       (error (princ (format \"ERR %S\" err))))))" 2>&1 || true)
  if [[ "$out" != *ok* ]]; then
    printf '%-55s %s\n' "$(basename "$file")" "FAILED"
    echo "$out" | grep -v debug-early | head -5
    status=1
  else
    printf '%-55s ok\n' "$(basename "$file")"
  fi
done < <(find "$REPO" -name '*.el' -not -path '*/.git/*' -not -path '*/.dev/*' | sort)
exit "$status"

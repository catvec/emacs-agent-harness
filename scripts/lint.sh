#!/usr/bin/env bash
# Read and byte-compile every elisp file; report the first failure per file.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMACS="${EMACS:-emacs}"
status=0
while IFS= read -r file; do
  out=$("$EMACS" -Q --batch -L "$REPO" -L "$REPO/lisp" -L "$REPO/lisp/modules" \
        -L "$REPO/lisp/transports" -L "$REPO/lisp/ui" \
        --eval "(progn (require 'bytecomp)
                   (let ((byte-compile-warnings nil))
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

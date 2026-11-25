#!/usr/bin/env bash
# Bounded local AFL++ campaign. Arguments: target seconds seed output-directory.
set -euo pipefail
fuzz_dir=$(cd -- "$(dirname -- "$0")" && pwd)
fuzz_root=$(cd -- "$fuzz_dir/../../.." && pwd)
export HARNESS_FUZZ_TARGET=${1:-all}
export HARNESS_FUZZ_SECONDS=${2:-60}
export HARNESS_FUZZ_SEED=${3:-42}
fuzz_output=${4:-$fuzz_root/scripts/.dev/fuzz}
if [[ $# -gt 4 || ! $HARNESS_FUZZ_SECONDS =~ ^[1-9][0-9]*$ || ! $HARNESS_FUZZ_SEED =~ ^[0-9]+$ ]] || (( HARNESS_FUZZ_SECONDS > 60 )); then
  echo 'Usage: run.sh [target=all] [seconds=60, at most 60] [seed=42] [output-directory]' >&2
  exit 2
fi
mkdir -p -- "$fuzz_output"
export HARNESS_FUZZ_REPORT_DIRECTORY
HARNESS_FUZZ_REPORT_DIRECTORY=$(mktemp -d -- "$fuzz_output/campaign-XXXXXX")
printf 'Campaign artifacts: %s\n' "$HARNESS_FUZZ_REPORT_DIRECTORY"
git -C "$fuzz_root" rev-parse HEAD > "$HARNESS_FUZZ_REPORT_DIRECTORY/revision.txt"
git -C "$fuzz_root" status --porcelain > "$HARNESS_FUZZ_REPORT_DIRECTORY/worktree.txt"
exec emacs -Q --batch -L "$fuzz_root/lisp" -L "$fuzz_root/lisp/modules" \
  -L "$fuzz_dir" -l harness-fuzz --eval '
(let ((harness-fuzz-keep-work-directory t)
      (harness-fuzz-parallel-targets 4)
      (print-circle t) (print-length nil) (print-level nil)
      (directory (getenv "HARNESS_FUZZ_REPORT_DIRECTORY")))
  (condition-case err
      (let* ((report (harness-fuzz-run
                      :targets (intern (getenv "HARNESS_FUZZ_TARGET"))
                      :executions 10000
                      :seconds (string-to-number (getenv "HARNESS_FUZZ_SECONDS"))
                      :seed (string-to-number (getenv "HARNESS_FUZZ_SEED"))
                      :shrink t :name "local-stability"))
             (summary (harness-fuzz-describe-report report)))
        (with-temp-file (expand-file-name "report.el" directory)
          (prin1 report (current-buffer)))
        (with-temp-file (expand-file-name "summary.txt" directory)
          (insert summary "\n"))
        (princ summary)
        (terpri)
        (kill-emacs (if (plist-get report :crashes) 1 0)))
    (error
     (message "Fuzz campaign failed: %s" (error-message-string err))
     (kill-emacs 2))))'

#!/usr/bin/env bash
# Synthetic, isolated live-harness walkthrough; no model or private log access.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
export HARNESS_DEV_SOCKET=${HARNESS_DEV_SOCKET:-history-demo}
export HARNESS_DEV_STATE=${HARNESS_DEV_STATE:-$ROOT/scripts/.dev/state-history-demo}
PROJECT=$ROOT/scripts/.dev/history-demo/project
WORKSPACE=$ROOT/scripts/.dev/history-demo/workspace
if [ ! -d "$PROJECT/.git" ]; then
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" -c user.name=Demo -c user.email=demo@example.invalid commit -q --allow-empty -m 'Demo workspace'
fi
if [ ! -e "$WORKSPACE/.git" ]; then
  git -C "$PROJECT" worktree add -q -b example-workspace "$WORKSPACE"
fi
scripts/dev.sh start
scripts/dev.sh eval "(progn (load \"$ROOT/demo/usage-history.el\" nil t) (harness-usage-history-demo \"$PROJECT/\"))"
printf '%s\n' 'Synthetic token-mix demo: period and grouping selectors, group details, pricing matrix, Help; H on the usage dashboard.'

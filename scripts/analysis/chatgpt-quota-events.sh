#!/usr/bin/env bash
# Extract the events of the overnight ChatGPT-plan spend from session logs.
#
# This script reads only; it changes nothing and writes nothing but stdout.
#
# The session logs live under <harness-state-directory>/sessions/, which a
# sandboxed bash cannot see, so pass the directory (or a copy of it) as $1:
#
#   scripts/analysis/chatgpt-quota-events.sh ~/.emacs.d/.local/cache/harness/sessions
#
# Where bash cannot reach it, the harness's own grep/read_file tools can; the
# queries the report cites are the ones below, run through those tools.
set -u
DIR=${1:?usage: $0 SESSION-DIR}

# The window: 2026-11-13 00:00-04:00 EST, in epoch seconds.
T0=1794546000
T1=1794560400

echo '== quota and money failures in the window =='
grep -h -E '"kind":"hint"' "$DIR"/*.nodes.jsonl \
  | grep -E 'subscription_sharing_usage_limit_exceeded|Insufficient Balance|invalid_api_key|Nothing left to carry on' \
  | grep -oE '"content":"[^"]*"[^}]*"session":"[0-9a-f-]+","ts":[0-9.]+' \
  | sort -t: -k4 -n

echo
echo '== compaction events in the window =='
grep -h -E '"kind":"compaction"' "$DIR"/*.nodes.jsonl \
  | grep -oE '"session":"[0-9a-f-]+","ts":[0-9.]+' \
  | sort

echo
echo '== prompt cache health alerts in the window =='
grep -h -E '"content":"Prompt cache miss' "$DIR"/*.nodes.jsonl \
  | grep -oE '"content":"[^"]*"[^}]*"session":"[0-9a-f-]+","ts":[0-9.]+' \
  | sort -t: -k4 -n

echo
echo '== per-session tool-call volume (window nodes only) =='
for f in "$DIR"/*.nodes.jsonl; do
  n=$(grep -c -E '"kind":"tool-call".*"ts":17945[0-9]{5}' "$f" 2>/dev/null || true)
  [ "${n:-0}" -gt 0 ] && printf '%6d %s\n' "$n" "$(basename "$f" .nodes.jsonl)"
done | sort -rn

echo
echo '== fallback moves into a ChatGPT-plan model =='
grep -oE '\{"session":"[0-9a-f-]+","original":"chatgpt:[^"]*","since":[0-9.]+' \
  "${DIR%/sessions}/fallback.json" 2>/dev/null | sort -t: -k4 -n

echo
echo "window: $T0 .. $T1 (2026-11-13 00:00-04:00 EST)"

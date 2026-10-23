#!/usr/bin/env bash
# Prove that the Flutter app builds: what a task that changes harness_client/
# runs before it hands its work in.
#
#   tool/check_build.sh [--accept-android-licenses] [options]
#
# It builds what is COMMITTED (`git archive HEAD`), in a directory of its own
# under scripts/.dev/client-check/ and never in this checkout, with the
# toolchain tool/client_toolchain.sh finds or installs, and runs, in order:
#
#   pub-get     flutter pub get --enforce-lockfile  pubspec.lock agrees with pubspec.yaml
#   analyze     flutter analyze                     no issues
#   test        flutter test                        no test fails that passes at BASE (a
#                                                   test that fails at BASE too is listed,
#                                                   and held against nobody)
#   build       flutter build apk --release         the APK tool/qr_install.sh
#                                                   installs, from an empty build/
#   upgrade     when pubspec.yaml, pubspec.lock, .flutter-version or android/
#               differ from BASE's: BASE's tree built, then HEAD's tree built
#               over that build/ -- the build you make after merging, over the
#               one you made before.  (shared_preferences_android 2.5.0 -> 2.5.2
#               broke exactly that, and a build from scratch never shows it.)
#               A BASE that does not build itself is said, and skipped.
#   tool-tests  python3 tool/test_qr_tools.py, tool/test_check_build.py
#                                                   when tool/ differs from BASE's
#
# and, when all of them pass, writes scripts/.dev/client-check/stamp.json.  The
# stamp names the commit that was checked.  This repository's plugin
# (.harness/plugins/dev/harness-client-check.el) has a task's hand_in refuse a
# branch that changed the app -- the paths in `inputs` below -- unless the stamp
# is for a commit with those paths as they are now, so run this after your last
# change to the app and commit everything first.
#
# It takes minutes (the first run on a machine installs the toolchain, several
# gigabytes): give the command a timeout of an hour.  The whole output of every
# step is kept in scripts/.dev/client-check/logs/, one file a step.
#
# Options:
#   --accept-android-licenses  let client_toolchain.sh accept the Android SDK
#                              licences for the SDK it installs (see its --help)
#   --quick          analyze and test the working tree, uncommitted changes
#                    included; builds no APK and writes no stamp
#   --base REF       the commit the branch started from (default: the merge
#                    base of HEAD and main); decides whether there is an upgrade
#                    build and whether tool/ changed
#   --no-upgrade     skip the upgrade build
#   --no-toolchain   use the environment as it is (flutter on PATH or FLUTTER,
#                    JAVA_HOME, ANDROID_HOME) instead of client_toolchain.sh
#   --keep           keep the directories the check built in on success too
#   --status         run nothing: exit 0 when the stamp covers the app as
#                    committed now, else 1 and say why (what hand_in asks)
#   --changed        run nothing: exit 0 when the branch has changed the app
#                    (committed since BASE, or not committed yet), else 1
#   --out DIR        where logs, copies and stamp go
#                    (default: scripts/.dev/client-check of the repository)
#   -h, --help       show this help
#
# Exit status: 0 passed (or --status: covered), 1 a step failed (or --status:
# not covered), 2 a bad option or no git, 3 no toolchain.
set -uo pipefail

tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(dirname "$tool_dir")"

# The paths of the app, relative to harness_client/, that a build or a test of
# it reads.  .harness/plugins/dev/harness-client-check.el has the same list
# (harness-client-check--paths); a test keeps the two equal.
inputs=(lib test android assets pubspec.yaml pubspec.lock analysis_options.yaml .flutter-version)
# Of those, what the upgrade build is about: what a version of a dependency or
# of the Android build can leave behind in build/.
upgrade_inputs=(pubspec.yaml pubspec.lock .flutter-version android)
# The tests of the tools in tool/, run when tool/ differs from BASE's.
tool_tests=(test_qr_tools.py test_check_build.py)

usage() {
  sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

die() {
  printf 'check_build: %s\n' "$*" >&2
  exit "${2:-2}"
}

quick=0 upgrade=1 use_toolchain=1 keep=0 status_only=0 changed_only=0 accept=0
base="${HARNESS_CLIENT_BASE:-}"
out=""
if [ -n "${HARNESS_CLIENT_CHECK_NO_TOOLCHAIN:-}" ]; then use_toolchain=0; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --accept-android-licenses) accept=1 ;;
    --quick) quick=1 ;;
    --base) [ $# -ge 2 ] || die "--base needs a commit"; base="$2"; shift ;;
    --no-upgrade) upgrade=0 ;;
    --no-toolchain) use_toolchain=0 ;;
    --keep) keep=1 ;;
    --status) status_only=1 ;;
    --changed) changed_only=1 ;;
    --out) [ $# -ge 2 ] || die "--out needs a directory"; out="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

command -v git >/dev/null 2>&1 || die "git is required"
repo="$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)" ||
  die "$project_dir is not in a git repository"
prefix="$(git -C "$project_dir" rev-parse --show-prefix)"  # harness_client/
prefix="${prefix%/}"
[ -n "$prefix" ] || die "harness_client is the repository itself; the check expects it inside one"
[ -n "$out" ] || out="$repo/scripts/.dev/client-check"
mkdir -p "$out" || die "cannot make $out"
out="$(cd "$out" && pwd)"
stamp="$out/stamp.json"
logs="$out/logs"
work="$out/work"

g() { git -C "$repo" "$@"; }

head_sha="$(g rev-parse --verify -q "HEAD^{commit}")" || die "the repository has no commit yet"

# The merge base with the branch the work will land on.
resolve_base() {
  local candidate
  if [ -n "$base" ]; then
    g rev-parse --verify -q "$base^{commit}" || true
    return
  fi
  for candidate in main master origin/main origin/master; do
    if g rev-parse --verify -q "$candidate^{commit}" >/dev/null; then
      g merge-base HEAD "$candidate" 2>/dev/null && return
    fi
  done
}

input_paths() { # the inputs as pathspecs of the repository
  local p
  for p in "${inputs[@]}"; do printf '%s/%s\n' "$prefix" "$p"; done
}

# The inputs as an array, `paths`; no mapfile, which a bash 3 (macOS) lacks.
load_paths() {
  local p
  paths=()
  while IFS= read -r p; do paths+=("$p"); done < <(input_paths)
}

sha256_of() { # FILE
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# --- --changed: whether the branch touched the app -----------------------------

if [ "$changed_only" = 1 ]; then
  base_sha="$(resolve_base)"
  load_paths
  if [ -n "$base_sha" ] && [ -n "$(g diff --name-only "$base_sha" -- "${paths[@]}")" ]; then
    exit 0
  fi
  [ -n "$(g status --porcelain -- "${paths[@]}")" ]
  exit $?
fi

# --- --status: what hand_in asks ----------------------------------------------

stamp_field() { # KEY -> the string value of "KEY" in the stamp
  sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$stamp" 2>/dev/null | head -n 1
}

# Print why the stamp does not cover the app as committed now; true when it does.
covered() {
  local result stamped
  [ -f "$stamp" ] || { echo "there is no stamp ($stamp): the check has not passed here"; return 1; }
  result="$(stamp_field result)"
  [ "$result" = pass ] || { echo "the stamp says \"$result\", not \"pass\""; return 1; }
  stamped="$(stamp_field head)"
  g rev-parse --verify -q "$stamped^{commit}" >/dev/null ||
    { echo "the stamp names a commit this repository does not have ($stamped)"; return 1; }
  if ! g merge-base --is-ancestor "$stamped" HEAD; then
    echo "the stamp is for ${stamped:0:12}, which is not in the history of HEAD ${head_sha:0:12}"
    return 1
  fi
  load_paths
  if ! g diff --quiet "$stamped" HEAD -- "${paths[@]}"; then
    echo "the app changed after the check passed for ${stamped:0:12}:"
    g diff --stat "$stamped" HEAD -- "${paths[@]}" | sed 's/^/  /'
    return 1
  fi
  if [ -n "$(g status --porcelain -- "${paths[@]}")" ]; then
    echo "the app has changes that are not committed:"
    g status --porcelain -- "${paths[@]}" | sed 's/^/  /'
    return 1
  fi
  return 0
}

if [ "$status_only" = 1 ]; then
  if reason="$(covered)"; then
    echo "check_build: the build check passed for $(stamp_field head | cut -c1-12), and the app is unchanged since"
    exit 0
  fi
  echo "check_build: $reason"
  exit 1
fi

# --- the toolchain ------------------------------------------------------------

if [ "$use_toolchain" = 1 ]; then
  toolchain_args=()
  [ "$accept" = 1 ] && toolchain_args+=(--accept-android-licenses)
  env_lines="$("$tool_dir/client_toolchain.sh" ${toolchain_args[@]+"${toolchain_args[@]}"})" || {
    status=$?
    echo "check_build: no toolchain to build with (see above); nothing was checked" >&2
    exit $((status == 2 ? 2 : 3))
  }
  eval "$env_lines"
fi
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
# No Gradle daemon left behind with its 8 GB heap.
export GRADLE_OPTS="${GRADLE_OPTS:-} -Dorg.gradle.daemon=false"

# A check is background work, as scripts/test.sh is: at nice 19 and idle I/O the
# user's own programs -- a game above all -- always win, and on an idle machine
# the check still gets all of it.  HARNESS_TEST_NICE and HARNESS_TEST_IONICE
# change it, as they do there.  A step that makes no progress for
# HARNESS_CLIENT_STEP_TIMEOUT seconds (default 1800) is killed and fails.
priority=()
case "${HARNESS_TEST_NICE:-19}" in
  ''|0|*[!0-9]*) ;;
  *) command -v nice >/dev/null 2>&1 && priority+=(nice -n "${HARNESS_TEST_NICE:-19}") ;;
esac
case "${HARNESS_TEST_IONICE:-3}" in
  [1-3]) command -v ionice >/dev/null 2>&1 && priority+=(ionice -c "${HARNESS_TEST_IONICE:-3}") ;;
esac
if command -v timeout >/dev/null 2>&1; then
  priority=(timeout "${HARNESS_CLIENT_STEP_TIMEOUT:-1800}" ${priority[@]+"${priority[@]}"})
fi

# --- what is to be checked ----------------------------------------------------

base_sha="$(resolve_base)"
load_paths

rm -rf "$logs" "$work"
mkdir -p "$logs" "$work"

dirty="$(g status --porcelain -- "$prefix")"
if [ "$quick" = 0 ] && [ -n "$dirty" ]; then
  echo "check_build: note: $prefix/ has changes that are not committed; the check is of the commit"
  echo "${dirty}" | sed -n '1,8s/^/  /p'
fi

started=$SECONDS
step_no=0
steps_run=()

finish() { # STATUS
  local status="$1"
  if [ "$status" -ne 0 ]; then
    echo
    echo "check_build: FAILED -- the copies stay in $work, the logs in $logs"
  fi
  exit "$status"
}

# Run a step, keeping its whole output in a log of its own.  run_step says what
# came of it and returns its status; step stops the check when it failed.
run_step() { # NAME DIR COMMAND...
  local name="$1" dir="$2" log started_at status=0
  shift 2
  step_no=$((step_no + 1))
  log="$(printf '%s/%02d-%s.log' "$logs" "$step_no" "$name")"
  printf '==> %-18s %s\n' "$name" "${1##*/} ${*:2:6}"
  started_at=$SECONDS
  (cd "$dir" && ${priority[@]+"${priority[@]}"} "$@") >"$log" 2>&1 || status=$?
  if [ "$status" -ne 0 ]; then
    [ "$status" -ne 124 ] || printf 'check_build: %s ran longer than HARNESS_CLIENT_STEP_TIMEOUT and was killed\n' "$name"
    printf 'FAIL %-18s exit %d after %ds; the last of its log, which is %s:\n' \
      "$name" "$status" "$((SECONDS - started_at))" "$log"
    tail -n 40 "$log" | sed 's/^/    | /'
    return "$status"
  fi
  printf 'ok   %-18s %ds\n' "$name" "$((SECONDS - started_at))"
  steps_run+=("$name")
}

step() { # NAME DIR COMMAND...
  run_step "$@" || finish 1
}

export_tree() { # REF DEST: harness_client as of REF, in DEST/harness_client
  mkdir -p "$2"
  g archive "$1" "$prefix" | tar -x -C "$2" || die "git archive $1 failed" 1
}

copy_working_tree() { # DEST: harness_client as it is on disk, ignored files left out
  mkdir -p "$1"
  (cd "$repo" && git ls-files -co --exclude-standard -z -- "$prefix" |
    while IFS= read -r -d '' file; do
      [ -e "$file" ] && printf '%s\0' "$file"
    done | tar --null -T - -c) | tar -x -C "$1"
}

flutter_of() { # TREE -> the flutter to run in TREE
  if [ -n "${FLUTTER:-}" ]; then printf '%s' "$FLUTTER"; else printf '%s/tool/flutter' "$1"; fi
}

# The app's tests, by name.  A test that fails here and failed at BASE too is
# somebody else's breakage -- the suite has been red before, and a branch that
# cannot go in until others' failures are mended is a branch nobody can finish --
# so it is listed, and held against nobody; a test that fails here and not at
# BASE, or a file that no longer loads, fails the check.
known_test_failures=0
base_test_failures() { # prints the failing tests of BASE's tree, one a line
  local utree flutter_base json status=0
  export_tree "$base_sha" "$work/base"
  utree="$work/base/$prefix"
  flutter_base="$(flutter_of "$utree")"
  json="$logs/base-test.json"
  echo "    (running the tests at ${base_sha:0:12} to see which of the failures are old)" >&2
  (cd "$utree" && ${priority[@]+"${priority[@]}"} "$flutter_base" pub get) >"$logs/base-pub-get.log" 2>&1 || return 1
  (cd "$utree" && ${priority[@]+"${priority[@]}"} "$flutter_base" test --reporter json) >"$json" 2>"$json.err" || true
  python3 -I "$tool_dir/report_flutter_tests.py" --failures "$json" 2>/dev/null || status=$?
  [ "$status" -ne 2 ] && [ "$status" -ne 3 ]
}

test_step() { # TREE FLUTTER
  local dir="$1" flutter="$2" json log status=0 report=0 started_at=$SECONDS
  if ! command -v python3 >/dev/null 2>&1; then
    step test "$dir" "$flutter" test
    return
  fi
  step_no=$((step_no + 1))
  json="$(printf '%s/%02d-test.json' "$logs" "$step_no")"
  log="$(printf '%s/%02d-test.log' "$logs" "$step_no")"
  printf '==> %-18s %s\n' test "${flutter##*/} test"
  (cd "$dir" && ${priority[@]+"${priority[@]}"} "$flutter" test --reporter json) >"$json" 2>"$json.err" || status=$?
  python3 -I "$tool_dir/report_flutter_tests.py" "$json" >"$log" 2>&1 || report=$?
  if [ "$status" -eq 0 ] && [ "$report" -eq 0 ]; then
    printf 'ok   %-18s %ds   %s\n' test "$((SECONDS - started_at))" "$(head -n 1 "$log")"
    steps_run+=(test)
    return
  fi
  # A run that did not finish, or died with no failing test to name, is a failure.
  if [ "$report" -eq 1 ] && [ -n "${base_sha:-}" ] && [ "$base_sha" != "$head_sha" ]; then
    local here="$logs/failing-tests-here.txt" there="$logs/failing-tests-at-base.txt" new
    python3 -I "$tool_dir/report_flutter_tests.py" --failures "$json" >"$here" 2>/dev/null || true
    if base_test_failures >"$there"; then
      new="$(LC_ALL=C comm -13 <(LC_ALL=C sort -u "$there") <(LC_ALL=C sort -u "$here"))"
      if [ -z "$new" ]; then
        known_test_failures="$(wc -l <"$here" | tr -d ' ')"
        printf 'ok   %-18s %ds   %s\n' test "$((SECONDS - started_at))" "$(head -n 1 "$log")"
        printf '     NOTE: all %s failing tests already fail at %s; this branch adds none.  They are\n' \
          "$known_test_failures" "${base_sha:0:12}"
        printf '     listed in %s -- somebody should mend them.\n' "$log"
        steps_run+=(test)
        return
      fi
      printf 'FAIL %-18s %d test(s) fail here that passed at %s:\n' test "$(echo "$new" | wc -l)" "${base_sha:0:12}"
      echo "$new" | sed 's/^/    | /'
      printf '     (%s -- %s; the whole report is in %s)\n' "$(head -n 1 "$log")" \
        "$(wc -l <"$there" | tr -d ' ') failed at the base already" "$log"
      finish 1
    fi
  fi
  printf 'FAIL %-18s flutter test exit %d, report %d after %ds; its report, which is %s:\n' \
    test "$status" "$report" "$((SECONDS - started_at))" "$log"
  head -n 60 "$log" | sed 's/^/    | /'
  finish 1
}

if [ "$quick" = 1 ]; then
  echo "check_build: quick: analyze and test the working tree (no APK, no stamp)"
  copy_working_tree "$work/quick"
  tree="$work/quick/$prefix"
  flutter="$(flutter_of "$tree")"
  step pub-get "$tree" "$flutter" pub get --enforce-lockfile
  step analyze "$tree" "$flutter" analyze
  test_step "$tree" "$flutter"
  printf 'check_build: quick check passed in %ds (nothing was built, no stamp written)\n' "$((SECONDS - started))"
  [ "$keep" = 1 ] || rm -rf "$work"
  exit 0
fi

echo "check_build: checking commit ${head_sha:0:12}${base_sha:+ (branch started at ${base_sha:0:12})}"
export_tree "$head_sha" "$work/head"
tree="$work/head/$prefix"
flutter="$(flutter_of "$tree")"

step pub-get "$tree" "$flutter" pub get --enforce-lockfile
step analyze "$tree" "$flutter" analyze
test_step "$tree" "$flutter"
step build "$tree" "$flutter" build apk --release

apk="$tree/build/app/outputs/flutter-apk/app-release.apk"
apk_sha=""
apk_bytes=0
if [ -f "$apk" ]; then
  apk_sha="$(sha256_of "$apk")"
  apk_bytes="$(wc -c <"$apk" | tr -d ' ')"
else
  echo "FAIL build    produced no APK at $apk"
  finish 1
fi

# --- the upgrade build ---------------------------------------------------------

upgrade_paths=()
for p in "${upgrade_inputs[@]}"; do upgrade_paths+=("$prefix/$p"); done
if [ "$upgrade" = 0 ]; then
  echo "skip upgrade    (--no-upgrade)"
elif [ -z "$base_sha" ]; then
  echo "skip upgrade    (no base to upgrade from: there is no main branch; pass --base)"
elif [ "$base_sha" = "$head_sha" ] || g diff --quiet "$base_sha" "$head_sha" -- "${upgrade_paths[@]}"; then
  echo "skip upgrade    (dependencies and Android files are as they were at ${base_sha:0:12})"
else
  export_tree "$base_sha" "$work/upgrade"
  utree="$work/upgrade/$prefix"
  uflutter="$(flutter_of "$utree")"
  # A base that does not build is nobody's doing here: the build over it cannot
  # be made, and the one from scratch above is what says this branch builds.
  if run_step upgrade-from "$utree" "$uflutter" build apk --release; then
    # HEAD over it: the files HEAD has, and none of the ones it deleted.
    export_tree "$head_sha" "$work/upgrade"
    while IFS= read -r -d '' gone; do
      rm -f "$work/upgrade/$gone"
    done < <(g diff --name-only -z --diff-filter=D "$base_sha" "$head_sha" -- "$prefix")
    step upgrade "$utree" "$uflutter" build apk --release
  else
    echo "     NOTE: ${base_sha:0:12} does not build either, so there is no build to make this branch's over;"
    echo "     the build from scratch passed, and that is all this branch can be held to."
  fi
fi

# --- the tools' own tests -------------------------------------------------------

if [ -n "$base_sha" ] && g diff --quiet "$base_sha" "$head_sha" -- "$prefix/tool"; then
  echo "skip tool-tests (tool/ is as it was at ${base_sha:0:12})"
elif command -v python3 >/dev/null 2>&1; then
  for t in "${tool_tests[@]}"; do
    [ -f "$tree/tool/$t" ] || continue
    step "tool-${t%.py}" "$tree" python3 -I "$tree/tool/$t"
  done
else
  echo "skip tool-tests (no python3)"
fi

# --- the stamp -------------------------------------------------------------------

steps_json=""
for s in "${steps_run[@]}"; do steps_json+="${steps_json:+, }\"$s\""; done
cat >"$stamp.new" <<EOF
{
  "format": 1,
  "result": "pass",
  "head": "$head_sha",
  "base": "$base_sha",
  "at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "seconds": $((SECONDS - started)),
  "steps": [$steps_json],
  "known_test_failures": $known_test_failures,
  "apk_sha256": "$apk_sha",
  "apk_bytes": $apk_bytes
}
EOF
mv "$stamp.new" "$stamp"

[ "$keep" = 1 ] || rm -rf "$work"
printf '\ncheck_build: PASSED in %ds for commit %s -- stamp: %s\n' \
  "$((SECONDS - started))" "${head_sha:0:12}" "$stamp"
[ -z "$apk_sha" ] || printf 'check_build: release APK %s bytes, sha256 %s\n' "$apk_bytes" "$apk_sha"
exit 0

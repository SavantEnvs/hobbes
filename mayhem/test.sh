#!/usr/bin/env bash
#
# mayhem/test.sh — RUN hobbes' own functional suites (already built by mayhem/build.sh): the in-tree
# hobbes-test groups, the 133 golden-output rosetta examples run through `hi`, and exact-value probes.
# exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


BT="$SRC/build-tests"
for b in hobbes-test hi mock-proc; do
  [ -x "$BT/$b" ] || { echo "missing $BT/$b (mayhem/build.sh builds it)" >&2; emit_ctrf hobbes 0 1 0; exit 1; }
done

passed=0; failed=0; skipped=0

# 1) hobbes-test: every group except the ones that need sockets/ports or spawn processes
#    (Net, PREPL, Process, Spawn) and so depend on the sandbox the suite runs in.
args=()
for g in $("$BT/hobbes-test" --list_tests); do
  case "$g" in Net|PREPL|Process|Spawn) continue ;; esac
  args+=(--tests "$g")
done
log="$(mktemp)"; trap 'rm -f "$log" "$log.json"' EXIT
(cd "$BT" && ./hobbes-test "${args[@]}" --json "$log.json") > "$log" 2>&1
p=$(grep -cE '^ +[A-Za-z0-9_]+ SUCCESS \(' "$log" || true)
f=$(grep -cE '^ +[A-Za-z0-9_]+ FAIL \(' "$log" || true)
echo "hobbes-test: $p passed, $f failed"
[ "$f" -eq 0 ] || grep -A3 -E '^(FAILURE|[ ]+[A-Za-z0-9_]+ FAIL)' "$log" | head -40
# a neutered or crashed runner prints no verdicts: that is a failure, never a skip
[ "$p" -ge 200 ] || { echo "hobbes-test ran only $p tests (expected >200)"; f=$((f+1)); }
passed=$((passed+p)); failed=$((failed+f))

# 2) rosetta examples: golden-output diff of `hi` on each script (prints "N passed, M failed").
out="$(bash "$SRC/examples/rosetta/run_tests.sh" "$BT/hi" 2>&1 || true)"
printf '%s\n' "$out" | grep -E '^(FAIL|  expected|  actual)' | head -30
rp=$(printf '%s\n' "$out" | sed -n 's/^\([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed$/\1/p' | tail -1)
rf=$(printf '%s\n' "$out" | sed -n 's/^\([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed$/\2/p' | tail -1)
echo "rosetta: ${rp:-?} passed, ${rf:-?} failed"
if [ -z "$rp" ] || [ "$rp" -lt 100 ]; then echo "rosetta ran only ${rp:-0} examples (expected >100)"; rf=$(( ${rf:-0} + 1 )); rp=${rp:-0}; fi
passed=$((passed+rp)); failed=$((failed+rf))

# 3) known-answer probes through the dynamically linked `hi`: expression -> exact printed value.
kat() { local expr="$1" want="$2" got
  got="$("$BT/hi" -s -x -e "$expr" 2>&1)" || true
  if [ "$got" = "$want" ]; then passed=$((passed+1)); else echo "KAT FAIL: $expr => [$got], want [$want]"; failed=$((failed+1)); fi; }
kat '6*7' '42'
kat 'reverse([1,2,3])' '[3, 2, 1]'
kat '"ab"++"cd"' '"abcd"'
kat '[x*x|x<-[1,2,3,4]]' '[1, 4, 9, 16]'
kat 'sum([1,2,3,4,5])' '15'

emit_ctrf "hobbes-test+rosetta" "$passed" "$failed" "$skipped"

#!/usr/bin/env bash
#
# mayhem/test.sh — RUN weggli's own upstream test suite (built by mayhem/build.sh
# via `cargo test --no-run`; this script only runs the pre-built test binaries).
# Suite: unit tests (src/util.rs) + integration tests (tests/query.rs, tests/cli.rs —
# assert_cmd behavioral assertions against the weggli binary's output).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

# Run the pre-built suite. build.sh compiled with identical flags, so this is a
# pure run (no compilation). --lib --bins --tests matches the --no-run build set.
LOG=/tmp/cargo-test.log
cargo test --lib --bins --tests 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# Sum every per-binary summary: "test result: ok. 48 passed; 0 failed; 0 ignored; ..."
read -r P F S < <(awk '/^test result:/ {
    for (i=1;i<=NF;i++) {
      if ($(i+1)=="passed;")  p+=$i;
      if ($(i+1)=="failed;")  f+=$i;
      if ($(i+1)=="ignored;") s+=$i;
    }
  } END { print p+0, f+0, s+0 }' "$LOG")

# Guard against a silently-empty run (e.g. neutered binaries producing no summaries).
if [ "$((P + F + S))" -eq 0 ]; then
  echo "ERROR: no test results parsed from cargo test output" >&2
  emit_ctrf "cargo-test" 0 1 0
  exit 1
fi
[ "$rc" -ne 0 ] && [ "$F" -eq 0 ] && F=1   # nonzero cargo exit with no parsed failures still fails

emit_ctrf "cargo-test" "$P" "$F" "$S"

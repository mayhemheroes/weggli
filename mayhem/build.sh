#!/usr/bin/env bash
#
# mayhem/build.sh — build weggli's cargo-fuzz target (fuzz_query) as a sanitized
# libFuzzer binary, plus the project's own test suite (cargo test, normal flags)
# so mayhem/test.sh only RUNS it.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the first (online) build populates the cargo
# registry under $CARGO_HOME; offline re-runs resolve crates from that cache
# (the rlenv runtime exports CARGO_NET_OFFLINE=true — do NOT hard-code --offline).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# ── 1. Test suite: project's NORMAL flags (no fuzzing cfg / sanitizer) ────────
# Compiles the lib + weggli binary + integration tests (tests/query.rs, tests/cli.rs)
# so mayhem/test.sh can run `cargo test` without building anything.
echo "=== cargo test --no-run (normal flags) ==="
cargo test --no-run --lib --bins --tests

# ── 2. Fuzz target: cargo-fuzz + ASan via RUSTFLAGS (OSS-Fuzz Rust path) ──────
# Rust code: ASan via RUSTFLAGS (rustc ignores the clang $SANITIZER_FLAGS); keep
# DWARF < 4 for Mayhem triage (§6.2 item 10) via RUST_DEBUG_FLAGS (-Zdwarf-version=3).
export RUST_DEBUG_FLAGS="${RUST_DEBUG_FLAGS:--Cdebuginfo=1 -Zdwarf-version=3}"
export RUSTFLAGS="${RUSTFLAGS:-} ${RUST_DEBUG_FLAGS} --cfg fuzzing -Zsanitizer=address -Cforce-frame-pointers"
# C/C++ code (tree-sitter grammars built by build.rs via cc): instrument with the
# clang $SANITIZER_FLAGS from the base image, DWARF-3 debug info. UBSan is dropped
# for the C objects only: rustc drives the final link and can't provide the UBSan
# runtime (__ubsan_handle_* undefined); ASan stays on and halting for everything.
C_SANITIZER_FLAGS="$(printf '%s' "${SANITIZER_FLAGS:-}" | sed 's/address,undefined/address/')"
export CFLAGS="${CFLAGS:-} ${C_SANITIZER_FLAGS} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} ${C_SANITIZER_FLAGS} -gdwarf-3"

FUZZ_DIR="fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete"

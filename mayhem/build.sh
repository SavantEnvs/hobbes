#!/usr/bin/env bash
#
# mayhem/build.sh — build hobbes' five libFuzzer harnesses (upstream's own fuzz/ directory), their
# standalone reproducers, and the project's test suite. Runs in /mayhem as `mayhem`.
# Three out-of-tree CMake builds, all under gitignored `build-*/` directories (SPEC §6.2 item 16):
#   build-fuzz        sanitized + SanCov-instrumented libhobbes, harnesses linked with $LIB_FUZZING_ENGINE
#   build-standalone  sanitized libhobbes, harnesses linked with upstream's run-once driver (fuzz/standalone_main.C)
#   build-tests       normal flags (no sanitizer, no -gdwarf-3): hobbes-test, hi, mock-proc for mayhem/test.sh
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

: "${SRC:=/mayhem}"
cd "$SRC"

# Debian trixie ships LLVM 19 (hobbes supports it; see include/hobbes/util/llvm.H).
LLVM_CMAKE_DIR="${HOBBES_LLVM_CMAKE_DIR:-/usr/lib/llvm-19/lib/cmake/llvm}"
NOWERROR="$SRC/mayhem/no-werror.cmake"
HARNESSES=(fuzz-type-decode fuzz-fregion-reader fuzz-parse-expr fuzz-hog-session)
# Ninja targets are the output paths: CMake drops the bare-name alias once $SRC/<harness> exists (re-runs).
HARNESS_OUTPUTS=("${HARNESSES[@]/#/fuzz/}")

# LeakSanitizer off at build time: link a weak __lsan_is_turned_off() into every harness.
mkdir -p build-fuzz build-standalone
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build-fuzz/lsan_off.o
cp build-fuzz/lsan_off.o build-standalone/lsan_off.o

# 1) fuzz build. BUILD_FUZZERS adds -fsanitize=fuzzer-no-link to the whole library, so the fuzzed code
#    carries SanCov even when $SANITIZER_FLAGS is empty.
cmake -S . -B build-fuzz -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SRC/build-fuzz/lsan_off.o" \
  -DCMAKE_PROJECT_hobbes_INCLUDE="$NOWERROR" -DLLVM_DIR="$LLVM_CMAKE_DIR" \
  -DBUILD_FUZZERS=ON -DFUZZING_ENGINE_LIB="$LIB_FUZZING_ENGINE"
cmake --build build-fuzz -j"$MAYHEM_JOBS" --target "${HARNESS_OUTPUTS[@]}"
for h in "${HARNESSES[@]}"; do cp build-fuzz/fuzz/"$h" "$SRC/$h"; done

# 2) standalone reproducers: same sanitized library, no libFuzzer runtime / no SanCov.
cmake -S . -B build-standalone -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SRC/build-standalone/lsan_off.o" \
  -DCMAKE_PROJECT_hobbes_INCLUDE="$NOWERROR" -DLLVM_DIR="$LLVM_CMAKE_DIR" \
  -DBUILD_FUZZERS=ON -DFUZZ_STANDALONE=ON
cmake --build build-standalone -j"$MAYHEM_JOBS" --target "${HARNESS_OUTPUTS[@]}"
for h in "${HARNESSES[@]}"; do cp build-standalone/fuzz/"$h" "$SRC/$h-standalone"; done

# 3) test suite with the project's normal flags (env CFLAGS/CXXFLAGS unset so nothing sanitized leaks in).
env -u CFLAGS -u CXXFLAGS -u LDFLAGS cmake -S . -B build-tests -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_PROJECT_hobbes_INCLUDE="$NOWERROR" -DLLVM_DIR="$LLVM_CMAKE_DIR"
cmake --build build-tests -j"$MAYHEM_JOBS" --target hobbes-test hi mock-proc

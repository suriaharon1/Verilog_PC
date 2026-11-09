#!/usr/bin/env bash
# run_tests.sh
# Run every built riscv-tests program for a suite and print a pass/fail table.
#
#   scripts/run_tests.sh rv32ui                 # run the rv32ui-p-* suite
#   scripts/run_tests.sh rv32ui --random-wait   # extra args go to the simulator
#
# Exit status is nonzero if any test does not pass.

set -u

SUITE="${1:-rv32ui}"
shift || true

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="$ROOT/build/sim/Vcore_top"
TEST_DIR="$ROOT/build/tests"
NM="${RISCV_PREFIX:-riscv64-unknown-elf-}nm"

if [ ! -x "$SIM" ]
then
    echo "error: $SIM not built (run: make sim)" >&2
    exit 2
fi

shopt -s nullglob
elfs=("$TEST_DIR/$SUITE"-p-*.elf)
if [ ${#elfs[@]} -eq 0 ]
then
    echo "error: no $SUITE tests in $TEST_DIR (run: make tests)" >&2
    exit 2
fi

pass=0
fail=0
failed=()

for elf in "${elfs[@]}"
do
    name="$(basename "$elf" .elf)"
    bin="${elf%.elf}.bin"
    tohost="$("$NM" "$elf" | awk '$3 == "tohost" { print $1 }')"
    if [ -z "$tohost" ]
    then
        printf "%-24s %s\n" "$name" "NO TOHOST SYMBOL"
        fail=$((fail + 1))
        failed+=("$name")
        continue
    fi

    result="$("$SIM" "$bin" --tohost "0x$tohost" "$@" 2>&1 | tail -n 1)"
    printf "%-24s %s\n" "$name" "$result"
    case "$result" in
        PASS*) pass=$((pass + 1)) ;;
        *)     fail=$((fail + 1)); failed+=("$name") ;;
    esac
done

echo "----------------------------------------"
echo "$SUITE: $pass passed, $fail failed, $((pass + fail)) total"
if [ "$fail" -ne 0 ]
then
    echo "failed: ${failed[*]}"
    exit 1
fi
exit 0

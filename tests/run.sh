#!/usr/bin/env bash
# Test suite for blink.
#
# Every test uses --dry-run or an argument error, so it never touches the
# keyboard backlight and runs fine on CI machines without one.
#
# Usage: tests/run.sh [path-to-blink]

set -u
BLINK=${1:-./blink}
pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n%s\n' "$1" "$2"; }

# expect_output NAME EXPECTED-SUBSTRING COMMAND...   (checks stdout + stderr)
expect_output() {
    local name=$1 want=$2 out
    shift 2
    out=$("$@" 2>&1)
    if [[ $out == *"$want"* ]]; then ok "$name"
    else bad "$name" "        expected to contain: $want"$'\n'"        got: $out"; fi
}

# expect_exit NAME EXPECTED-CODE COMMAND...
expect_exit() {
    local name=$1 want=$2 got
    shift 2
    "$@" >/dev/null 2>&1
    got=$?
    if [[ $got == "$want" ]]; then ok "$name"
    else bad "$name" "        expected exit $want, got $got"; fi
}

echo "Running blink tests against $BLINK"

# Encoding
expect_output "encodes SOS" $'  S  ...\n  O  ---\n  S  ...' "$BLINK" -n SOS
expect_output "is case-insensitive" $'  H  ....\n  I  ..' "$BLINK" -n hi
expect_output "encodes digits" "  7  --..." "$BLINK" -n 7
expect_output "encodes punctuation" "  ?  ..--.." "$BLINK" -n "?"
expect_output "marks word gaps" $'  A  .-\n     /\n  B  -...' "$BLINK" -n "A B"
expect_output "collapses repeated spaces" $'  A  .-\n     /\n  B  -...' "$BLINK" -n "A    B"
expect_output "joins multiple arguments" $'  A  .-\n     /\n  B  -...' "$BLINK" -n A B
expect_output "reads from stdin" $'  O  ---\n  K  -.-' bash -c "echo ok | '$BLINK' -n"

# Timing (PARIS standard: 1 unit = 1200 ms / WPM, so 100 ms at 12 WPM)
expect_output "SOS takes 27 units" "(2.7 s per pass)" "$BLINK" -n -w 12 SOS
expect_output "PARIS takes 43 units" "(4.3 s per pass)" "$BLINK" -n -w 12 PARIS
expect_output "word gap is 7 units" "(1.7 s per pass)" "$BLINK" -n -w 12 "E E E"

# Unsupported characters
expect_output "warns about unknown characters" "skipping characters with no Morse code: '#'" "$BLINK" -n "a#b"
expect_output "warns about non-ASCII characters" "(non-ASCII)" "$BLINK" -n "café"
expect_output "still sends the rest" $'  A  .-\n  B  -...' "$BLINK" -n "a#b"

# Errors (all exit before the backlight is opened)
expect_exit "rejects an empty message" 2 "$BLINK" -n "###"
expect_exit "rejects --wpm 0" 2 "$BLINK" -n -w 0 A
expect_exit "rejects --wpm 61" 2 "$BLINK" -n -w 61 A
expect_exit "rejects --brightness 0" 2 "$BLINK" -n -b 0 A
expect_exit "rejects --brightness 101" 2 "$BLINK" -n -b 101 A
expect_exit "rejects negative --repeat" 2 "$BLINK" -n -r -1 A
expect_exit "rejects unknown options" 2 "$BLINK" --nope A

# Info flags
expect_output "prints the version" "blink 1.0.0" "$BLINK" --version
expect_output "prints help" "Usage:" "$BLINK" --help
expect_exit "help exits 0" 0 "$BLINK" --help

echo
echo "$pass passed, $fail failed"
[[ $fail == 0 ]]

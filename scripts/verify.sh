#!/bin/bash
# Builds, tests and benchmarks the package. Output goes to the terminal and to .logs/ (git-ignored).
# Usage: bash scripts/verify.sh
cd "$(dirname "$0")/.." || exit 1
mkdir -p .logs
{
  date -u +"%Y-%m-%dT%H:%M:%SZ"
  sw_vers
  uname -m
  sysctl -n machdep.cpu.brand_string hw.model 2>/dev/null
  swift --version 2>&1
  xcodebuild -version 2>&1
} > .logs/env.txt

# run <name> <command...>: show the output, keep it in .logs/<name>.txt, record the exit code.
run() {
  local name=$1
  shift
  echo "== $*"
  "$@" 2>&1 | tee ".logs/$name.txt"
  local code=${PIPESTATUS[0]}
  echo "exit=$code" >> ".logs/$name.txt"
  return "$code"
}

# The script exits with the first failing step's code (0 when every step passes).
status=0
fail() { [ "$status" -ne 0 ] || status=$1; }

if run build swift build; then
  run test swift test || fail $?
  run bench swift run -c release bench || fail $?
else
  fail $?
fi
echo
echo "Done. Logs: .logs/env.txt build.txt test.txt bench.txt"
exit "$status"

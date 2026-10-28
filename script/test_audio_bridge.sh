#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TASK_ROOT/work/driver-tests"
for suite in BridgeTests BridgeQualityTests CrunchTests; do
  /usr/bin/clang -std=c11 -g -O1 -fsanitize=address,undefined -mmacosx-version-min=14.2 \
    -I "$TASK_ROOT/Sources/mixerMacDSP/include" \
    "$TASK_ROOT/Driver/Tests/$suite.c" "$TASK_ROOT/Sources/mixerMacDSP/mixerMacDSP.c" \
    -o "$TASK_ROOT/work/driver-tests/$suite"
  "$TASK_ROOT/work/driver-tests/$suite"
done

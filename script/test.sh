#!/bin/zsh
set -euo pipefail

TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_SWIFT="$(xcrun --find swift)"
TASK_TESTING_PLUGIN="$(dirname "$TASK_SWIFT")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"

cd "$TASK_ROOT"
if [[ -f "$TASK_TESTING_PLUGIN" ]]; then
  "$TASK_SWIFT" test -Xswiftc -load-plugin-library -Xswiftc "$TASK_TESTING_PLUGIN" "$@"
else
  "$TASK_SWIFT" test "$@"
fi

#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER="$TASK_ROOT/outputs/mixerMacAudio.driver"
mkdir -p "$DRIVER/Contents/MacOS" "$DRIVER/Contents/Resources" "$TASK_ROOT/work/driver-tests"
/usr/bin/clang -std=c11 -fblocks -O2 -arch arm64 -arch x86_64 \
  -mmacosx-version-min=14.2 -bundle \
  -framework CoreAudio -framework CoreFoundation \
  "$TASK_ROOT/Driver/mixerMacAudio.c" -o "$DRIVER/Contents/MacOS/mixerMacAudio"
cp "$TASK_ROOT/Driver/Info.plist" "$DRIVER/Contents/Info.plist"
cp "$TASK_ROOT/Driver/LICENSE.txt" "$DRIVER/Contents/Resources/LICENSE.txt"
/usr/bin/codesign --force --sign - "$DRIVER"
/usr/bin/codesign --verify --strict "$DRIVER"
/usr/bin/plutil -lint "$DRIVER/Contents/Info.plist"
/usr/bin/clang -std=c11 -fblocks -g -O1 -fsanitize=address,undefined \
  -mmacosx-version-min=14.2 -framework CoreAudio -framework CoreFoundation \
  "$TASK_ROOT/Driver/Tests/DriverTests.c" -o "$TASK_ROOT/work/driver-tests/DriverTests"
"$TASK_ROOT/work/driver-tests/DriverTests"
"$TASK_ROOT/script/test_audio_bridge.sh"
echo "Built and checked: $DRIVER"

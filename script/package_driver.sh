#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$TASK_ROOT/script/build_driver.sh"
PKG_ROOT="$TASK_ROOT/work/driver-package-root"
mkdir -p "$PKG_ROOT/Library/Audio/Plug-Ins/HAL"
/usr/bin/ditto "$TASK_ROOT/outputs/mixerMacAudio.driver" "$PKG_ROOT/Library/Audio/Plug-Ins/HAL/mixerMacAudio.driver"
/usr/bin/pkgbuild --root "$PKG_ROOT" --identifier local.mixermac.audio.driver \
  --version 0.1.0 --ownership recommended --install-location / \
  "$TASK_ROOT/outputs/mixerMacAudio.pkg"
cp "$TASK_ROOT/Driver/README.md" "$TASK_ROOT/outputs/DRIVER_INSTALL.md"
echo "Installer: $TASK_ROOT/outputs/mixerMacAudio.pkg"

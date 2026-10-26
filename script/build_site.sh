#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_SITE="$TASK_ROOT/work/pages-site"
mkdir -p "$TASK_SITE/assets"
cp "$TASK_ROOT/site/index.html" "$TASK_ROOT/site/styles.css" "$TASK_ROOT/site/app.js" "$TASK_SITE/"
cp "$TASK_ROOT/docs/assets/app-icon.png" "$TASK_ROOT/docs/assets/console.png" "$TASK_ROOT/docs/assets/detail.png" "$TASK_SITE/assets/"
echo "Static site: $TASK_SITE"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if pgrep -x MacSearch >/dev/null; then
  echo 'Please quit Mac Search before installing.' >&2
  exit 1
fi
scripts/build-app.sh
ditto 'build/Mac Search.app' '/Applications/Mac Search.app'
codesign --verify --deep --strict '/Applications/Mac Search.app'
open '/Applications/Mac Search.app'

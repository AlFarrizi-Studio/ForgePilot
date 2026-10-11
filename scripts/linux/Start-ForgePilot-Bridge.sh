#!/bin/sh
set -eu
forgepilot_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
if ! command -v node >/dev/null 2>&1; then
  echo "Node.js 22 or newer is required. Install Node.js and reopen this file." >&2
  exit 1
fi
exec node "$forgepilot_dir/../../runtime/bridge.mjs" "$@"

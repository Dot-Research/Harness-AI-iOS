#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f /workspace/toolchains/env.sh ]]; then
  source /workspace/toolchains/env.sh
  swift test --cache-path /workspace/toolchains/cache/swiftpm --config-path /workspace/toolchains/cache/config --security-path /workspace/toolchains/cache/security -j 4 -Xswiftc -module-cache-path -Xswiftc /workspace/toolchains/cache/clang
else
  swift test -j 4
fi
PYTHONPATH=companion python3 -m unittest discover -s companion/tests -v

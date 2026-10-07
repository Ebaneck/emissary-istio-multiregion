#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "==> deleting k3d clusters"
k3d cluster delete "$CLUSTER_US" 2>/dev/null || true
k3d cluster delete "$CLUSTER_EU" 2>/dev/null || true

echo "==> stopping redis"
docker rm -f "$REDIS_NAME" 2>/dev/null || true

if [[ "${REMOVE_NETWORK:-0}" == "1" ]]; then
  docker network rm "$NETWORK_NAME" 2>/dev/null || true
fi

echo "down complete"

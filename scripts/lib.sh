#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETWORK_NAME="${NETWORK_NAME:-cano-multi}"
REDIS_NAME="${REDIS_NAME:-cano-redis}"
CLUSTER_US="${CLUSTER_US:-cano-us}"
CLUSTER_EU="${CLUSTER_EU:-cano-eu}"
ISTIO_VERSION="${ISTIO_VERSION:-1.23.3}"
JWT_SECRET="${JWT_SECRET:-cano-dev-secret}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    return 1
  fi
}

ensure_network() {
  if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    docker network create "$NETWORK_NAME"
    echo "created docker network $NETWORK_NAME"
  fi
}

wait_deploy() {
  local ctx="$1" ns="$2" name="$3" timeout="${4:-180s}"
  kubectl --context "$ctx" -n "$ns" rollout status "deploy/$name" --timeout="$timeout"
}

k3d_ctx() {
  echo "k3d-$1"
}

apply_boards() {
  local ctx="$1" region="$2"
  sed "s/PLACEHOLDER_REGION/${region}/g" "$ROOT/deploy/common/boards-deploy.yaml" \
    | kubectl --context "$ctx" apply -f -
}

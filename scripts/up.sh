#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "==> prerequisites"
need_cmd docker
need_cmd helm
need_cmd kubectl
need_cmd go

if ! command -v k3d >/dev/null 2>&1; then
  echo "installing k3d..."
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi
need_cmd k3d

if ! command -v istioctl >/dev/null 2>&1; then
  echo "installing istioctl ${ISTIO_VERSION}..."
  curl -L "https://istio.io/downloadIstio" | ISTIO_VERSION="$ISTIO_VERSION" sh -
  export PATH="${PWD}/istio-${ISTIO_VERSION}/bin:${PATH}"
  # also try common install location from download in ROOT
  if [[ -x "${ROOT}/istio-${ISTIO_VERSION}/bin/istioctl" ]]; then
    export PATH="${ROOT}/istio-${ISTIO_VERSION}/bin:${PATH}"
  fi
fi
# If still missing, download into ROOT
if ! command -v istioctl >/dev/null 2>&1; then
  (
    cd "$ROOT"
    curl -L "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-osx-arm64.tar.gz" -o /tmp/istio.tgz 2>/dev/null \
      || curl -L "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-osx.tar.gz" -o /tmp/istio.tgz 2>/dev/null \
      || curl -L "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz" -o /tmp/istio.tgz
    tar -xzf /tmp/istio.tgz -C "$ROOT"
  )
  export PATH="${ROOT}/istio-${ISTIO_VERSION}/bin:${PATH}"
fi
need_cmd istioctl

if ! command -v jq >/dev/null 2>&1; then
  echo "warning: jq not found; demo.sh will need it" >&2
fi

ensure_network

echo "==> redis"
if ! docker inspect "$REDIS_NAME" >/dev/null 2>&1; then
  docker run -d --name "$REDIS_NAME" --network "$NETWORK_NAME" -p 6379:6379 redis:7-alpine
else
  docker start "$REDIS_NAME" >/dev/null || true
fi
# wait for redis
for i in $(seq 1 30); do
  if docker exec "$REDIS_NAME" redis-cli ping 2>/dev/null | grep -q PONG; then
    break
  fi
  sleep 1
done
docker exec "$REDIS_NAME" redis-cli SET 'account:email:alice@example.com' '{"id":"alice","region":"us"}' >/dev/null
docker exec "$REDIS_NAME" redis-cli SET 'account:email:bruno@example.com' '{"id":"bruno","region":"eu"}' >/dev/null
echo "redis seeded"

create_cluster() {
  local name="$1" http_port="$2" https_port="$3"
  if k3d cluster list | grep -q "^${name} "; then
    echo "cluster $name already exists"
    return
  fi
  k3d cluster create "$name" \
    --network "$NETWORK_NAME" \
    -p "${http_port}:80@loadbalancer" \
    -p "${https_port}:443@loadbalancer" \
    --k3s-arg "--disable=traefik@server:0" \
    --host-alias "host.docker.internal:host-gateway"
}

echo "==> k3d clusters"
create_cluster "$CLUSTER_US" 8080 8443
create_cluster "$CLUSTER_EU" 8081 8444

CTX_US="$(k3d_ctx "$CLUSTER_US")"
CTX_EU="$(k3d_ctx "$CLUSTER_EU")"

echo "==> build images"
docker build -t cano/auth:local "$ROOT/auth"
docker build -t cano/boards:local "$ROOT/boards"
k3d image import cano/auth:local cano/boards:local -c "$CLUSTER_US"
k3d image import cano/auth:local cano/boards:local -c "$CLUSTER_EU"

install_region() {
  local ctx="$1" region="$2" overlay="$3"
  echo "==> region $region ($ctx)"

  if ! kubectl --context "$ctx" get ns istio-system >/dev/null 2>&1; then
    istioctl install -y --context "$ctx" --set profile=default
  fi

  kubectl --context "$ctx" apply -f "$ROOT/deploy/common/namespaces.yaml"
  # restart nothing yet; labels apply to new pods

  kubectl --context "$ctx" apply -f "$ROOT/deploy/common/peer-authentication.yaml"
  kubectl --context "$ctx" apply -f "$ROOT/deploy/common/auth-deploy.yaml"
  apply_boards "$ctx" "$region"

  helm repo add datawire https://app.getambassador.io >/dev/null 2>&1 || true
  helm repo update datawire >/dev/null

  if ! helm --kube-context "$ctx" -n emissary status emissary >/dev/null 2>&1; then
    helm install emissary datawire/emissary-ingress \
      --kube-context "$ctx" \
      --namespace emissary \
      -f "$ROOT/deploy/common/emissary-istio-values.yaml" \
      --wait --timeout 5m || \
    helm install emissary datawire/emissary \
      --kube-context "$ctx" \
      --namespace emissary \
      -f "$ROOT/deploy/common/emissary-istio-values.yaml" \
      --wait --timeout 5m
  else
    helm upgrade emissary datawire/emissary-ingress \
      --kube-context "$ctx" \
      --namespace emissary \
      -f "$ROOT/deploy/common/emissary-istio-values.yaml" \
      --wait --timeout 5m 2>/dev/null || \
    helm upgrade emissary datawire/emissary \
      --kube-context "$ctx" \
      --namespace emissary \
      -f "$ROOT/deploy/common/emissary-istio-values.yaml" \
      --wait --timeout 5m
  fi

  # Ensure CRDs / wait for emissary agent or deployment
  kubectl --context "$ctx" -n emissary wait --for=condition=available --timeout=180s deploy -l app.kubernetes.io/name=emissary-ingress 2>/dev/null \
    || kubectl --context "$ctx" -n emissary wait --for=condition=available --timeout=180s deploy -l app.kubernetes.io/instance=emissary 2>/dev/null \
    || true

  wait_deploy "$ctx" demo auth 180s
  wait_deploy "$ctx" demo boards 180s

  kubectl --context "$ctx" apply -f "$ROOT/deploy/common/tls-context.yaml"
  kubectl --context "$ctx" apply -f "$ROOT/deploy/common/auth-service.yaml"
  kubectl --context "$ctx" apply -f "$ROOT/deploy/${overlay}/local-mappings.yaml"
  kubectl --context "$ctx" apply -f "$ROOT/deploy/${overlay}/handover-mapping.yaml"
}

install_region "$CTX_US" us us
install_region "$CTX_EU" eu eu

echo ""
echo "Ready."
echo "  US Emissary: http://127.0.0.1:8080"
echo "  EU Emissary: http://127.0.0.1:8081"
echo "Run: ./scripts/demo.sh"

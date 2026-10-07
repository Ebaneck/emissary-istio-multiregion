#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "==> prerequisites"
need_cmd docker
need_cmd helm
need_cmd kubectl
need_cmd go

BIN_DIR="${ROOT}/.bin"
mkdir -p "$BIN_DIR"
export PATH="${BIN_DIR}:${PATH}"

if ! command -v k3d >/dev/null 2>&1; then
  echo "installing k3d into ${BIN_DIR}..."
  K3D_TAG="$(curl -sL https://api.github.com/repos/k3d-io/k3d/releases/latest | jq -r .tag_name)"
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
  esac
  curl -sL "https://github.com/k3d-io/k3d/releases/download/${K3D_TAG}/k3d-${OS}-${ARCH}" -o "${BIN_DIR}/k3d"
  chmod +x "${BIN_DIR}/k3d"
fi
need_cmd k3d

if ! command -v istioctl >/dev/null 2>&1; then
  echo "installing istioctl ${ISTIO_VERSION} into ${ROOT}..."
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) IARCH=amd64 ;;
    arm64|aarch64) IARCH=arm64 ;;
    *) IARCH=amd64 ;;
  esac
  case "$OS" in
    darwin) IOS=osx ;;
    linux) IOS=linux ;;
    *) IOS=linux ;;
  esac
  # osx arm64 uses osx-arm64; osx amd64 uses osx
  if [[ "$IOS" == "osx" && "$IARCH" == "arm64" ]]; then
    IASSET="istio-${ISTIO_VERSION}-osx-arm64.tar.gz"
  elif [[ "$IOS" == "osx" ]]; then
    IASSET="istio-${ISTIO_VERSION}-osx.tar.gz"
  else
    IASSET="istio-${ISTIO_VERSION}-linux-${IARCH}.tar.gz"
  fi
  curl -sL "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/${IASSET}" -o /tmp/istio.tgz
  tar -xzf /tmp/istio.tgz -C "$ROOT"
  ln -sfn "${ROOT}/istio-${ISTIO_VERSION}/bin/istioctl" "${BIN_DIR}/istioctl"
fi
need_cmd istioctl

if ! command -v jq >/dev/null 2>&1; then
  echo "warning: jq not found; demo.sh will need it" >&2
fi

ensure_network

REDIS_HOST_PORT="${REDIS_HOST_PORT:-16379}"
echo "==> redis (host port ${REDIS_HOST_PORT})"
docker rm -f "$REDIS_NAME" >/dev/null 2>&1 || true
docker run -d --name "$REDIS_NAME" --network "$NETWORK_NAME" -p "${REDIS_HOST_PORT}:6379" redis:7-alpine
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
# Keep auth Deployment REDIS_ADDR in sync with host-mapped port
sed -i.bak "s|host.docker.internal:[0-9]*|host.docker.internal:${REDIS_HOST_PORT}|g" "$ROOT/deploy/common/auth-deploy.yaml"
rm -f "$ROOT/deploy/common/auth-deploy.yaml.bak"

create_cluster() {
  local name="$1" http_port="$2" https_port="$3"
  if k3d cluster list | grep -q "^${name} "; then
    echo "cluster $name already exists"
    return
  fi
  # host.docker.internal is provided by Docker Desktop; on Linux add --host-alias if needed
  k3d cluster create "$name" \
    --network "$NETWORK_NAME" \
    -p "${http_port}:80@loadbalancer" \
    -p "${https_port}:443@loadbalancer" \
    --k3s-arg "--disable=traefik@server:0"
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
    # minimal control plane + tiny resource requests (dual k3d needs ~8Gi Docker RAM)
    istioctl install -y --context "$ctx" -f "$ROOT/deploy/common/istio-operator-minimal.yaml"
  fi

  kubectl --context "$ctx" apply -f "$ROOT/deploy/common/namespaces.yaml"
  # restart nothing yet; labels apply to new pods

  kubectl --context "$ctx" apply -f "$ROOT/deploy/common/peer-authentication.yaml"
  kubectl --context "$ctx" apply -f "$ROOT/deploy/common/auth-deploy.yaml"
  apply_boards "$ctx" "$region"

  EMISSARY_APP_VERSION="${EMISSARY_APP_VERSION:-3.12.2}"
  helm repo add datawire https://app.getambassador.io >/dev/null 2>&1 || true
  helm repo update >/dev/null

  # CRDs + apiext must exist before the chart (Listener/Module kinds)
  if ! kubectl --context "$ctx" get crd listeners.getambassador.io >/dev/null 2>&1; then
    kubectl --context "$ctx" apply -f "https://app.getambassador.io/yaml/emissary/${EMISSARY_APP_VERSION}/emissary-crds.yaml"
  fi
  kubectl --context "$ctx" wait --timeout=120s --for=condition=available deployment emissary-apiext -n emissary-system
  kubectl --context "$ctx" -n emissary-system scale deploy emissary-apiext --replicas=1

  if ! helm --kube-context "$ctx" -n emissary status emissary >/dev/null 2>&1; then
    helm install emissary datawire/emissary-ingress \
      --kube-context "$ctx" \
      --namespace emissary \
      --version 8.12.2 \
      -f "$ROOT/deploy/common/emissary-istio-values.yaml" \
      --wait --timeout 5m
  else
    helm upgrade emissary datawire/emissary-ingress \
      --kube-context "$ctx" \
      --namespace emissary \
      --version 8.12.2 \
      -f "$ROOT/deploy/common/emissary-istio-values.yaml" \
      --wait --timeout 5m
  fi

  kubectl --context "$ctx" -n emissary wait --for=condition=available --timeout=180s deploy -l app.kubernetes.io/name=emissary-ingress

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

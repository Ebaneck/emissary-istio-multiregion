# Multi-Region Emissary + Istio Local Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a privacy-first dual-region (US/EU) edge on one laptop with k3d, Emissary, Istio mTLS, JWT ExtAuth + shared Redis, and prove correct-region + handover flows with `scripts/demo.sh`.

**Architecture:** Two k3d clusters on Docker network `cano-multi`. Each cluster runs Istio (STRICT) + Emissary (Istio cert integration) + auth + boards. Shared Redis holds account→region. ExtAuth sets `x-region-target`; high-precedence Mapping proxies to peer Emissary when wrong region.

**Tech Stack:** Go 1.22, Redis 7, k3d, Istio 1.23.3, Emissary Ingress Helm chart `datawire/emissary`, Helm 3, kubectl, Docker

## Global Constraints

- Clusters named `cano-us` and `cano-eu`; Docker network `cano-multi`
- Auth: HS256 JWT; claims `sub` (account id) and `region` (`us`|`eu`)
- Seed accounts: `alice@example.com` → us; `bruno@example.com` → eu
- ExtAuth HTTP; bypass JWT check for `POST /login` inside auth service
- Mapping hostname `*`; boards Mapping uses `service: boards:80` and `tls: istio-upstream`
- Handover Mapping `precedence: 100` matching foreign `x-region-target`
- Response headers on handover: `x-routed-from`, `x-routed-to`
- No Cloudflare, Prometheus, Zipkin, true DB replication, or Istio multi-cluster mesh
- Host ports: US `8080`/`8443`, EU `8081`/`8444` (HTTP/HTTPS via k3d loadbalancer)

## File Structure

```
cano/
  README.md
  .gitignore
  scripts/up.sh
  scripts/down.sh
  scripts/demo.sh
  scripts/lib.sh
  redis/seed.sh
  auth/go.mod
  auth/go.sum
  auth/main.go
  auth/main_test.go
  auth/Dockerfile
  boards/go.mod
  boards/go.sum
  boards/main.go
  boards/main_test.go
  boards/Dockerfile
  deploy/common/namespaces.yaml
  deploy/common/peer-authentication.yaml
  deploy/common/auth-deploy.yaml
  deploy/common/boards-deploy.yaml
  deploy/common/emissary-istio-values.yaml
  deploy/common/tls-context.yaml
  deploy/common/auth-service.yaml
  deploy/common/listeners-host.yaml
  deploy/us/handover-mapping.yaml
  deploy/us/local-mappings.yaml
  deploy/eu/handover-mapping.yaml
  deploy/eu/local-mappings.yaml
```

---

### Task 1: Auth service (Go) with unit tests

**Files:**
- Create: `auth/go.mod`, `auth/main.go`, `auth/main_test.go`, `auth/Dockerfile`
- Test: `auth/main_test.go`

**Interfaces:**
- Consumes: Redis at `REDIS_ADDR` (default `redis:6379`); `JWT_SECRET`; key `account:email:<email>` → JSON `{"id","region"}`
- Produces: `POST /login` → `{"token":"..."}`; ExtAuth via any path — if path is `/login` return 200; else require Bearer, return 200 + headers `x-region-target`, `x-account-id` or 401

- [ ] **Step 1: Write failing tests**

Create `auth/go.mod`:

```
module github.com/ebaneck/cano/auth

go 1.22

require (
        github.com/golang-jwt/jwt/v5 v5.2.1
        github.com/redis/go-redis/v9 v9.7.0
)
```

Create `auth/main_test.go`:

```go
package main

import (
#ifdef "encoding/json"
        "net/http"
        "net/http/httptest"
        "testing"
        "time"

        "github.com/golang-jwt/jwt/v5"
)

func TestExtAuthUnauthorizedWithoutToken(t *testing.T) {
        s := &Server{jwtSecret: []byte("test-secret"), regionLookup: nil}
        req := httptest.NewRequest(http.MethodGet, "/boards/", nil)
        rr := httptest.NewRecorder()
        s.handleExtAuth(rr, req)
        if rr.Code != http.StatusUnauthorized {
                t.Fatalf("got %d", rr.Code)
        }
}

func TestExtAuthBypassesLogin(t *testing.T) {
        s := &Server{jwtSecret: []byte("test-secret")}
        req := httptest.NewRequest(http.MethodPost, "/login", nil)
        // Emissary sends original path in X-Forwarded-Proto stack; we also check URL path
        req.Header.Set("X-Original-URL", "http://x/login")
        rr := httptest.NewRecorder()
        s.handleExtAuth(rr, req)
        if rr.Code != http.StatusOK {
                t.Fatalf("got %d", rr.Code)
        }
}

func TestExtAuthSetsRegionHeaders(t *testing.T) {
        secret := []byte("test-secret")
        tok := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
                "sub":    "alice",
                "region": "us",
                "exp":    time.Now().Add(time.Hour).Unix(),
        })
        signed, err := tok.SignedString(secret)
        if err != nil {
                t.Fatal(err)
        }
        s := &Server{jwtSecret: secret}
        req := httptest.NewRequest(http.MethodGet, "/boards/", nil)
        req.Header.Set("Authorization", "Bearer "+signed)
        rr := httptest.NewRecorder()
        s.handleExtAuth(rr, req)
        if rr.Code != http.StatusOK {
                t.Fatalf("got %d body=%s", rr.Code, rr.Body.String())
        }
        if rr.Header().Get("x-region-target") != "us" {
                t.Fatalf("region header %q", rr.Header().Get("x-region-target"))
        }
        if rr.Header().Get("x-account-id") != "alice" {
                t.Fatalf("account header %q", rr.Header().Get("x-account-id"))
        }
}

func TestLoginIssuesToken(t *testing.T) {
        s := &Server{
                jwtSecret: []byte("test-secret"),
                lookup: func(email string) (*Account, error) {
                        if email == "alice@example.com" {
                                return &Account{ID: "alice", Region: "us"}, nil
                        }
                        return nil, errNotFound
                },
        }
        body, _ := json.Marshal(map[string]string{"email": "alice@example.com"})
        req := httptest.NewRequest(http.MethodPost, "/login", bytesReader(body))
        req.Header.Set("Content-Type", "application/json")
        rr := httptest.NewRecorder()
        s.handleLogin(rr, req)
        if rr.Code != http.StatusOK {
                t.Fatalf("got %d %s", rr.Code, rr.Body.String())
        }
        var resp map[string]string
        if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
                t.Fatal(err)
        }
        if resp["token"] == "" {
                t.Fatal("empty token")
        }
}
```

Add tiny helpers in the same file or main.go: `bytesReader`, `errNotFound`, types `Account`, `Server`.

- [ ] **Step 2: Run tests — expect fail**

```bash
cd auth && go test ./...
```

Expected: fail (undefined Server / handlers)

- [ ] **Step 3: Implement `auth/main.go`**

```go
package main

import (
        "context"
        "encoding/json"
        "errors"
        "fmt"
        "log"
        "net/http"
        "os"
        "strings"
        "time"

        "github.com/golang-jwt/jwt/v5"
        "github.com/redis/go-redis/v9"
)

var errNotFound = errors.New("not found")

type Account struct {
        ID     string `json:"id"`
        Region string `json:"region"`
}

type Server struct {
        jwtSecret []byte
        lookup    func(email string) (*Account, error)
        rdb       *redis.Client
}

func main() {
        secret := []byte(envOr("JWT_SECRET", "cano-dev-secret"))
        rdb := redis.NewClient(&redis.Options{Addr: envOr("REDIS_ADDR", "127.0.0.1:6379")})
        s := &Server{
                jwtSecret: secret,
                rdb:       rdb,
                lookup: func(email string) (*Account, error) {
                        val, err := rdb.Get(context.Background(), "account:email:"+email).Result()
                        if err == redis.Nil {
                                return nil, errNotFound
                        }
                        if err != nil {
                                return nil, err
                        }
                        var a Account
                        if err := json.Unmarshal([]byte(val), &a); err != nil {
                                return nil, err
                        }
                        return &a, nil
                },
        }
        mux := http.NewServeMux()
        mux.HandleFunc("/login", s.handleLogin)
        mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
        // ExtAuth: Emissary AuthService posts to this path (or prefix)
        mux.HandleFunc("/", s.handleExtAuth)
        addr := envOr("LISTEN_ADDR", ":8080")
        log.Printf("auth listening on %s", addr)
        log.Fatal(http.ListenAndServe(addr, mux))
}

func envOr(k, d string) string {
        if v := os.Getenv(k); v != "" {
                return v
        }
        return d
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
        if r.Method != http.MethodPost {
                http.Error(w, "method", http.StatusMethodNotAllowed)
                return
        }
        var in struct {
                Email string `json:"email"`
        }
        if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.Email == "" {
                http.Error(w, "bad request", http.StatusBadRequest)
                return
        }
        acct, err := s.lookup(in.Email)
        if errors.Is(err, errNotFound) {
                http.Error(w, "unauthorized", http.StatusUnauthorized)
                return
        }
        if err != nil {
                http.Error(w, "redis", http.StatusServiceUnavailable)
                return
        }
        tok := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
                "sub":    acct.ID,
                "region": acct.Region,
                "exp":    time.Now().Add(2 * time.Hour).Unix(),
        })
        signed, err := tok.SignedString(s.jwtSecret)
        if err != nil {
                http.Error(w, "token", http.StatusInternalServerError)
                return
        }
        w.Header().Set("Content-Type", "application/json")
        _ = json.NewEncoder(w).Encode(map[string]string{"token": signed, "region": acct.Region})
}

func (s *Server) handleExtAuth(w http.ResponseWriter, r *http.Request) {
        path := r.URL.Path
        if p := r.Header.Get("X-Original-URL"); p != "" {
                // may be full URL
                if i := strings.Index(p, "://"); i >= 0 {
                        rest := p[i+3:]
                        if j := strings.Index(rest, "/"); j >= 0 {
                                path = rest[j:]
                        }
                } else if strings.HasPrefix(p, "/") {
                        path = p
                }
        }
        if path == "/login" || strings.HasPrefix(path, "/login?") {
                w.WriteHeader(http.StatusOK)
                return
        }
        // Also allow health through mapping if needed
        if path == "/healthz" {
                w.WriteHeader(http.StatusOK)
                return
        }
        authz := r.Header.Get("Authorization")
        if !strings.HasPrefix(authz, "Bearer ") {
                http.Error(w, "unauthorized", http.StatusUnauthorized)
                return
        }
        raw := strings.TrimPrefix(authz, "Bearer ")
        parsed, err := jwt.Parse(raw, func(t *jwt.Token) (interface{}, error) {
                if t.Method != jwt.SigningMethodHS256 {
                        return nil, fmt.Errorf("alg")
                }
                return s.jwtSecret, nil
        })
        if err != nil || !parsed.Valid {
                http.Error(w, "unauthorized", http.StatusUnauthorized)
                return
        }
        claims, ok := parsed.Claims.(jwt.MapClaims)
        if !ok {
                http.Error(w, "unauthorized", http.StatusUnauthorized)
                return
        }
        sub, _ := claims["sub"].(string)
        region, _ := claims["region"].(string)
        if sub == "" || (region != "us" && region != "eu") {
                http.Error(w, "unauthorized", http.StatusUnauthorized)
                return
        }
        w.Header().Set("x-region-target", region)
        w.Header().Set("x-account-id", sub)
        w.WriteHeader(http.StatusOK)
}
```

Fix test helper: use `bytes.NewReader` in TestLoginIssuesToken (import `bytes`).

- [ ] **Step 4: Run tests — expect pass**

```bash
cd auth && go mod tidy && go test ./...
```

Expected: PASS

- [ ] **Step 5: Dockerfile**

```dockerfile
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /auth .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /auth /auth
EXPOSE 8080
ENTRYPOINT ["/auth"]
```

- [ ] **Step 6: Commit**

```bash
git add auth
git commit -m "feat(auth): JWT login and ExtAuth region headers"
```

---

### Task 2: Boards service (Go) with unit tests

**Files:**
- Create: `boards/go.mod`, `boards/main.go`, `boards/main_test.go`, `boards/Dockerfile`

**Interfaces:**
- Consumes: env `REGION` (`us`|`eu`); request headers `x-account-id`, `x-region-target`
- Produces: `GET /boards/` → 200 JSON if header region matches `REGION`; 403 otherwise

- [ ] **Step 1: Write failing tests in `boards/main_test.go`**

```go
package main

import (
        "encoding/json"
        "net/http"
        "net/http/httptest"
        "testing"
)

func TestBoardsSameRegion(t *testing.T) {
        h := boardsHandler("us")
        req := httptest.NewRequest(http.MethodGet, "/boards/", nil)
        req.Header.Set("x-account-id", "alice")
        req.Header.Set("x-region-target", "us")
        rr := httptest.NewRecorder()
        h(rr, req)
        if rr.Code != 200 {
                t.Fatalf("%d", rr.Code)
        }
        var body map[string]string
        _ = json.Unmarshal(rr.Body.Bytes(), &body)
        if body["region"] != "us" || body["account"] != "alice" {
                t.Fatalf("%v", body)
        }
}

func TestBoardsCrossRegionForbidden(t *testing.T) {
        h := boardsHandler("us")
        req := httptest.NewRequest(http.MethodGet, "/boards/", nil)
        req.Header.Set("x-account-id", "bruno")
        req.Header.Set("x-region-target", "eu")
        rr := httptest.NewRecorder()
        h(rr, req)
        if rr.Code != http.StatusForbidden {
                t.Fatalf("%d", rr.Code)
        }
}
```

- [ ] **Step 2: Run — expect fail**

```bash
cd boards && go test ./...
```

- [ ] **Step 3: Implement `boards/main.go`**

```go
package main

import (
        "encoding/json"
        "log"
        "net/http"
        "os"
)

func main() {
        region := os.Getenv("REGION")
        if region != "us" && region != "eu" {
                log.Fatal("REGION must be us or eu")
        }
        mux := http.NewServeMux()
        mux.HandleFunc("/boards/", boardsHandler(region))
        mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
        addr := ":8080"
        if v := os.Getenv("LISTEN_ADDR"); v != "" {
                addr = v
        }
        log.Printf("boards region=%s on %s", region, addr)
        log.Fatal(http.ListenAndServe(addr, mux))
}

func boardsHandler(region string) http.HandlerFunc {
        return func(w http.ResponseWriter, r *http.Request) {
                acct := r.Header.Get("x-account-id")
                target := r.Header.Get("x-region-target")
                if acct == "" || target == "" {
                        http.Error(w, "missing auth headers", http.StatusUnauthorized)
                        return
                }
                if target != region {
                        http.Error(w, "wrong region", http.StatusForbidden)
                        return
                }
                w.Header().Set("Content-Type", "application/json")
                _ = json.NewEncoder(w).Encode(map[string]string{
                        "region":  region,
                        "account": acct,
                        "message": "board data for " + acct + " served from " + region,
                })
        }
}
```

- [ ] **Step 4: `go mod tidy && go test ./...` — PASS**

- [ ] **Step 5: Dockerfile** (same pattern as auth, binary `/boards`)

- [ ] **Step 6: Commit**

```bash
git add boards
git commit -m "feat(boards): regional boards service with privacy guard"
```

---

### Task 3: Redis seed + shared deploy manifests

**Files:**
- Create: `redis/seed.sh`, `deploy/common/*.yaml`, `deploy/common/emissary-istio-values.yaml`

**Interfaces:**
- Redis keys: `account:email:alice@example.com` = `{"id":"alice","region":"us"}` etc.
- Peer Auth STRICT in namespaces `emissary`, `demo`
- Auth/boards Deployments in namespace `demo` with Istio injection

- [ ] **Step 1: Write `redis/seed.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
REDIS_ADDR="${REDIS_ADDR:-127.0.0.1:6379}"
redis-cli -u "redis://${REDIS_ADDR}" SET 'account:email:alice@example.com' '{"id":"alice","region":"us"}'
redis-cli -u "redis://${REDIS_ADDR}" SET 'account:email:bruno@example.com' '{"id":"bruno","region":"eu"}'
```

- [ ] **Step 2: Write `deploy/common/namespaces.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: emissary
  labels:
    istio-injection: enabled
---
apiVersion: v1
kind: Namespace
metadata:
  name: demo
  labels:
    istio-injection: enabled
```

- [ ] **Step 3: Write `deploy/common/peer-authentication.yaml`**

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: demo
spec:
  mtls:
    mode: STRICT
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: emissary
spec:
  mtls:
    mode: STRICT
```

- [ ] **Step 4: Write `deploy/common/auth-deploy.yaml`**

Include Secret `jwt-secret` (`cano-dev-secret`), Deployment `auth` image `cano/auth:local`, env `REDIS_ADDR=host.k3d.internal:6379` **or** Redis container IP reachable as `cano-redis:6379` via extraHosts — prefer running Redis with `--network cano-multi --name cano-redis` and set `REDIS_ADDR=cano-redis:6379` plus k3d `--host-alias` / CoreDNS entry. **Decision for up.sh:** add hosts entry `cano-redis` → Redis container IP in both clusters via `k3d node edit` or ConfigMap CoreDNS rewrite. Simplest reliable approach: publish Redis on host `6379` and use `host.docker.internal:6379` from pods (works on Docker Desktop macOS). Spec stand-in: use `REDIS_ADDR=host.docker.internal:6379`.

Deployment ports 8080; Service `auth` ports 80→8080 and 443→8080.

- [ ] **Step 5: Write `deploy/common/boards-deploy.yaml`** with placeholder `REGION` replaced by up.sh via `sed` or kustomize — use two files in Task 4 instead: keep template with `env REGION` set per overlay.

Actually create `deploy/common/boards-deploy.yaml` with `value: PLACEHOLDER_REGION` and substitute in up.sh.

- [ ] **Step 6: Write `deploy/common/emissary-istio-values.yaml`** exactly from Emissary Istio howto (createDefaultListeners, podAnnotations, volumes, volumeMounts, env AMBASSADOR_*).

- [ ] **Step 7: Write TLSContext, AuthService, Listener/Host if needed**

```yaml
# tls-context.yaml
apiVersion: getambassador.io/v3alpha1
kind: TLSContext
metadata:
  name: istio-upstream
  namespace: emissary
spec:
  secret: istio-certs
  alpn_protocols: istio
---
# auth-service.yaml  
apiVersion: getambassador.io/v3alpha1
kind: AuthService
metadata:
  name: demo-auth
  namespace: emissary
spec:
  auth_service: auth.demo:80
  proto: http
  path_prefix: /
  allowed_request_headers:
    - Authorization
    - Cookie
  allowed_authorization_headers:
    - x-region-target
    - x-account-id
```

Note: AuthService in emissary ns calling `auth.demo` — need allow cross-namespace (default in K8s DNS works). Istio mTLS: Emissary→auth also needs Mapping tls or PeerAuth permissive for auth during bring-up. **Use STRICT and Mapping for login/boards with tls; AuthService traffic from Emissary sidecar to auth sidecar should auto-mTLS.**

- [ ] **Step 8: Commit**

```bash
git add redis deploy/common
git commit -m "feat(deploy): shared Redis seed and common K8s manifests"
```

---

### Task 4: Per-region mappings (handover + local)

**Files:**
- Create: `deploy/us/handover-mapping.yaml`, `deploy/us/local-mappings.yaml`, `deploy/eu/handover-mapping.yaml`, `deploy/eu/local-mappings.yaml`

**Interfaces:**
- US handover: headers `x-region-target: eu` → `http://k3d-cano-eu-serverlb:80`
- EU handover: headers `x-region-target: us` → `http://k3d-cano-us-serverlb:80`

- [ ] **Step 1: US handover**

```yaml
apiVersion: getambassador.io/v3alpha1
kind: Mapping
metadata:
  name: handover-to-eu
  namespace: emissary
spec:
  hostname: "*"
  precedence: 100
  prefix: /
  headers:
    x-region-target: eu
  service: http://k3d-cano-eu-serverlb:80
  add_response_headers:
    x-routed-from: us
    x-routed-to: eu
  timeout_ms: 60000
  connect_timeout_ms: 6000
  idle_timeout_ms: 300000
  cluster_idle_timeout_ms: 300000
```

- [ ] **Step 2: US local mappings**

```yaml
apiVersion: getambassador.io/v3alpha1
kind: Mapping
metadata:
  name: login
  namespace: emissary
spec:
  hostname: "*"
  prefix: /login
  service: auth.demo:80
  timeout_ms: 10000
---
apiVersion: getambassador.io/v3alpha1
kind: Mapping
metadata:
  name: boards
  namespace: emissary
spec:
  hostname: "*"
  prefix: /boards/
  service: boards.demo:80
  tls: istio-upstream
  timeout_ms: 15000
```

- [ ] **Step 3: Mirror for EU** (handover to us; response headers swapped; boards REGION=eu via up.sh)

- [ ] **Step 4: Commit**

```bash
git add deploy/us deploy/eu
git commit -m "feat(deploy): regional handover and local Emissary mappings"
```

---

### Task 5: Scripts — up / down / demo / lib

**Files:**
- Create: `scripts/lib.sh`, `scripts/up.sh`, `scripts/down.sh`, `scripts/demo.sh`

**Interfaces:**
- `up.sh` creates network, Redis, clusters, installs Istio 1.23.3, Emissary, imports images, applies manifests, waits ready
- `demo.sh` hits `http://127.0.0.1:8080` (US) for flows A–C
- Install k3d/istioctl if missing (curl install scripts)

- [ ] **Step 1: `scripts/lib.sh`** — helpers: `need_cmd`, `ensure_network`, `cluster_ctx` (`k3d kubeconfig merge`), `wait_deploy`, `REDIS_NAME=cano-redis`

- [ ] **Step 2: `scripts/up.sh`** sequence:

1. Ensure docker network `cano-multi`
2. Run Redis: `docker run -d --rm --name cano-redis --network cano-multi -p 6379:6379 redis:7-alpine`
3. Seed via `docker run --rm --network cano-multi redis:7-alpine redis-cli -h cano-redis SET ...`
4. Create clusters if missing:
   ```bash
   k3d cluster create cano-us --network cano-multi \
     -p "8080:80@loadbalancer" -p "8443:443@loadbalancer" --k3s-arg "--disable=traefik@server:0"
   k3d cluster create cano-eu --network cano-multi \
     -p "8081:80@loadbalancer" -p "8444:443@loadbalancer" --k3s-arg "--disable=traefik@server:0"
   ```
5. Build images `cano/auth:local` `cano/boards:local`; `k3d image import` into both
6. For each cluster: install Istio (`istioctl install -y --set profile=default`), apply namespaces, PeerAuthentication, auth+boards (REGION), secret
7. Helm repo add datawire; helm install emissary with values file in emissary ns; wait
8. Apply TLSContext, AuthService, mappings
9. Print endpoints

- [ ] **Step 3: `scripts/down.sh`** — delete clusters, stop redis, optional remove network

- [ ] **Step 4: `scripts/demo.sh`**

```bash
US=http://127.0.0.1:8080
# Flow A
TOKEN_ALICE=$(curl -sf -X POST "$US/login" -H 'content-type: application/json' -d '{"email":"alice@example.com"}' | jq -r .token)
RESP=$(curl -si "$US/boards/" -H "Authorization: Bearer $TOKEN_ALICE")
echo "$RESP" | grep -q '"region":"us"' 
echo "$RESP" | grep -qi 'x-routed-to' && exit 1  # must NOT be handed over
# Flow B
TOKEN_BRUNO=$(curl -sf -X POST "$US/login" -H 'content-type: application/json' -d '{"email":"bruno@example.com"}' | jq -r .token)
RESP=$(curl -si "$US/boards/" -H "Authorization: Bearer $TOKEN_BRUNO")
echo "$RESP" | grep -q 'x-routed-from: us'
echo "$RESP" | grep -q 'x-routed-to: eu'
echo "$RESP" | grep -q '"region":"eu"'
# Flow C
code=$(curl -s -o /dev/null -w '%{http_code}' "$US/boards/")
test "$code" = "401"
echo "ALL PASS"
```

- [ ] **Step 5: Make executable; commit**

```bash
chmod +x scripts/*.sh redis/seed.sh
git add scripts redis/seed.sh
git commit -m "feat(scripts): up, down, and curl demo for dual-region handover"
```

---

### Task 6: README + end-to-end verification

**Files:**
- Create: `README.md`
- Modify: `.gitignore` if needed (`*.sum` keep tracked)

- [ ] **Step 1: Write README** — prerequisites (Docker Desktop, install k3d/helm/kubectl/istioctl/jq/go), `./scripts/up.sh`, `./scripts/demo.sh`, architecture summary, pointer to design spec

- [ ] **Step 2: Run `./scripts/up.sh`** on this machine; fix issues until Deployments Ready

- [ ] **Step 3: Run `./scripts/demo.sh`** — expect `ALL PASS`

- [ ] **Step 4: Commit README**

```bash
git add README.md
git commit -m "docs: README for local multi-region demo"
```

---

## Spec coverage checklist

| Spec requirement | Task |
|------------------|------|
| Dual k3d + cano-multi | 5 |
| Istio STRICT per region | 3, 5 |
| Emissary Istio certs + TLSContext | 3, 5 |
| JWT ExtAuth + shared Redis | 1, 3, 5 |
| Seed alice/bruno | 3, 5 |
| Handover Mapping precedence 100 | 4 |
| boards privacy guard | 2 |
| demo.sh Flows A–C | 5, 6 |
| up/down scripts | 5 |
| Out of scope items omitted | — |

## Self-review notes

- Auth ExtAuth path detection uses URL path and `X-Original-URL`; login Mapping still hits AuthService first — bypass in ExtAuth required (implemented).
- Redis via `host.docker.internal:6379` on macOS Docker Desktop; document Linux alternative (`--add-host=host.docker.internal:host-gateway` on k3d create).
- Emissary chart version: pin in up.sh after `helm search repo datawire/emissary` at implementation time (e.g. `--version 8.9.1` or current stable).

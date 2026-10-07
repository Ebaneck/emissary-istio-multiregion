# Multi-Region Emissary + Istio Local Demo — Design

**Date:** 2026-10-07  
**Status:** Approved for implementation planning  
**Goal:** Run a privacy-first dual-region edge locally (Monday.com-style handover) with Emissary Ingress + Istio, and prove it with curl.

## Motivation

Build a laptop-complete demo of:

1. **Monday.com multi-regional pattern** — independent regions, global/replicated auth, high-precedence regional handover when traffic enters the wrong region.
2. **Emissary + Istio integration** — Emissary for north-south edge routing; Istio for east-west mTLS within each region.

Primary design driver: **privacy-first** (user content stays in home region). Performance and resilience are secondary benefits, not the optimization target.

## Decisions (locked)

| Topic | Choice |
|--------|--------|
| Success criteria | Full routing demo (auth → `x-region-target` → handover → regional backend); curl-provable |
| Topology | Two k3d clusters (`cano-us`, `cano-eu`) on shared Docker network `cano-multi` |
| Auth | JWT ExtAuth in both clusters; shared Redis as stand-in for replicated auth store |
| Tooling | k3d (preferred for macOS dual-cluster reliability) |
| Approach | Dual cluster + Emissary + Istio-per-region + shared Redis (not Istio multi-cluster mesh) |

## Architecture

```
curl → US Emissary (default ingress for ambiguous hosts)
         → ExtAuth (JWT) → Redis (shared)
         → if x-region-target ≠ us: Mapping precedence=100 → EU Emissary
         → else: Mapping → boards-us via Istio mTLS

Each cluster: Istio STRICT PeerAuthentication, sidecar injection on emissary + apps.
Regions do not share a mesh. Handover is Emissary → Emissary over Docker network.
```

### Properties (Monday-aligned)

- Each region is independently deployable and can fail without taking the other offline (for local traffic already in that region).
- Users can hit either region’s Emissary entrypoint.
- Auth metadata is available in both regions (shared Redis).
- Vendor-neutral regional routing: no Cloudflare / edge-worker dependency.

## Components

### Infra

- Docker network `cano-multi`
- k3d clusters `cano-us` and `cano-eu` attached to that network
- Port mappings (or documented LoadBalancer URLs) for each Emissary (HTTP/HTTPS) so host curl works
- Scripts: `scripts/up.sh`, `scripts/down.sh`, `scripts/demo.sh`

### Istio (per cluster)

- Install supported Istio (≥1.10 per Emissary docs; pin a recent stable in the plan)
- Label namespaces for `istio-injection=enabled` (emissary + regional apps)
- `PeerAuthentication` mode `STRICT` in app namespaces (and document testing under permissive if needed during bring-up)
- No multi-cluster Istio, east-west gateways between regions, or shared control plane

### Emissary (per cluster)

- Helm install from datawire chart with Istio integration values:
  - pod annotations for Istio cert output / inbound skip as in Emissary Istio howto
  - `istio-certs` emptyDir volume + mounts
  - `AMBASSADOR_ISTIO_SECRET_DIR=/etc/istio-certs`
  - `AMBASSADOR_ENVOY_BASE_ID=1`
  - `createDefaultListeners: true`
- `TLSContext` named `istio-upstream` referencing secret `istio-certs`, `alpn_protocols: istio`
- AuthService (HTTP protocol) pointing at local ExtAuth; **bypass** ExtAuth for `POST /login` so login does not require a JWT
- Host/hostname for Mappings: `*` (no custom DNS required for the demo)

### Auth (replicated topology)

- **Language:** small Go services (single static binary; easy to bake into k3d via local image import).
- **Redis:** single Docker container on `cano-multi`, reachable from both clusters (explicit stand-in for real-time replicated DB; not true replication).
- **Auth service (deployed in both clusters):**
  - `POST /login` — body `{ "email": "…" }`; looks up email → `{accountId, region}` in Redis; issues HS256 JWT (shared secret as K8s Secret applied identically in both clusters). Claims include `sub` (account id) and `region`.
  - ExtAuth HTTP endpoint — validates `Authorization: Bearer`; on success returns 200 and injects:
    - `x-region-target: us|eu`
    - `x-account-id: <id>`
  - Seed data written at Redis start: `alice@example.com` → us; `bruno@example.com` → eu

### Regional applications

- `boards` image parameterized by `REGION=us|eu` (deployed only in home cluster as `boards`)
- Minimal HTTP API: `GET /boards/` returns JSON `{ "region", "account", "message" }` using `x-account-id`
- Returns 403 if JWT/account region (from headers) ≠ this instance’s `REGION` (privacy guard)
- Kubernetes Service maps port 80 (and 443) to container port
- Emissary Mapping uses `service: boards:80` and `tls: istio-upstream`

### Routing hierarchy (per Emissary)

1. **Handover Mapping(s)** — `precedence: 100`, match header `x-region-target` equal to the *other* region, `prefix: /`, `service` = peer Emissary HTTP URL on Docker network (k3d node IP / published port); add response headers `x-routed-from`, `x-routed-to`; timeouts suitable for local (e.g. 60s request, elevated idle).
2. **Local app Mappings** — lower precedence; `/login` → auth service; `/boards/` → boards.
3. Loop prevention: after handover, destination ExtAuth sets matching `x-region-target`; handover Mapping only matches the foreign region value.

## Request flows (acceptance criteria)

### Flow A — Correct region (no handover)

1. Login as alice → JWT with region us.
2. `GET` US Emissary `/boards/` with Bearer.
3. Expect 200 from `boards-us`; no handover response headers (or no `x-routed-to`).

### Flow B — Wrong region (handover) — primary demo

1. Login as bruno → JWT with region eu.
2. `GET` US Emissary `/boards/` with Bearer.
3. Expect 200 from `boards-eu`; response headers `x-routed-from: us`, `x-routed-to: eu`.

### Flow C — Guards

1. Invalid/missing JWT → 401 from ExtAuth.
2. Optional: Mapping without `tls` under STRICT → upstream failure (documents Istio requirement).
3. Regional app refuses cross-region account if somehow reached without going through correct routing.

`scripts/demo.sh` automates A–C and prints pass/fail.

## Error handling

| Condition | Behavior |
|-----------|----------|
| Missing/invalid JWT | 401 ExtAuth |
| Unknown email on login | 401 |
| Peer Emissary unreachable | 503 on handover |
| Redis down | Auth failures (login + ExtAuth) |
| Wrong-region re-entry after hop | Not re-proxied; local route applies |

## Out of scope

- Cloudflare, WAF, real DNS slug routing
- True database replication / conflict resolution
- Prometheus, Grafana, Zipkin (Istio howto extras)
- Third region, production TLS certificates, AWS NLB / Transit Gateway fidelity
- Istio multi-cluster mesh spanning US↔EU

## Repo layout (planned)

```
cano/
  README.md
  .gitignore
  scripts/up.sh down.sh demo.sh
  infra/          # k3d / docker network helpers
  redis/          # compose or run script for shared Redis
  auth/           # ExtAuth + login service source + Dockerfile
  boards/         # regional demo service source + Dockerfile
  deploy/
    us/           # cluster-specific overlays (handover target = eu)
    eu/
    common/       # shared Mapping templates, PeerAuthentication, etc.
  docs/superpowers/specs/…
```

## Testing

- Manual: README curl examples for A/B/C.
- Automated: `scripts/demo.sh` after `up.sh`.
- Bring-up verification: wait for Emissary Deployments available; Istio sidecars present on emissary and boards pods; Redis ping from auth pods.

## Success definition

A developer with Docker, k3d, helm, kubectl, and istioctl can run `./scripts/up.sh`, then `./scripts/demo.sh`, and see Flows A and B pass—including visible `x-routed-from` / `x-routed-to` on the wrong-region path—without cloud accounts.

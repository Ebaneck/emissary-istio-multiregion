# cano — local multi-region Emissary + Istio demo

Privacy-first dual-region edge on one laptop, inspired by [monday.com’s multi-regional architecture](https://engineering.monday.com/monday-coms-multi-regional-architecture-a-deep-dive/) and the [Emissary + Istio howto](https://emissary-ingress.dev/docs/4.0/howtos/istio/).

## What you get

- Two **k3d** clusters (`cano-us`, `cano-eu`) on Docker network `cano-multi`
- **Emissary** at each edge with JWT **ExtAuth** and high-precedence regional **handover**
- **Istio** STRICT mTLS east-west inside each region
- Shared **Redis** as the stand-in for replicated auth metadata
- Regional **boards** services that refuse cross-region accounts

## Prerequisites

- Docker Desktop (or Docker Engine)
- [Helm](https://helm.sh/) 3, [kubectl](https://kubernetes.io/docs/tasks/tools/), Go 1.22+, [jq](https://jqlang.github.io/jq/)
- `./scripts/up.sh` installs **k3d** and **istioctl** if missing

## Quick start

```bash
./scripts/up.sh    # several minutes first time
./scripts/demo.sh  # Flows A–C; expect ALL PASS
./scripts/down.sh  # tear down clusters + redis
```

| Endpoint | URL |
|----------|-----|
| US Emissary | http://127.0.0.1:8080 |
| EU Emissary | http://127.0.0.1:8081 |
| Redis | localhost:6379 |

Seeded accounts: `alice@example.com` → us, `bruno@example.com` → eu.

### Manual curl

```bash
# Login
TOKEN=$(curl -s -X POST http://127.0.0.1:8080/login \
  -H 'content-type: application/json' \
  -d '{"email":"bruno@example.com"}' | jq -r .token)

# Wrong-region entry → handover US → EU
curl -si http://127.0.0.1:8080/boards/ -H "Authorization: Bearer $TOKEN"
# Look for x-routed-from: us / x-routed-to: eu and "region":"eu"
```

## Design & plan

- Spec: `docs/superpowers/specs/2026-10-07-multi-region-emissary-istio-design.md`
- Plan: `docs/superpowers/plans/2026-10-07-multi-region-emissary-istio.md`

#!/usr/bin/env bash
set -euo pipefail

US="${US_URL:-http://127.0.0.1:8080}"
EU="${EU_URL:-http://127.0.0.1:8081}"

need_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for demo.sh" >&2
    exit 1
  fi
}

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

need_jq

echo "==> Flow A: alice via US (no handover)"
TOKEN_ALICE="$(curl -sf -X POST "$US/login" -H 'content-type: application/json' -d '{"email":"alice@example.com"}' | jq -r .token)"
[[ -n "$TOKEN_ALICE" && "$TOKEN_ALICE" != null ]] || fail "alice login"
RESP_A="$(curl -si "$US/boards/" -H "Authorization: Bearer $TOKEN_ALICE")"
echo "$RESP_A" | grep -q '"region":"us"' || fail "alice body region us"
echo "$RESP_A" | grep -qi 'x-routed-to' && fail "alice should not be handed over"
pass "Flow A"

echo "==> Flow B: bruno via US (handover to EU)"
TOKEN_BRUNO="$(curl -sf -X POST "$US/login" -H 'content-type: application/json' -d '{"email":"bruno@example.com"}' | jq -r .token)"
[[ -n "$TOKEN_BRUNO" && "$TOKEN_BRUNO" != null ]] || fail "bruno login"
RESP_B="$(curl -si "$US/boards/" -H "Authorization: Bearer $TOKEN_BRUNO")"
echo "$RESP_B" | grep -qi 'x-routed-from: us' || fail "missing x-routed-from: us"
echo "$RESP_B" | grep -qi 'x-routed-to: eu' || fail "missing x-routed-to: eu"
echo "$RESP_B" | grep -q '"region":"eu"' || fail "bruno body region eu"
pass "Flow B"

echo "==> Flow C: unauthenticated"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "$US/boards/")"
[[ "$CODE" == "401" ]] || fail "expected 401 got $CODE"
pass "Flow C"

echo "==> sanity: bruno direct to EU (no handover headers required)"
RESP_EU="$(curl -si "$EU/boards/" -H "Authorization: Bearer $TOKEN_BRUNO")"
echo "$RESP_EU" | grep -q '"region":"eu"' || fail "direct EU bruno"
pass "EU direct"

echo ""
echo "ALL PASS"

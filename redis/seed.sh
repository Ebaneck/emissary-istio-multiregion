#!/usr/bin/env bash
set -euo pipefail
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET 'account:email:alice@example.com' '{"id":"alice","region":"us"}'
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET 'account:email:bruno@example.com' '{"id":"bruno","region":"eu"}'
echo "seeded alice@example.com -> us, bruno@example.com -> eu"

#!/usr/bin/env bash
# Regenerates every virtual mock in postman/mocks/<service> from its
# submodule's current spec (stateful mode), smoke-tests each one, then
# the caller (CI or you, locally) pushes what changed.
#
# Why a smoke test and not a full collection run: `postman mock generate
# --mode stateful` maps flat CRUD resources well (GET list/by-id, PUT
# replace-by-id), but a spec's non-CRUD "action" endpoints (reserve,
# checkout) and nested array sub-resources (cart items) come out wrong
# -- generic {id, ...echoedBody} responses with the wrong status code
# instead of the real resource, and in cart-service's case, PUT
# /api/cart/items/:id outright hangs the server (confirmed with a
# direct curl timeout, independent of this script). Running each
# service's hand-authored collection against that output would just
# fail or hang on gaps in the generator, not in what we're testing.
# The smoke test instead confirms the one thing that matters for this
# pipeline: the regenerated mock starts and answers its primary read
# endpoint. See README.md for the full writeup.
#
# To add a 5th/6th/Nth service: add one submodule, one `mock generate`
# call (see README), and one line each to collection_for()/port_for()/
# smoke_check() below, and to SERVICES. (Plain case statements, not
# associative arrays, on purpose -- macOS ships bash 3.2, which has no
# associative arrays.)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

SERVICES="product-service cart-service order-service inventory-service"

port_for() {
  case "$1" in
    product-service) echo 4501 ;;
    cart-service) echo 4502 ;;
    order-service) echo 4503 ;;
    inventory-service) echo 4504 ;;
    *) echo "unknown service: $1" >&2; exit 1 ;;
  esac
}

# One safe, read-only request per service that proves the regenerated
# mock is actually serving real data, not just that the port is open.
smoke_check() {
  local svc="$1" port="$2"
  case "$svc" in
    product-service) curl -sf -m 5 "http://localhost:${port}/api/products" | grep -q '"id"' ;;
    cart-service)    curl -sf -m 5 "http://localhost:${port}/api/cart" | grep -q '"items"' ;;
    order-service)   curl -sf -m 5 "http://localhost:${port}/api/orders" >/dev/null ;;
    inventory-service) curl -sf -m 5 "http://localhost:${port}/api/inventory" | grep -q '"productId"' ;;
    *) echo "unknown service: $1" >&2; return 1 ;;
  esac
}

for svc in $SERVICES; do
  echo "::group::${svc}"
  echo "-- regenerating postman/mocks/${svc} from services/${svc}'s current spec --"
  postman mock generate --update "postman/mocks/${svc}"

  port=$(port_for "$svc")
  echo "-- smoke-testing the regenerated mock on :${port} --"
  postman mock run "postman/mocks/${svc}" --port "${port}" --no-history &
  mock_pid=$!

  # Not every service's spec defines /health (cart-service's doesn't), so
  # readiness means "the server answers HTTP at all", not "2xx on /health".
  ready=0
  for _ in $(seq 1 20); do
    if curl -s -m 2 -o /dev/null "http://localhost:${port}/health"; then
      ready=1
      break
    fi
    sleep 0.5
  done

  ok=0
  if [ "${ready}" -eq 1 ] && smoke_check "${svc}" "${port}"; then
    ok=1
  fi

  # `postman mock run` spawns deeper worker processes that outlive the PID
  # bash captured in $mock_pid, so `wait` on that PID alone can hang.
  # Kill by port instead and don't block on it -- each service uses its
  # own port, so a slow-to-die process here can't affect the next one.
  lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null | xargs -r kill 2>/dev/null || true
  disown "${mock_pid}" 2>/dev/null || true

  if [ "${ok}" -ne 1 ]; then
    echo "::error::${svc}'s regenerated virtual mock failed its smoke test -- not pushing anything"
    exit 1
  fi
  echo "${svc}: OK"
  echo "::endgroup::"
done

echo "All virtual mocks regenerated and smoke-tested."

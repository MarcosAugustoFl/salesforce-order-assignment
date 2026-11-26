#!/usr/bin/env bash
# Sends ONE signed event to the deployed endpoint. Handy for live "what if…?" tests.
#
#   ./scripts/curl/send-event.sh <status> <occurredAt> [orderId] [eventId]
#
# Examples
#   ./scripts/curl/send-event.sh cleared  2026-10-13T09:00:00Z                       # newer -> APPLIED
#   ./scripts/curl/send-event.sh inProgress 2026-10-01T09:00:00Z                     # older -> IGNORED
#   ./scripts/curl/send-event.sh sent 2026-10-12T14:03:11Z ord_77d1e9 evt_004        # same id -> DUPLICATE
#   ./scripts/curl/send-event.sh inProgress 2026-11-01T10:00:00Z ord_brand_new       # new order is created
#   BAD_SIGNATURE=1 ./scripts/curl/send-event.sh cleared 2026-10-13T09:00:00Z        # -> 401
#   ORG=my-alias ./scripts/curl/send-event.sh ...                                    # another org alias
#
# Status: created | inProgress | waitingForParticipant | sent | cleared | returned
set -euo pipefail

if [ $# -lt 2 ]; then sed -n '2,15p' "$0"; exit 1; fi
STATUS="$1"
OCCURRED_AT="$2"
ORDER_ID="${3:-ord_77d1e9}"
EVENT_ID="${4:-evt_live_$(date +%s)}"
ORG="${ORG:-order-assignment}"
SECRET="${ORDERS_WEBHOOK_SECRET:-orders-takehome-2026}"

ORG_JSON="$(sf org display --target-org "$ORG" --json 2>/dev/null)"
TOKEN="$(printf '%s' "$ORG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["accessToken"])')"
INSTANCE="$(printf '%s' "$ORG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["instanceUrl"])')"

BODY="{\"subscriptionId\":\"sub_a1b2c3d4e5f67890abcdef12\",\"event\":{\"id\":\"$EVENT_ID\",\"type\":\"order.$STATUS\",\"occurredAt\":\"$OCCURRED_AT\",\"version\":\"1.0\"},\"data\":{\"orderId\":\"$ORDER_ID\",\"orderFriendlyId\":\"OR-$ORDER_ID\",\"accountId\":\"acct_8f3c2a\",\"accountFriendlyId\":\"AC-260914-017-2231\"}}"
KEY="$SECRET"; [ -n "${BAD_SIGNATURE:-}" ] && KEY="wrong-secret"
SIGNATURE="$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$KEY" | awk '{print $NF}')"

echo "→ $EVENT_ID  order.$STATUS  occurredAt=$OCCURRED_AT  order=$ORDER_ID"
curl -sS -X POST "$INSTANCE/services/apexrest/orders/events" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Orders-Signature: $SIGNATURE" \
  --data-binary "$BODY" \
  -w '  (HTTP %{http_code})\n'

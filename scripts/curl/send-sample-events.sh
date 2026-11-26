#!/usr/bin/env bash
# Sends the spec's sample events to the deployed endpoint over HTTPS, signed like Orders would sign them.
#
#   ./scripts/curl/send-sample-events.sh [org-alias]
#
# Auth, either:
#   - default: the access token of your Salesforce CLI session for the org, or
#   - like the real sender: set ORDERS_CLIENT_ID and ORDERS_CLIENT_SECRET (External Client App consumer key/secret)
#     and the script gets a token for the integration user via the OAuth Client Credentials flow (see README).
set -euo pipefail
cd "$(dirname "$0")/../.."

ORG="${1:-order-assignment}"
SECRET="${ORDERS_WEBHOOK_SECRET:-orders-takehome-2026}"
EVENTS="scripts/data/sample-events.ndjson"

ORG_JSON="$(sf org display --target-org "$ORG" --json 2>/dev/null)"
INSTANCE="$(printf '%s' "$ORG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["instanceUrl"])')"
if [ -n "${ORDERS_CLIENT_ID:-}" ] && [ -n "${ORDERS_CLIENT_SECRET:-}" ]; then
  echo "Authenticating as the integration user (Client Credentials flow)"
  TOKEN="$(curl -sS -X POST "$INSTANCE/services/oauth2/token" \
    --data-urlencode grant_type=client_credentials \
    --data-urlencode "client_id=$ORDERS_CLIENT_ID" \
    --data-urlencode "client_secret=$ORDERS_CLIENT_SECRET" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r.get("access_token") or sys.exit("token error: %s" % r))')"
else
  echo "Authenticating with your Salesforce CLI session"
  TOKEN="$(printf '%s' "$ORG_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["accessToken"])')"
fi
URL="$INSTANCE/services/apexrest/orders/events"

post() { # body signature
  curl -sS -X POST "$URL" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "Orders-Signature: $2" \
    --data-binary "$1" \
    -w '  -> HTTP %{http_code}\n'
}

sign() { printf '%s' "$1" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}'; }

while IFS= read -r body; do
  [ -z "$body" ] && continue
  printf '%s ' "$(printf '%s' "$body" | python3 -c 'import json,sys; e=json.load(sys.stdin)["event"]; print(e["id"], e["type"])')"
  post "$body" "$(sign "$body")"
done < "$EVENTS"

echo "Late event: inProgress from 2026-10-11 arriving after 'sent' (2026-10-12). Expect IGNORED, status stays sent:"
late='{ "subscriptionId": "sub_a1b2c3d4e5f67890abcdef12", "event": { "id": "evt_late_demo", "type": "order.inProgress", "occurredAt": "2026-10-11T12:00:00Z", "version": "1.0" }, "data": { "orderId": "ord_77d1e9", "orderFriendlyId": "OR-261001-017-2231", "accountId": "acct_8f3c2a", "accountFriendlyId": "AC-260914-017-2231" } }'
post "$late" "$(sign "$late")"

echo "Tampered body (signature of the original) should be rejected:"
original="$(head -n1 "$EVENTS")"
post "${original/order.inProgress/order.returned}" "$(sign "$original")"

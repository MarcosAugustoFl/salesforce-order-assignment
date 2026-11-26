#!/usr/bin/env bash
# Creates a Postman environment with your org's instance URL and a current access token.
#   ./scripts/postman/make-environment.sh [org-alias]
# Then in Postman: Import → the generated file → select "Orders - <alias>" (top right).
# Tokens expire with the Salesforce session (default 2 hours): re-run and re-import if you get 401 INVALID_SESSION_ID.
set -euo pipefail
cd "$(dirname "$0")"
ORG="${1:-order-assignment}"
OUT="local-${ORG}.postman_environment.json"
sf org display --target-org "$ORG" --json 2>/dev/null | ORG="$ORG" python3 -c '
import json, os, sys
r = json.load(sys.stdin)["result"]
print(json.dumps({
  "name": "Orders - " + os.environ["ORG"],
  "values": [
    {"key": "instanceUrl", "value": r["instanceUrl"], "type": "default", "enabled": True},
    {"key": "accessToken", "value": r["accessToken"], "type": "secret", "enabled": True},
  ],
}, indent=2))' > "$OUT"
echo "Wrote scripts/postman/$OUT (contains a session token: do not commit or share)."

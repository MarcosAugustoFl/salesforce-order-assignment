#!/usr/bin/env bash
# Prints the current orders and their event history from the org.
#   ./scripts/show-state.sh [org-alias]
set -euo pipefail
ORG="${1:-order-assignment}"
echo "ORDERS"
sf data query --target-org "$ORG" --query \
  "SELECT Order_Id__c, Status__c, Status_As_Of__c, Last_Event_Id__c, Sync_Error__c FROM External_Order__c ORDER BY Order_Id__c" \
  2>/dev/null | grep -v -E "^Querying|^$"
echo
echo "EVENTS (newest first)"
sf data query --target-org "$ORG" --query \
  "SELECT External_Order__r.Order_Id__c, Event_Id__c, Status__c, Occurred_At__c, Outcome__c, Delivery_Count__c FROM External_Order_Event__c ORDER BY CreatedDate DESC LIMIT 20" \
  2>/dev/null | grep -v -E "^Querying|^$"

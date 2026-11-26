/**
 * Writes what the Orders API returned (accounts, orders, lines) into Salesforce.
 * Shared by OrderDetailsSyncJob and AccountOrdersBackfillJob so both follow the same rules:
 *
 *  - The API's status only replaces ours if its updatedAt is newer (OrderStatus.supersedes). An event can
 *    land while a callout is in flight, and an older API snapshot must never undo it.
 *  - Existing orders are locked (FOR UPDATE) before writing, which serialises this with the webhook.
 *  - Fields the response does not carry are left untouched (list items have no participant or lines).
 *
 * without sharing: same reason as OrderEventService. A system sync must see every record it may update.
 */
public without sharing class ExternalOrderWriter {
    /**
     * Upserts orders from API data.
     * @param accountIdForNewOrders Account for orders not yet in Salesforce (backfill). If null, unknown orders are skipped.
     * @return the saved records, keyed by Orders order id
     */
    public Map<String, External_Order__c> applyOrders(List<OrdersApiClient.ApiOrder> apiOrders, Id accountIdForNewOrders) {
        Map<String, External_Order__c> saved = new Map<String, External_Order__c>();
        if (apiOrders.isEmpty()) {
            return saved;
        }
        Set<String> orderIds = new Set<String>();
        for (OrdersApiClient.ApiOrder apiOrder : apiOrders) {
            orderIds.add(apiOrder.id);
        }
        Map<String, External_Order__c> existing = new Map<String, External_Order__c>();
        for (External_Order__c order : [
            SELECT Id, Order_Id__c, Status__c, Status_As_Of__c, Details_Synced_At__c
            FROM External_Order__c
            WHERE Order_Id__c IN :orderIds
            FOR UPDATE
        ]) {
            existing.put(order.Order_Id__c, order);
        }

        List<OrdersApiClient.ApiOrder> detailed = new List<OrdersApiClient.ApiOrder>();
        for (OrdersApiClient.ApiOrder apiOrder : apiOrders) {
            External_Order__c order = existing.get(apiOrder.id);
            if (order == null) {
                if (accountIdForNewOrders == null) {
                    continue; // deleted in Salesforce meanwhile; nothing to update
                }
                order = new External_Order__c(Order_Id__c = apiOrder.id, Account__c = accountIdForNewOrders);
            }
            copyFields(apiOrder, order);
            saved.put(apiOrder.id, order);
            if (apiOrder.hasDetails) {
                detailed.add(apiOrder);
            }
        }
        upsert saved.values() Order_Id__c;
        replaceLines(detailed, saved);
        return saved;
    }

    /** Replaces placeholder names and refreshes Orders fields on the matching Accounts. */
    public void applyAccounts(List<OrdersApiClient.ApiAccount> apiAccounts) {
        Map<String, OrdersApiClient.ApiAccount> byOrdersId = new Map<String, OrdersApiClient.ApiAccount>();
        for (OrdersApiClient.ApiAccount apiAccount : apiAccounts) {
            byOrdersId.put(apiAccount.id, apiAccount);
        }
        List<Account> accounts = [
            SELECT Id, Orders_Account_Id__c
            FROM Account
            WHERE Orders_Account_Id__c IN :byOrdersId.keySet()
        ];
        for (Account acc : accounts) {
            OrdersApiClient.ApiAccount apiAccount = byOrdersId.get(acc.Orders_Account_Id__c);
            if (String.isNotBlank(apiAccount.name)) {
                acc.Name = apiAccount.name;
            }
            acc.Orders_Friendly_Id__c = apiAccount.friendlyId;
            acc.Orders_Status__c = apiAccount.status;
            acc.Orders_Synced_At__c = Datetime.now();
        }
        update accounts;
    }

    /** Records why an order could not be read, so an agent can see the copy may be stale. */
    public void recordSyncErrors(Map<Id, String> errorsByOrderRecordId) {
        List<External_Order__c> updates = new List<External_Order__c>();
        for (Id orderRecordId : errorsByOrderRecordId.keySet()) {
            updates.add(
                new External_Order__c(Id = orderRecordId, Sync_Error__c = errorsByOrderRecordId.get(orderRecordId).abbreviate(255))
            );
        }
        update updates;
    }

    private static void copyFields(OrdersApiClient.ApiOrder apiOrder, External_Order__c order) {
        order.Name = String.isBlank(apiOrder.friendlyId) ? apiOrder.id : apiOrder.friendlyId;
        if (apiOrder.amount != null) {
            order.Amount__c = apiOrder.amount;
            order.Currency__c = apiOrder.currencyCode;
        }
        if (apiOrder.participantRef != null) {
            order.Participant_Ref__c = apiOrder.participantRef;
        }
        if (apiOrder.createdAt != null) {
            order.Order_Created_At__c = apiOrder.createdAt;
        }
        if (apiOrder.updatedAt != null) {
            order.Order_Updated_At__c = apiOrder.updatedAt;
        }
        if (
            OrderStatus.isKnown(apiOrder.status) &&
            OrderStatus.supersedes(order.Status__c, order.Status_As_Of__c, apiOrder.status, apiOrder.updatedAt)
        ) {
            order.Status__c = apiOrder.status;
            order.Status_As_Of__c = apiOrder.updatedAt;
            order.Last_Event_Id__c = null; // the current status now comes from the API, not from an event
        }
        if (apiOrder.hasDetails) {
            order.Details_Synced_At__c = Datetime.now();
            order.Sync_Error__c = null;
        }
    }

    /** Makes each detailed order's lines match the API: insert new, update existing, delete removed. */
    private static void replaceLines(List<OrdersApiClient.ApiOrder> detailed, Map<String, External_Order__c> saved) {
        if (detailed.isEmpty()) {
            return;
        }
        Set<Id> orderRecordIds = new Set<Id>();
        for (OrdersApiClient.ApiOrder apiOrder : detailed) {
            orderRecordIds.add(saved.get(apiOrder.id).Id);
        }
        Map<String, External_Order_Line__c> existingByKey = new Map<String, External_Order_Line__c>();
        for (External_Order_Line__c line : [
            SELECT Id, Line_Key__c
            FROM External_Order_Line__c
            WHERE External_Order__c IN :orderRecordIds
        ]) {
            existingByKey.put(line.Line_Key__c, line);
        }

        List<External_Order_Line__c> toInsert = new List<External_Order_Line__c>();
        List<External_Order_Line__c> toUpdate = new List<External_Order_Line__c>();
        for (OrdersApiClient.ApiOrder apiOrder : detailed) {
            for (OrdersApiClient.ApiOrderLine apiLine : apiOrder.lines) {
                String key = apiOrder.id + ':' + apiLine.id; // line ids are only unique within an order
                External_Order_Line__c line = existingByKey.remove(key);
                if (line == null) {
                    // The master-detail field can only be set on insert, so new and existing lines are written separately.
                    line = new External_Order_Line__c(Line_Key__c = key, External_Order__c = saved.get(apiOrder.id).Id);
                    toInsert.add(line);
                } else {
                    toUpdate.add(line);
                }
                line.Name = apiLine.id;
                line.Type__c = apiLine.lineType;
                line.Status__c = apiLine.status;
                line.Amount__c = apiLine.amount;
                line.Currency__c = apiLine.currencyCode;
            }
        }
        insert toInsert;
        update toUpdate;
        delete existingByKey.values(); // whatever is left is no longer on the order in Orders
    }
}

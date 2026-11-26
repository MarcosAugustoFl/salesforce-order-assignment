// Simulates Orders delivering the spec's sample sequence (5 events: one duplicate, one out of order).
// Each payload is signed with the shared secret and sent through the real REST handler
// (OrdersWebhookResource.receive), exactly as an HTTP POST would be, so signature checking is exercised too.
//
//   sf apex run --file scripts/apex/simulate-sample-events.apex
//
// Records are committed. Run it twice: the second run returns DUPLICATE for every event.
// To start over: sf apex run --file scripts/apex/reset-demo-data.apex

List<String> payloads = new List<String>{
    '{ "subscriptionId": "sub_a1b2c3d4e5f67890abcdef12", "event": { "id": "evt_001", "type": "order.inProgress", "occurredAt": "2026-10-10T10:00:00Z", "version": "1.0" }, "data": { "orderId": "ord_77d1e9", "orderFriendlyId": "OR-261001-017-2231", "accountId": "acct_8f3c2a", "accountFriendlyId": "AC-260914-017-2231" } }',
    '{ "subscriptionId": "sub_a1b2c3d4e5f67890abcdef12", "event": { "id": "evt_002", "type": "order.waitingForParticipant", "occurredAt": "2026-10-11T10:00:00Z", "version": "1.0" }, "data": { "orderId": "ord_77d1e9", "orderFriendlyId": "OR-261001-017-2231", "accountId": "acct_8f3c2a", "accountFriendlyId": "AC-260914-017-2231" } }',
    '{ "subscriptionId": "sub_a1b2c3d4e5f67890abcdef12", "event": { "id": "evt_001", "type": "order.inProgress", "occurredAt": "2026-10-10T10:00:00Z", "version": "1.0" }, "data": { "orderId": "ord_77d1e9", "orderFriendlyId": "OR-261001-017-2231", "accountId": "acct_8f3c2a", "accountFriendlyId": "AC-260914-017-2231" } }',
    '{ "subscriptionId": "sub_a1b2c3d4e5f67890abcdef12", "event": { "id": "evt_004", "type": "order.sent", "occurredAt": "2026-10-12T14:03:11Z", "version": "1.0" }, "data": { "orderId": "ord_77d1e9", "orderFriendlyId": "OR-261001-017-2231", "accountId": "acct_8f3c2a", "accountFriendlyId": "AC-260914-017-2231" } }',
    '{ "subscriptionId": "sub_a1b2c3d4e5f67890abcdef12", "event": { "id": "evt_003", "type": "order.cleared", "occurredAt": "2026-10-09T09:41:27Z", "version": "1.0" }, "data": { "orderId": "ord_52ab10", "orderFriendlyId": "OR-260922-017-1187", "accountId": "acct_8f3c2a", "accountFriendlyId": "AC-260914-017-2231" } }'
};

String secret = OrdersIntegrationConfig.webhookSecret();
for (String payload : payloads) {
    RestRequest request = new RestRequest();
    request.httpMethod = 'POST';
    request.requestURI = '/services/apexrest/orders/events';
    request.requestBody = Blob.valueOf(payload);
    request.addHeader('Orders-Signature', OrdersSignatureVerifier.sign(request.requestBody, secret));
    RestContext.request = request;
    RestContext.response = new RestResponse();

    OrdersWebhookResource.receive();

    System.debug(LoggingLevel.ERROR, 'HTTP ' + RestContext.response.statusCode + ' ' + RestContext.response.responseBody.toString());
}

// A forged event (signed with the wrong secret) must be rejected with 401.
String forged = payloads[0].replace('evt_001', 'evt_forged');
RestRequest bad = new RestRequest();
bad.requestBody = Blob.valueOf(forged);
bad.addHeader('Orders-Signature', OrdersSignatureVerifier.sign(bad.requestBody, 'not-the-secret'));
RestContext.request = bad;
RestContext.response = new RestResponse();
OrdersWebhookResource.receive();
System.debug(LoggingLevel.ERROR, 'Forged event -> HTTP ' + RestContext.response.statusCode + ' ' + RestContext.response.responseBody.toString());

// End state. Expected: ord_77d1e9 = sent, ord_52ab10 = cleared, evt_001 stored once (delivered twice).
for (External_Order__c o : [SELECT Order_Id__c, Status__c, Status_As_Of__c, Account__r.Name FROM External_Order__c WHERE Order_Id__c IN ('ord_77d1e9', 'ord_52ab10') ORDER BY Order_Id__c]) {
    System.debug(LoggingLevel.ERROR, 'ORDER ' + o.Order_Id__c + ' status=' + o.Status__c + ' asOf=' + o.Status_As_Of__c + ' account=' + o.Account__r.Name);
}
for (External_Order_Event__c e : [SELECT Event_Id__c, Status__c, Outcome__c, Delivery_Count__c FROM External_Order_Event__c WHERE External_Order__r.Order_Id__c IN ('ord_77d1e9', 'ord_52ab10') ORDER BY Event_Id__c]) {
    System.debug(LoggingLevel.ERROR, 'EVENT ' + e.Event_Id__c + ' ' + e.Status__c + ' outcome=' + e.Outcome__c + ' deliveries=' + e.Delivery_Count__c);
}

@IsTest
private class OrdersWebhookResourceTest {
    /** The five-event sample sequence from the spec, including the duplicate and the out-of-order event. */
    @IsTest
    static void sampleSequenceReachesExpectedEndState() {
        List<String> bodies = new List<String>{
            OrdersTestData.eventJson('evt_001', 'inProgress', '2026-10-10T10:00:00Z', 'ord_77d1e9'),
            OrdersTestData.eventJson('evt_002', 'waitingForParticipant', '2026-10-11T10:00:00Z', 'ord_77d1e9'),
            OrdersTestData.eventJson('evt_001', 'inProgress', '2026-10-10T10:00:00Z', 'ord_77d1e9'),
            OrdersTestData.eventJson('evt_004', 'sent', '2026-10-12T14:03:11Z', 'ord_77d1e9'),
            OrdersTestData.eventJson('evt_003', 'cleared', '2026-10-09T09:41:27Z', 'ord_52ab10')
        };
        List<String> outcomes = new List<String>();
        Test.setMock(HttpCalloutMock.class, new OrdersApiMock());
        Test.startTest();
        for (String body : bodies) {
            RestResponse response = OrdersTestData.post(body);
            Assert.areEqual(200, response.statusCode, response.responseBody.toString());
            outcomes.add((String) OrdersTestData.responseBody(response).get('outcome'));
        }
        Test.stopTest();

        Assert.areEqual(new List<String>{ 'APPLIED', 'APPLIED', 'DUPLICATE', 'APPLIED', 'APPLIED' }, outcomes);
        Assert.areEqual('sent', OrdersTestData.reload('ord_77d1e9').Status__c);
        Assert.areEqual('cleared', OrdersTestData.reload('ord_52ab10').Status__c);

        External_Order_Event__c evt001 = [
            SELECT Delivery_Count__c, Outcome__c
            FROM External_Order_Event__c
            WHERE Event_Id__c = 'evt_001'
        ];
        Assert.areEqual(2, evt001.Delivery_Count__c, 'delivered twice');
        Assert.areEqual(4, [SELECT COUNT() FROM External_Order_Event__c], 'evt_001 stored (processed) once');
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE Orders_Account_Id__c = :OrdersTestData.ACCOUNT_ID]);
    }

    @IsTest
    static void olderEventArrivingLateIsRecordedButDoesNotChangeStatus() {
        Test.setMock(HttpCalloutMock.class, new OrdersApiMock()); // queued detail sync runs when the test ends
        OrdersTestData.post(OrdersTestData.eventJson('evt_new', 'sent', '2026-10-12T14:03:11Z', 'ord_1'));
        RestResponse response = OrdersTestData.post(
            OrdersTestData.eventJson('evt_old', 'inProgress', '2026-10-10T10:00:00Z', 'ord_1')
        );

        Assert.areEqual(200, response.statusCode);
        Assert.areEqual('IGNORED', OrdersTestData.responseBody(response).get('outcome'));
        External_Order__c order = OrdersTestData.reload('ord_1');
        Assert.areEqual('sent', order.Status__c);
        Assert.areEqual('evt_new', order.Last_Event_Id__c);
        Assert.areEqual('Ignored', [SELECT Outcome__c FROM External_Order_Event__c WHERE Event_Id__c = 'evt_old'].Outcome__c);
    }

    @IsTest
    static void eventForKnownAccountReusesIt() {
        Test.setMock(HttpCalloutMock.class, new OrdersApiMock()); // queued detail sync runs when the test ends
        Account existing = OrdersTestData.linkedAccount();
        OrdersTestData.post(OrdersTestData.eventJson('evt_1', 'inProgress', '2026-10-10T10:00:00Z', 'ord_1'));

        Assert.areEqual(existing.Id, OrdersTestData.reload('ord_1').Account__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Account]);
    }

    @IsTest
    static void unknownAccountGetsPlaceholderNamedAfterFriendlyId() {
        Test.setMock(HttpCalloutMock.class, new OrdersApiMock()); // queued detail sync runs when the test ends
        OrdersTestData.post(OrdersTestData.eventJson('evt_1', 'inProgress', '2026-10-10T10:00:00Z', 'ord_1'));

        Account placeholder = [SELECT Name, Orders_Synced_At__c FROM Account WHERE Orders_Account_Id__c = :OrdersTestData.ACCOUNT_ID];
        Assert.areEqual(OrdersTestData.ACCOUNT_FRIENDLY_ID, placeholder.Name);
        Assert.isNull(placeholder.Orders_Synced_At__c, 'marks it for enrichment');
    }

    @IsTest
    static void appliedEventQueuesDetailSyncWithoutCallingOrdersInline() {
        OrdersApiMock api = new OrdersApiMock(); // every path 404s
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        OrdersTestData.post(OrdersTestData.eventJson('evt_1', 'inProgress', '2026-10-10T10:00:00Z', 'ord_1'));
        Assert.areEqual(1, Limits.getQueueableJobs(), 'detail sync queued');
        Assert.areEqual(0, api.calledPaths.size(), 'the webhook itself makes no callouts');
        Test.stopTest(); // runs the queued job

        External_Order__c order = OrdersTestData.reload('ord_1');
        Assert.areEqual('inProgress', order.Status__c, 'status is kept even though Orders could not be read');
        Assert.isTrue(order.Sync_Error__c.contains('404'), order.Sync_Error__c);
    }

    @IsTest
    static void wrongSignatureIsRejectedAndNothingStored() {
        String body = OrdersTestData.eventJson('evt_1', 'sent', '2026-10-12T14:03:11Z', 'ord_1');
        RestResponse response = OrdersTestData.post(body, OrdersSignatureVerifier.sign(Blob.valueOf(body), 'wrong-secret'));

        Assert.areEqual(401, response.statusCode);
        Assert.areEqual('invalid_signature', OrdersTestData.responseBody(response).get('error'));
        Assert.areEqual(0, [SELECT COUNT() FROM External_Order__c]);
        Assert.areEqual(0, [SELECT COUNT() FROM External_Order_Event__c]);
    }

    @IsTest
    static void missingSignatureIsRejected() {
        RestResponse response = OrdersTestData.post(
            OrdersTestData.eventJson('evt_1', 'sent', '2026-10-12T14:03:11Z', 'ord_1'),
            null
        );
        Assert.areEqual(401, response.statusCode);
    }

    @IsTest
    static void bodyChangedAfterSigningIsRejected() {
        String original = OrdersTestData.eventJson('evt_1', 'sent', '2026-10-12T14:03:11Z', 'ord_1');
        String tampered = original.replace('order.sent', 'order.returned');
        RestResponse response = OrdersTestData.post(tampered, OrdersSignatureVerifier.sign(Blob.valueOf(original), OrdersIntegrationConfig.webhookSecret()));
        Assert.areEqual(401, response.statusCode);
    }

    @IsTest
    static void signedButMalformedEventIsBadRequest() {
        Assert.areEqual(400, OrdersTestData.post('not json').statusCode);
        Assert.areEqual(400, OrdersTestData.post('{"event":{"id":"evt_1"},"data":{}}').statusCode);

        RestResponse unknownType = OrdersTestData.post(
            OrdersTestData.eventJson('evt_1', 'teleported', '2026-10-12T14:03:11Z', 'ord_1')
        );
        Assert.areEqual(400, unknownType.statusCode);
        Assert.isTrue(((String) OrdersTestData.responseBody(unknownType).get('message')).contains('Unsupported event type'));
        Assert.areEqual(0, [SELECT COUNT() FROM External_Order_Event__c]);
    }

    @IsTest
    static void signatureHeaderNameIsCaseInsensitive() {
        Test.setMock(HttpCalloutMock.class, new OrdersApiMock()); // queued detail sync runs when the test ends
        String body = OrdersTestData.eventJson('evt_1', 'sent', '2026-10-12T14:03:11Z', 'ord_1');
        RestRequest request = new RestRequest();
        request.requestBody = Blob.valueOf(body);
        request.addHeader('orders-signature', OrdersSignatureVerifier.sign(Blob.valueOf(body), OrdersIntegrationConfig.webhookSecret()));
        RestContext.request = request;
        RestContext.response = new RestResponse();

        OrdersWebhookResource.receive();

        Assert.areEqual(200, RestContext.response.statusCode);
    }
}

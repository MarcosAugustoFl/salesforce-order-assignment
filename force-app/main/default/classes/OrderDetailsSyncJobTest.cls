@IsTest
private class OrderDetailsSyncJobTest {
    @IsTest
    static void fillsDetailsLinesAndPlaceholderAccountName() {
        Account placeholder = new Account(Name = OrdersTestData.ACCOUNT_FRIENDLY_ID, Orders_Account_Id__c = OrdersTestData.ACCOUNT_ID);
        insert placeholder;
        External_Order__c order = OrdersTestData.order(placeholder.Id, 'ord_1', 'sent', Datetime.newInstanceGmt(2026, 10, 12, 14, 3, 11));
        insert new External_Order_Line__c(Name = 'ol_gone', Line_Key__c = 'ord_1:ol_gone', External_Order__c = order.Id);

        OrdersApiMock api = new OrdersApiMock()
            .respond('/orders/ord_1', 200, OrdersTestData.orderDetailJson('ord_1', 'sent', '2026-10-12T14:03:11Z', new List<String>{ 'ol_1', 'ol_2' }))
            .respond('/accounts/' + OrdersTestData.ACCOUNT_ID, 200, OrdersTestData.accountJson());
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        System.enqueueJob(new OrderDetailsSyncJob(new Set<Id>{ order.Id }, 1));
        Test.stopTest();

        External_Order__c synced = OrdersTestData.reload('ord_1');
        Assert.areEqual(1250.00, synced.Amount__c);
        Assert.areEqual('USD', synced.Currency__c);
        Assert.areEqual('p_4411', synced.Participant_Ref__c);
        Assert.isNotNull(synced.Details_Synced_At__c);
        Assert.isNull(synced.Sync_Error__c);
        Assert.areEqual(2, synced.Lines__r.size(), 'ol_gone removed, ol_1 and ol_2 added');
        Assert.areEqual('ord_1:ol_1', synced.Lines__r[0].Line_Key__c);

        Account acc = [SELECT Name, Orders_Status__c, Orders_Synced_At__c FROM Account WHERE Id = :placeholder.Id];
        Assert.areEqual('Northwind Plan Sponsor LLC', acc.Name);
        Assert.areEqual('active', acc.Orders_Status__c);
        Assert.isNotNull(acc.Orders_Synced_At__c);
    }

    /** An event landed after Orders produced this response: the older API status must not undo it. */
    @IsTest
    static void olderApiSnapshotDoesNotOverwriteNewerEventStatus() {
        Account acc = OrdersTestData.linkedAccount();
        External_Order__c order = OrdersTestData.order(acc.Id, 'ord_1', 'cleared', Datetime.newInstanceGmt(2026, 10, 13, 0, 0, 0));
        Test.setMock(
            HttpCalloutMock.class,
            new OrdersApiMock().respond('/orders/ord_1', 200, OrdersTestData.orderDetailJson('ord_1', 'sent', '2026-10-12T14:03:11Z', new List<String>{ 'ol_1' }))
        );

        Test.startTest();
        System.enqueueJob(new OrderDetailsSyncJob(new Set<Id>{ order.Id }, 1));
        Test.stopTest();

        External_Order__c synced = OrdersTestData.reload('ord_1');
        Assert.areEqual('cleared', synced.Status__c);
        Assert.areEqual(1250.00, synced.Amount__c, 'other details are still filled in');
    }

    @IsTest
    static void newerApiSnapshotCorrectsStatus() {
        Account acc = OrdersTestData.linkedAccount();
        External_Order__c order = OrdersTestData.order(acc.Id, 'ord_1', 'inProgress', Datetime.newInstanceGmt(2026, 10, 10, 0, 0, 0));
        Test.setMock(
            HttpCalloutMock.class,
            new OrdersApiMock().respond('/orders/ord_1', 200, OrdersTestData.orderDetailJson('ord_1', 'sent', '2026-10-12T14:03:11Z', new List<String>()))
        );

        Test.startTest();
        System.enqueueJob(new OrderDetailsSyncJob(new Set<Id>{ order.Id }, 1));
        Test.stopTest();

        Assert.areEqual('sent', OrdersTestData.reload('ord_1').Status__c);
    }

    @IsTest
    static void rateLimitStopsAndReschedulesWithoutRecordingAnError() {
        Account acc = OrdersTestData.linkedAccount();
        External_Order__c order = OrdersTestData.order(acc.Id, 'ord_1', 'sent', Datetime.now());
        Test.setMock(HttpCalloutMock.class, new OrdersApiMock().rateLimit('/orders/ord_1', 120));

        Test.startTest();
        System.enqueueJob(new OrderDetailsSyncJob(new Set<Id>{ order.Id }, 1));
        Test.stopTest();

        Assert.isNull(OrdersTestData.reload('ord_1').Sync_Error__c);
        Assert.areEqual(1, QueueableChain.captured.size(), 'retry scheduled');
        Assert.areEqual(2, QueueableChain.minutesFor(120));
    }

    @IsTest
    static void serverErrorOnLastAttemptIsRecordedAndNotRetried() {
        Account acc = OrdersTestData.linkedAccount();
        External_Order__c order = OrdersTestData.order(acc.Id, 'ord_1', 'sent', Datetime.now());
        Test.setMock(HttpCalloutMock.class, new OrdersApiMock().respond('/orders/ord_1', 503, ''));

        Test.startTest();
        System.enqueueJob(new OrderDetailsSyncJob(new Set<Id>{ order.Id }, OrderDetailsSyncJob.MAX_ATTEMPTS));
        Test.stopTest();

        Assert.isTrue(OrdersTestData.reload('ord_1').Sync_Error__c.contains('attempts'));
        Assert.areEqual(0, QueueableChain.captured.size());
    }

    @IsTest
    static void moreOrdersThanOneRunAllowsContinueInFollowUpJob() {
        Account acc = OrdersTestData.linkedAccount();
        List<External_Order__c> orders = new List<External_Order__c>();
        for (Integer i = 0; i < OrderDetailsSyncJob.MAX_CALLOUTS_PER_RUN + 5; i++) {
            orders.add(new External_Order__c(Name = 'O' + i, Order_Id__c = 'ord_' + i, Account__c = acc.Id));
        }
        insert orders;
        OrdersApiMock api = new OrdersApiMock();
        Test.setMock(HttpCalloutMock.class, api);

        Test.startTest();
        System.enqueueJob(new OrderDetailsSyncJob(new Map<Id, External_Order__c>(orders).keySet(), 1));
        Test.stopTest();

        Integer orderCallouts = 0;
        for (String path : api.calledPaths) {
            orderCallouts += path.startsWith('/orders/') ? 1 : 0;
        }
        Assert.areEqual(OrderDetailsSyncJob.MAX_CALLOUTS_PER_RUN, orderCallouts);
        Assert.areEqual(1, QueueableChain.captured.size(), 'the remaining 5 continue later');
    }
}

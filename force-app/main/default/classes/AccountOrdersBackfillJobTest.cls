@IsTest
private class AccountOrdersBackfillJobTest {
    private static String pageJson(List<String> orderIds, Integer nextPage) {
        List<Object> items = new List<Object>();
        for (String orderId : orderIds) {
            items.add(
                new Map<String, Object>{
                    'id' => orderId,
                    'friendlyId' => 'OR-' + orderId,
                    'accountId' => OrdersTestData.ACCOUNT_ID,
                    'status' => 'cleared',
                    'amount' => new Map<String, Object>{ 'value' => '300.00', 'currency' => 'USD' },
                    'updatedAt' => '2026-10-09T09:41:27Z'
                }
            );
        }
        return JSON.serialize(new Map<String, Object>{ 'items' => items, 'page' => 1, 'pageSize' => 50, 'nextPage' => nextPage });
    }

    private static String pagePath(Integer page) {
        return '/accounts/' + OrdersTestData.ACCOUNT_ID + '/orders?page=' + page + '&pageSize=50';
    }

    @IsTest
    static void firstPageCreatesOrdersAndChainsNextPage() {
        Account acc = OrdersTestData.linkedAccount();
        Test.setMock(
            HttpCalloutMock.class,
            new OrdersApiMock()
                .respond('/accounts/' + OrdersTestData.ACCOUNT_ID, 200, OrdersTestData.accountJson())
                .respond(pagePath(1), 200, pageJson(new List<String>{ 'ord_a', 'ord_b' }, 2))
        );

        Test.startTest();
        System.enqueueJob(new AccountOrdersBackfillJob(acc.Id));
        Test.stopTest();

        Assert.areEqual(2, [SELECT COUNT() FROM External_Order__c WHERE Account__c = :acc.Id AND Status__c = 'cleared']);
        Assert.areEqual('Northwind Plan Sponsor LLC', [SELECT Name FROM Account WHERE Id = :acc.Id].Name);
        Assert.areEqual(1, QueueableChain.captured.size());
        Assert.isTrue(QueueableChain.captured[0] instanceof AccountOrdersBackfillJob, 'next page');
    }

    @IsTest
    static void lastPageHandsNewOrdersToDetailSync() {
        Account acc = OrdersTestData.linkedAccount();
        Test.setMock(HttpCalloutMock.class, new OrdersApiMock().respond(pagePath(2), 200, pageJson(new List<String>{ 'ord_c' }, null)));

        Test.startTest();
        System.enqueueJob(new AccountOrdersBackfillJob(acc.Id, 2, 1, new Set<Id>()));
        Test.stopTest();

        Assert.areEqual(1, QueueableChain.captured.size());
        Assert.isTrue(QueueableChain.captured[0] instanceof OrderDetailsSyncJob);
    }

    @IsTest
    static void backfillDoesNotOverwriteNewerEventStatus() {
        Account acc = OrdersTestData.linkedAccount();
        OrdersTestData.order(acc.Id, 'ord_a', 'returned', Datetime.newInstanceGmt(2026, 10, 20, 0, 0, 0));
        Test.setMock(HttpCalloutMock.class, new OrdersApiMock().respond(pagePath(2), 200, pageJson(new List<String>{ 'ord_a' }, null)));

        Test.startTest();
        System.enqueueJob(new AccountOrdersBackfillJob(acc.Id, 2, 1, new Set<Id>()));
        Test.stopTest();

        External_Order__c order = OrdersTestData.reload('ord_a');
        Assert.areEqual('returned', order.Status__c);
        Assert.areEqual(300.00, order.Amount__c);
    }

    @IsTest
    static void unknownOrdersAccountStopsQuietly() {
        Account acc = OrdersTestData.linkedAccount();
        Test.setMock(HttpCalloutMock.class, new OrdersApiMock()); // 404 everywhere

        Test.startTest();
        System.enqueueJob(new AccountOrdersBackfillJob(acc.Id));
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM External_Order__c]);
        Assert.areEqual(0, QueueableChain.captured.size(), '404 is not retried');
    }

    @IsTest
    static void controllerRequiresALinkedAccount() {
        User agent = OrdersTestData.agentUser();
        System.runAs(agent) {
            Account unlinked = new Account(Name = 'Not in Orders');
            insert unlinked;
            try {
                OrdersSyncController.syncAccountOrders(unlinked.Id);
                Assert.fail('expected an error');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('not linked'), e.getMessage());
            }
        }
    }

    @IsTest
    static void agentCanStartBackfill() {
        User agent = OrdersTestData.agentUser();
        Test.setMock(HttpCalloutMock.class, new OrdersApiMock());
        System.runAs(agent) {
            Account acc = OrdersTestData.linkedAccount();
            Test.startTest();
            Id jobId = OrdersSyncController.syncAccountOrders(acc.Id);
            Test.stopTest();
            Assert.isNotNull(jobId);
        }
    }
}

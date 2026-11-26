@IsTest
private class OrderEventServiceTest {
    /** 200 events across 100 orders in one call: same fixed number of queries/DML as a single event. */
    @IsTest
    static void processesLargeBatchWithinGovernorLimits() {
        List<OrderEvent> events = new List<OrderEvent>();
        for (Integer i = 0; i < 100; i++) {
            // Deliberately newest first, so half the work depends on ordering by occurredAt.
            events.add(OrdersTestData.event('evt_b' + i, 'sent', '2026-10-12T10:00:00Z', 'ord_' + i));
            events.add(OrdersTestData.event('evt_a' + i, 'inProgress', '2026-10-10T10:00:00Z', 'ord_' + i));
        }

        Test.startTest();
        OrderEventService.ProcessResult result = new OrderEventService().process(events);
        Integer queries = Limits.getQueries();
        Integer dmlStatements = Limits.getDmlStatements();
        Test.stopTest();

        Assert.isTrue(queries <= 4, 'queries: ' + queries);
        Assert.isTrue(dmlStatements <= 4, 'DML statements: ' + dmlStatements);
        Assert.areEqual(100, [SELECT COUNT() FROM External_Order__c WHERE Status__c = 'sent']);
        Assert.areEqual(200, [SELECT COUNT() FROM External_Order_Event__c]);
        Assert.areEqual(100, result.changedOrderIds.size());
    }

    @IsTest
    static void duplicatesInsideOneBatchAreProcessedOnce() {
        OrderEvent first = OrdersTestData.event('evt_1', 'inProgress', '2026-10-10T10:00:00Z', 'ord_1');
        OrderEvent again = OrdersTestData.event('evt_1', 'inProgress', '2026-10-10T10:00:00Z', 'ord_1');

        OrderEventService.ProcessResult result = new OrderEventService().process(new List<OrderEvent>{ first, again });

        Assert.areEqual(OrderEventService.Outcome.APPLIED, result.results[0].outcome);
        Assert.areEqual(OrderEventService.Outcome.DUPLICATE, result.results[1].outcome);
        Assert.areEqual(2, [SELECT Delivery_Count__c FROM External_Order_Event__c].Delivery_Count__c);
    }

    @IsTest
    static void sameTimestampFurtherStatusWins() {
        new OrderEventService().process(new List<OrderEvent>{
            OrdersTestData.event('evt_2', 'cleared', '2026-10-12T10:00:00Z', 'ord_1'),
            OrdersTestData.event('evt_1', 'sent', '2026-10-12T10:00:00Z', 'ord_1')
        });
        Assert.areEqual('cleared', OrdersTestData.reload('ord_1').Status__c);
    }

    @IsTest
    static void returnedCanFollowCleared() {
        new OrderEventService().process(new List<OrderEvent>{ OrdersTestData.event('evt_1', 'cleared', '2026-10-12T10:00:00Z', 'ord_1') });
        new OrderEventService().process(new List<OrderEvent>{ OrdersTestData.event('evt_2', 'returned', '2026-10-13T10:00:00Z', 'ord_1') });
        Assert.areEqual('returned', OrdersTestData.reload('ord_1').Status__c);
    }

    @IsTest
    static void eventOlderThanSyncedStatusIsIgnored() {
        Account acc = OrdersTestData.linkedAccount();
        OrdersTestData.order(acc.Id, 'ord_1', 'cleared', Datetime.newInstanceGmt(2026, 10, 12, 0, 0, 0));

        OrderEventService.ProcessResult result = new OrderEventService().process(new List<OrderEvent>{
            OrdersTestData.event('evt_1', 'sent', '2026-10-11T10:00:00Z', 'ord_1')
        });

        Assert.areEqual(OrderEventService.Outcome.IGNORED, result.results[0].outcome);
        Assert.isTrue(result.changedOrderIds.isEmpty());
        Assert.areEqual('cleared', OrdersTestData.reload('ord_1').Status__c);
    }

    @IsTest
    static void statusRuleUnitCases() {
        Datetime t1 = Datetime.newInstanceGmt(2026, 10, 10, 0, 0, 0);
        Datetime t2 = t1.addHours(1);
        Assert.isTrue(OrderStatus.supersedes(null, null, 'inProgress', t1), 'nothing held yet');
        Assert.isTrue(OrderStatus.supersedes('sent', t1, 'inProgress', t2), 'later timestamp wins, even if lower status');
        Assert.isFalse(OrderStatus.supersedes('inProgress', t2, 'sent', t1), 'older loses');
        Assert.isFalse(OrderStatus.supersedes('sent', t1, 'sent', t1), 'identical is not newer');
        Assert.isNull(OrderStatus.fromEventType('order.unknown'));
        Assert.isNull(OrderStatus.fromEventType('invoice.sent'));
        Assert.areEqual('waitingForParticipant', OrderStatus.fromEventType('order.waitingForParticipant'));
    }
}

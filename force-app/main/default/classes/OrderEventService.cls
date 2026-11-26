/**
 * Applies order status events to Salesforce.
 *
 * Each event ends up with one of three outcomes, all of them successful from the sender's point of view:
 *   DUPLICATE - already received (same event.id). Nothing changes except the stored event's delivery count.
 *   APPLIED   - the newest information we have for its order; the order's status is updated.
 *   IGNORED   - older than what we already hold (it arrived out of order). It is recorded in the history
 *               but does not change the order.
 *
 * Bulk-safe: takes a list and uses a fixed number of queries and DML statements regardless of its size.
 * The webhook passes one event per request; tests and the simulation script pass many at once.
 *
 * without sharing: this is a system integration. It must see every Account and order to find the existing
 * record. A sharing-filtered query could miss one and then fail on the unique key, or create a second Account.
 * Who may call it is controlled by the integration user's permission set, not by record sharing.
 */
public without sharing class OrderEventService {
    public enum Outcome {
        APPLIED,
        IGNORED,
        DUPLICATE
    }

    public class Result {
        public final String eventId;
        public final Outcome outcome;

        public Result(String eventId, Outcome outcome) {
            this.eventId = eventId;
            this.outcome = outcome;
        }
    }

    public class ProcessResult {
        /** One result per input event, in input order. */
        public final List<Result> results = new List<Result>();
        /** Orders whose status changed. Their amount and lines may have changed too, so they are re-read from Orders. */
        public final Set<Id> changedOrderIds = new Set<Id>();
    }

    public ProcessResult process(List<OrderEvent> events) {
        ProcessResult result = new ProcessResult();
        if (events == null || events.isEmpty()) {
            return result;
        }

        // 1. Collapse duplicates inside this batch: the first copy is processed, the rest only count as deliveries.
        Map<String, OrderEvent> distinctEvents = new Map<String, OrderEvent>();
        Map<String, Integer> deliveryCounts = new Map<String, Integer>();
        for (OrderEvent evt : events) {
            if (!distinctEvents.containsKey(evt.eventId)) {
                distinctEvents.put(evt.eventId, evt);
                deliveryCounts.put(evt.eventId, 0);
            }
            deliveryCounts.put(evt.eventId, deliveryCounts.get(evt.eventId) + 1);
        }

        // 2. Lock the orders involved. A concurrent request for the same order waits here until this
        //    transaction commits, so two events can never both read the old status and overwrite each other.
        Map<String, External_Order__c> ordersByOrderId = lockOrders(distinctEvents.values());

        // 3. Events already stored are redeliveries: nothing to apply, just record that they came again.
        Map<String, External_Order_Event__c> storedEvents = findStoredEvents(distinctEvents.keySet());
        for (External_Order_Event__c stored : storedEvents.values()) {
            Decimal previousCount = stored.Delivery_Count__c == null ? 1 : stored.Delivery_Count__c;
            stored.Delivery_Count__c = previousCount + deliveryCounts.get(stored.Event_Id__c);
            stored.Last_Delivered_At__c = Datetime.now();
        }

        List<OrderEvent> newEvents = new List<OrderEvent>();
        for (OrderEvent evt : distinctEvents.values()) {
            if (!storedEvents.containsKey(evt.eventId)) {
                newEvents.add(evt);
            }
        }

        // 4. There is no order.created event: the first event we see for an order creates it (and its Account).
        addMissingOrders(newEvents, ordersByOrderId);

        // 5. Apply oldest first so the newest information is what remains, whatever order they arrived in.
        newEvents.sort(new OldestFirst());
        Map<String, Outcome> outcomes = new Map<String, Outcome>();
        Map<String, String> outcomeDetails = new Map<String, String>();
        Map<String, External_Order__c> changedOrders = new Map<String, External_Order__c>();
        for (OrderEvent evt : newEvents) {
            External_Order__c order = ordersByOrderId.get(evt.orderId);
            if (OrderStatus.supersedes(order.Status__c, order.Status_As_Of__c, evt.status, evt.occurredAt)) {
                outcomeDetails.put(evt.eventId, describeApplied(order.Status__c, evt.status));
                order.Status__c = evt.status;
                order.Status_As_Of__c = evt.occurredAt;
                order.Last_Event_Id__c = evt.eventId;
                outcomes.put(evt.eventId, Outcome.APPLIED);
                changedOrders.put(evt.orderId, order);
            } else {
                outcomes.put(evt.eventId, Outcome.IGNORED);
                outcomeDetails.put(evt.eventId, describeIgnored(order));
            }
        }

        // 6. Write orders first (new ones need an Id for the event's master-detail), then the event history.
        upsert changedOrders.values() Order_Id__c;
        List<External_Order_Event__c> eventRecords = new List<External_Order_Event__c>();
        for (OrderEvent evt : newEvents) {
            eventRecords.add(
                toEventRecord(
                    evt,
                    ordersByOrderId.get(evt.orderId).Id,
                    outcomes.get(evt.eventId),
                    outcomeDetails.get(evt.eventId),
                    deliveryCounts.get(evt.eventId)
                )
            );
        }
        insert eventRecords;
        update storedEvents.values();

        // 7. Report per input event, in input order. Second and later copies are always duplicates.
        Set<String> reported = new Set<String>();
        for (OrderEvent evt : events) {
            Boolean isDuplicate = reported.contains(evt.eventId) || storedEvents.containsKey(evt.eventId);
            result.results.add(new Result(evt.eventId, isDuplicate ? Outcome.DUPLICATE : outcomes.get(evt.eventId)));
            reported.add(evt.eventId);
        }
        for (External_Order__c order : changedOrders.values()) {
            result.changedOrderIds.add(order.Id);
        }
        return result;
    }

    private Map<String, External_Order__c> lockOrders(List<OrderEvent> events) {
        Set<String> orderIds = new Set<String>();
        for (OrderEvent evt : events) {
            orderIds.add(evt.orderId);
        }
        Map<String, External_Order__c> ordersByOrderId = new Map<String, External_Order__c>();
        for (External_Order__c order : [
            SELECT Id, Order_Id__c, Status__c, Status_As_Of__c
            FROM External_Order__c
            WHERE Order_Id__c IN :orderIds
            FOR UPDATE
        ]) {
            ordersByOrderId.put(order.Order_Id__c, order);
        }
        return ordersByOrderId;
    }

    private Map<String, External_Order_Event__c> findStoredEvents(Set<String> eventIds) {
        Map<String, External_Order_Event__c> storedEvents = new Map<String, External_Order_Event__c>();
        for (External_Order_Event__c stored : [
            SELECT Id, Event_Id__c, Delivery_Count__c
            FROM External_Order_Event__c
            WHERE Event_Id__c IN :eventIds
        ]) {
            storedEvents.put(stored.Event_Id__c, stored);
        }
        return storedEvents;
    }

    /** Adds an in-memory (not yet inserted) order for each event whose order we have never seen. */
    private void addMissingOrders(List<OrderEvent> events, Map<String, External_Order__c> ordersByOrderId) {
        List<OrderEvent> firstSightings = new List<OrderEvent>();
        Set<String> seen = new Set<String>(ordersByOrderId.keySet());
        for (OrderEvent evt : events) {
            if (seen.add(evt.orderId)) {
                firstSightings.add(evt);
            }
        }
        if (firstSightings.isEmpty()) {
            return;
        }
        Map<String, Id> accountIds = findOrCreateAccounts(firstSightings);
        for (OrderEvent evt : firstSightings) {
            ordersByOrderId.put(
                evt.orderId,
                new External_Order__c(
                    Order_Id__c = evt.orderId,
                    Name = String.isBlank(evt.orderFriendlyId) ? evt.orderId : evt.orderFriendlyId,
                    Account__c = accountIds.get(evt.accountId)
                )
            );
        }
    }

    /**
     * Matches Accounts by Orders_Account_Id__c and creates a placeholder for unknown ones. The payload has
     * no account name, so the placeholder is named after the friendly id until OrderDetailsSyncJob reads
     * the real name from GET /accounts/{id}.
     */
    private Map<String, Id> findOrCreateAccounts(List<OrderEvent> events) {
        Map<String, OrderEvent> eventsByAccountId = new Map<String, OrderEvent>();
        for (OrderEvent evt : events) {
            eventsByAccountId.put(evt.accountId, evt);
        }
        Map<String, Id> accountIds = new Map<String, Id>();
        for (Account acc : [
            SELECT Id, Orders_Account_Id__c
            FROM Account
            WHERE Orders_Account_Id__c IN :eventsByAccountId.keySet()
        ]) {
            accountIds.put(acc.Orders_Account_Id__c, acc.Id);
        }
        List<Account> placeholders = new List<Account>();
        for (OrderEvent evt : eventsByAccountId.values()) {
            if (!accountIds.containsKey(evt.accountId)) {
                placeholders.add(
                    new Account(
                        Name = String.isBlank(evt.accountFriendlyId) ? evt.accountId : evt.accountFriendlyId,
                        Orders_Account_Id__c = evt.accountId,
                        Orders_Friendly_Id__c = evt.accountFriendlyId
                    )
                );
            }
        }
        insert placeholders;
        for (Account acc : placeholders) {
            accountIds.put(acc.Orders_Account_Id__c, acc.Id);
        }
        return accountIds;
    }

    private External_Order_Event__c toEventRecord(
        OrderEvent evt,
        Id orderRecordId,
        Outcome outcome,
        String detail,
        Integer deliveryCount
    ) {
        return new External_Order_Event__c(
            External_Order__c = orderRecordId,
            Event_Id__c = evt.eventId,
            Event_Type__c = evt.eventType,
            Status__c = evt.status,
            Occurred_At__c = evt.occurredAt,
            Subscription_Id__c = evt.subscriptionId,
            Outcome__c = outcome == OrderEventService.Outcome.APPLIED ? 'Applied' : 'Ignored',
            Outcome_Detail__c = detail,
            Delivery_Count__c = deliveryCount,
            Last_Delivered_At__c = Datetime.now(),
            Raw_Payload__c = evt.rawPayload
        );
    }

    private static String describeApplied(String previousStatus, String newStatus) {
        return previousStatus == null
            ? 'Status set to ' + newStatus + '.'
            : 'Status changed from ' + previousStatus + ' to ' + newStatus + '.';
    }

    private static String describeIgnored(External_Order__c order) {
        return 'Not applied: the order already had newer information (' +
            order.Status__c +
            ' as of ' +
            order.Status_As_Of__c.formatGmt('yyyy-MM-dd HH:mm:ss') +
            ' UTC).';
    }

    private class OldestFirst implements Comparator<OrderEvent> {
        public Integer compare(OrderEvent a, OrderEvent b) {
            if (a.occurredAt == b.occurredAt) {
                return OrderStatus.rank(a.status) - OrderStatus.rank(b.status);
            }
            return a.occurredAt < b.occurredAt ? -1 : 1;
        }
    }
}

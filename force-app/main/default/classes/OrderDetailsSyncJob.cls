/**
 * Reads the parts of an order the event does not carry (amount, participant, lines) from
 * GET /orders/{id}, plus the real name of any placeholder Account from GET /accounts/{id}.
 *
 * Why async: the webhook must answer within the sender's 10s timeout, and an Orders API outage should
 * never cause an event to be rejected. The status (the part the CX team cares about most) is already
 * correct before this job runs; this job only fills in the rest.
 *
 * Rate limit (60 requests/minute): one run makes at most MAX_CALLOUTS_PER_RUN order callouts. Remaining
 * orders continue in a follow-up run one minute later. A 429 stops the run and resumes after Retry-After.
 * Transient failures are retried up to MAX_ATTEMPTS times; after that the error is saved on the order
 * (Sync_Error__c) so an agent can see the details may be stale.
 */
public without sharing class OrderDetailsSyncJob implements Queueable, Database.AllowsCallouts {
    @TestVisible
    private static final Integer MAX_CALLOUTS_PER_RUN = 40;
    @TestVisible
    private static final Integer MAX_ATTEMPTS = 3;

    private final Set<Id> orderIds;
    private final Integer attempt;

    public static void enqueue(Set<Id> orderIds) {
        if (orderIds != null && !orderIds.isEmpty()) {
            System.enqueueJob(new OrderDetailsSyncJob(orderIds, 1));
        }
    }

    public OrderDetailsSyncJob(Set<Id> orderIds, Integer attempt) {
        this.orderIds = orderIds;
        this.attempt = attempt;
    }

    public void execute(QueueableContext context) {
        List<External_Order__c> batch = [
            SELECT Id, Order_Id__c, Account__r.Orders_Account_Id__c, Account__r.Orders_Synced_At__c
            FROM External_Order__c
            WHERE Id IN :orderIds
            LIMIT :MAX_CALLOUTS_PER_RUN
        ];
        OrdersApiClient client = new OrdersApiClient();
        List<OrdersApiClient.ApiOrder> fetched = new List<OrdersApiClient.ApiOrder>();
        Map<Id, String> errors = new Map<Id, String>();
        Set<Id> toRetry = new Set<Id>();
        Set<Id> attempted = new Set<Id>();
        Integer retryAfterSeconds;

        // All callouts happen before any DML: Apex does not allow a callout after uncommitted DML.
        for (External_Order__c order : batch) {
            try {
                fetched.add(client.getOrder(order.Order_Id__c));
            } catch (OrdersApiClient.OrdersApiException e) {
                if (e.isRateLimited()) {
                    retryAfterSeconds = e.retryAfterSeconds == null ? 60 : e.retryAfterSeconds;
                    break; // stop calling; this order and the rest are retried later
                }
                if (e.isRetryable()) {
                    toRetry.add(order.Id);
                } else {
                    errors.put(order.Id, e.getMessage()); // e.g. 404: retrying will not help
                }
            }
            attempted.add(order.Id);
        }
        List<OrdersApiClient.ApiAccount> accounts = retryAfterSeconds == null
            ? fetchPlaceholderAccounts(client, batch)
            : new List<OrdersApiClient.ApiAccount>();

        // Orders not attempted in this run: beyond the per-run limit, or skipped because of a 429.
        // Orders missing from the query (deleted meanwhile) are dropped.
        Set<Id> notAttempted = new Set<Id>(orderIds);
        notAttempted.removeAll(attempted);
        if (batch.size() < MAX_CALLOUTS_PER_RUN) {
            notAttempted.retainAll(new Map<Id, External_Order__c>(batch).keySet());
        }

        Boolean hadFailures = retryAfterSeconds != null || !toRetry.isEmpty();
        if (hadFailures && attempt >= MAX_ATTEMPTS) {
            String message = 'Could not read order details from Orders after ' + attempt + ' attempts; will refresh on the next event or sync.';
            for (Id orderId : toRetry) {
                errors.put(orderId, message);
            }
            if (retryAfterSeconds != null) {
                for (Id orderId : notAttempted) {
                    errors.put(orderId, message);
                }
                notAttempted.clear();
            }
            toRetry.clear();
        }

        ExternalOrderWriter writer = new ExternalOrderWriter();
        writer.applyOrders(fetched, null);
        writer.applyAccounts(accounts);
        writer.recordSyncErrors(errors);

        Set<Id> next = new Set<Id>(notAttempted);
        next.addAll(toRetry);
        if (!next.isEmpty()) {
            QueueableChain.enqueue(
                new OrderDetailsSyncJob(next, hadFailures ? attempt + 1 : attempt),
                QueueableChain.minutesFor(retryAfterSeconds)
            );
        }
    }

    /** Accounts created from an event (never synced) get their real name and status from Orders. */
    private static List<OrdersApiClient.ApiAccount> fetchPlaceholderAccounts(
        OrdersApiClient client,
        List<External_Order__c> batch
    ) {
        Set<String> accountIds = new Set<String>();
        for (External_Order__c order : batch) {
            if (order.Account__r.Orders_Synced_At__c == null && order.Account__r.Orders_Account_Id__c != null) {
                accountIds.add(order.Account__r.Orders_Account_Id__c);
            }
        }
        List<OrdersApiClient.ApiAccount> accounts = new List<OrdersApiClient.ApiAccount>();
        for (String accountId : accountIds) {
            if (Limits.getCallouts() >= Limits.getLimitCallouts()) {
                break;
            }
            try {
                accounts.add(client.getAccount(accountId));
            } catch (OrdersApiClient.OrdersApiException e) {
                // Not fatal: the account keeps its placeholder name and is retried on its next order event.
                System.debug(LoggingLevel.WARN, 'Could not read Orders account ' + accountId + ': ' + e.getMessage());
                if (e.isRateLimited()) {
                    break;
                }
            }
        }
        return accounts;
    }
}

/**
 * Pulls every order of one Account from Orders (GET /accounts/{id}/orders, page by page).
 *
 * Why it exists: events only start once we subscribe, and there is no order.created event. Orders that
 * existed before, or whose events were lost (for example while the subscription was suspended), would
 * otherwise never appear in Salesforce. Agents start it with the "Sync Orders" button on the Account.
 *
 * One page per run (50 orders, 1-2 callouts), then it chains the next page. When all pages are done, orders
 * that have never had their details read are handed to OrderDetailsSyncJob (lines and participant are
 * not in the list response). Only one follow-up job is enqueued per run, as the platform requires.
 */
public without sharing class AccountOrdersBackfillJob implements Queueable, Database.AllowsCallouts {
    @TestVisible
    private static final Integer MAX_ATTEMPTS = 3;

    private final Id accountId;
    private final Integer page;
    private final Integer attempt;
    private final Set<Id> ordersNeedingDetails;

    public AccountOrdersBackfillJob(Id accountId) {
        this(accountId, 1, 1, new Set<Id>());
    }

    @TestVisible
    private AccountOrdersBackfillJob(Id accountId, Integer page, Integer attempt, Set<Id> ordersNeedingDetails) {
        this.accountId = accountId;
        this.page = page;
        this.attempt = attempt;
        this.ordersNeedingDetails = ordersNeedingDetails;
    }

    public void execute(QueueableContext context) {
        Account acc = [SELECT Id, Orders_Account_Id__c FROM Account WHERE Id = :accountId];
        OrdersApiClient client = new OrdersApiClient();
        OrdersApiClient.ApiAccount apiAccount;
        OrdersApiClient.OrdersPage result;
        try {
            if (page == 1) {
                apiAccount = client.getAccount(acc.Orders_Account_Id__c);
            }
            result = client.getAccountOrders(acc.Orders_Account_Id__c, page);
        } catch (OrdersApiClient.OrdersApiException e) {
            handleFailure(e);
            return;
        }

        ExternalOrderWriter writer = new ExternalOrderWriter();
        if (apiAccount != null) {
            writer.applyAccounts(new List<OrdersApiClient.ApiAccount>{ apiAccount });
        }
        for (External_Order__c order : writer.applyOrders(result.items, accountId).values()) {
            if (order.Details_Synced_At__c == null) {
                ordersNeedingDetails.add(order.Id);
            }
        }

        if (result.nextPage != null) {
            QueueableChain.enqueue(new AccountOrdersBackfillJob(accountId, result.nextPage, 1, ordersNeedingDetails), 0);
        } else if (!ordersNeedingDetails.isEmpty()) {
            QueueableChain.enqueue(new OrderDetailsSyncJob(ordersNeedingDetails, 1), 1); // 1 min: let the rate limit window reset
        }
    }

    private void handleFailure(OrdersApiClient.OrdersApiException e) {
        if (e.isRetryable() && attempt < MAX_ATTEMPTS) {
            QueueableChain.enqueue(
                new AccountOrdersBackfillJob(accountId, page, attempt + 1, ordersNeedingDetails),
                QueueableChain.minutesFor(e.retryAfterSeconds)
            );
            return;
        }
        // Not retryable (e.g. 404: this Orders account id does not exist) or out of attempts.
        System.debug(LoggingLevel.ERROR, 'Order backfill for Account ' + accountId + ' stopped on page ' + page + ': ' + e.getMessage());
        if (!ordersNeedingDetails.isEmpty()) {
            QueueableChain.enqueue(new OrderDetailsSyncJob(ordersNeedingDetails, 1), 1); // keep what earlier pages found
        }
    }
}

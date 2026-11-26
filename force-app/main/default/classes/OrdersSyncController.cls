/**
 * Backs the "Sync Orders" quick action on Account. Runs with sharing and in user mode: the agent must be
 * able to see the Account to start a sync for it. The sync itself then runs as a system process.
 */
public with sharing class OrdersSyncController {
    @AuraEnabled
    public static Id syncAccountOrders(Id accountId) {
        List<Account> accounts = [SELECT Id, Orders_Account_Id__c FROM Account WHERE Id = :accountId WITH USER_MODE];
        if (accounts.isEmpty()) {
            throw userError('Account not found or not accessible.');
        }
        if (String.isBlank(accounts[0].Orders_Account_Id__c)) {
            throw userError('This account is not linked to Orders. Fill in "Orders Account Id" first.');
        }
        return System.enqueueJob(new AccountOrdersBackfillJob(accountId));
    }

    private static AuraHandledException userError(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message); // so the message is also visible to tests and logs
        return e;
    }
}

// Deletes the demo account (and, through master-detail, its orders, lines and events) so the simulation can be re-run from scratch.
//   sf apex run --file scripts/apex/reset-demo-data.apex
delete [SELECT Id FROM Account WHERE Orders_Account_Id__c = 'acct_8f3c2a'];
System.debug(LoggingLevel.ERROR, 'Demo data removed.');

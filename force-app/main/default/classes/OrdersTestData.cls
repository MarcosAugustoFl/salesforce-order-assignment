/** Builders shared by the Orders integration tests. */
@IsTest
public class OrdersTestData {
    public static final String ACCOUNT_ID = 'acct_8f3c2a';
    public static final String ACCOUNT_FRIENDLY_ID = 'AC-260914-017-2231';

    public static String eventJson(String eventId, String status, String occurredAt, String orderId) {
        return JSON.serialize(
            new Map<String, Object>{
                'subscriptionId' => 'sub_a1b2c3d4e5f67890abcdef12',
                'event' => new Map<String, Object>{
                    'id' => eventId,
                    'type' => 'order.' + status,
                    'occurredAt' => occurredAt,
                    'version' => '1.0'
                },
                'data' => new Map<String, Object>{
                    'orderId' => orderId,
                    'orderFriendlyId' => 'OR-' + orderId,
                    'accountId' => ACCOUNT_ID,
                    'accountFriendlyId' => ACCOUNT_FRIENDLY_ID
                }
            }
        );
    }

    public static OrderEvent event(String eventId, String status, String occurredAt, String orderId) {
        return OrderEvent.parse(eventJson(eventId, status, occurredAt, orderId));
    }

    /** Calls the webhook exactly as Salesforce would for an HTTP POST, with a correct signature. */
    public static RestResponse post(String body) {
        return post(body, OrdersSignatureVerifier.sign(Blob.valueOf(body), OrdersIntegrationConfig.webhookSecret()));
    }

    public static RestResponse post(String body, String signature) {
        RestRequest request = new RestRequest();
        request.httpMethod = 'POST';
        request.requestURI = '/services/apexrest/orders/events';
        request.requestBody = Blob.valueOf(body);
        if (signature != null) {
            request.addHeader('Orders-Signature', signature);
        }
        RestContext.request = request;
        RestContext.response = new RestResponse();
        OrdersWebhookResource.receive();
        return RestContext.response;
    }

    public static Map<String, Object> responseBody(RestResponse response) {
        return (Map<String, Object>) JSON.deserializeUntyped(response.responseBody.toString());
    }

    /** A CX user: standard profile plus the Orders_Agent permission set, as documented in the README. */
    public static User agentUser() {
        User agent = new User(
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User'].Id,
            LastName = 'Agent',
            Email = 'agent@example.test',
            Username = 'orders.agent.' + Crypto.getRandomInteger() + '@example.test',
            Alias = 'agent',
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert agent;
        insert new PermissionSetAssignment(
            AssigneeId = agent.Id,
            PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Orders_Agent'].Id
        );
        return agent;
    }

    public static Account linkedAccount() {
        Account acc = new Account(Name = 'Northwind (existing)', Orders_Account_Id__c = ACCOUNT_ID);
        insert acc;
        return acc;
    }

    public static External_Order__c order(Id accountId, String orderId, String status, Datetime asOf) {
        External_Order__c order = new External_Order__c(
            Name = 'OR-' + orderId,
            Order_Id__c = orderId,
            Account__c = accountId,
            Status__c = status,
            Status_As_Of__c = asOf
        );
        insert order;
        return order;
    }

    public static External_Order__c reload(String orderId) {
        return [
            SELECT
                Id, Name, Status__c, Status_As_Of__c, Last_Event_Id__c, Amount__c, Currency__c, Participant_Ref__c,
                Order_Created_At__c, Details_Synced_At__c, Sync_Error__c, Account__c,
                (SELECT Line_Key__c, Name, Type__c, Status__c, Amount__c FROM Lines__r ORDER BY Name)
            FROM External_Order__c
            WHERE Order_Id__c = :orderId
        ];
    }

    public static String orderDetailJson(String orderId, String status, String updatedAt, List<String> lineIds) {
        List<Object> lines = new List<Object>();
        for (String lineId : lineIds) {
            lines.add(
                new Map<String, Object>{
                    'id' => lineId,
                    'type' => 'rollover',
                    'status' => status,
                    'amount' => new Map<String, Object>{ 'value' => '625.00', 'currency' => 'USD' }
                }
            );
        }
        return JSON.serialize(
            new Map<String, Object>{
                'id' => orderId,
                'friendlyId' => 'OR-' + orderId,
                'accountId' => ACCOUNT_ID,
                'participantRef' => 'p_4411',
                'status' => status,
                'amount' => new Map<String, Object>{ 'value' => '1250.00', 'currency' => 'USD' },
                'lines' => lines,
                'createdAt' => '2026-10-01T16:20:05Z',
                'updatedAt' => updatedAt
            }
        );
    }

    public static String accountJson() {
        return JSON.serialize(
            new Map<String, Object>{
                'id' => ACCOUNT_ID,
                'friendlyId' => ACCOUNT_FRIENDLY_ID,
                'name' => 'Northwind Plan Sponsor LLC',
                'status' => 'active',
                'updatedAt' => '2026-10-12T14:03:11Z'
            }
        );
    }
}

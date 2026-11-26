/**
 * Central place for integration settings.
 *
 * Inbound secret: protected Custom Metadata. A Named/External Credential cannot be used here because
 * Apex can never read its secrets; Salesforce only injects them into outbound callouts. We need the raw
 * secret to recompute the HMAC of inbound requests.
 *
 * Outbound: the Orders API is called through the Orders_API Named Credential, which holds the
 * Bearer token, so no credential appears in code or in this class.
 */
public inherited sharing class OrdersIntegrationConfig {
    public static final String ORDERS_API = 'callout:Orders_API';
    private static final String SETTING_NAME = 'Default';

    public static String webhookSecret() {
        Orders_Integration_Setting__mdt setting = Orders_Integration_Setting__mdt.getInstance(SETTING_NAME);
        if (setting == null || String.isBlank(setting.Webhook_Secret__c)) {
            throw new OrdersIntegrationException(
                'Orders webhook secret is not configured (Orders_Integration_Setting__mdt.' + SETTING_NAME + ').'
            );
        }
        return setting.Webhook_Secret__c;
    }
}

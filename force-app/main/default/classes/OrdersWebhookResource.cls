/**
 * Inbound endpoint for Orders events: POST /services/apexrest/orders/events
 *
 * Exposure: authenticated Apex REST. The caller (Orders) obtains an OAuth token for a dedicated
 * integration user (Client Credentials flow) and the HMAC signature is checked as a second layer.
 *
 * This class only translates HTTP to and from the service layer:
 *   401 - signature missing or wrong (never processed)
 *   400 - signed but not a valid event (sender bug; retrying will not help)
 *   200 - processed: applied, ignored as older, or a duplicate. All are success, so the sender stops retrying.
 *   500 - unexpected failure; everything is rolled back so the sender's retry starts clean.
 *
 * Only quick, local work happens here (well under the sender's 10s timeout). Calls back to the Orders
 * API happen asynchronously in OrderDetailsSyncJob.
 */
@RestResource(urlMapping='/orders/events')
global with sharing class OrdersWebhookResource {
    @TestVisible
    private static final String SIGNATURE_HEADER = 'Orders-Signature';

    @HttpPost
    global static void receive() {
        RestRequest request = RestContext.request;
        RestResponse response = RestContext.response;

        try {
            String signature = headerValue(request, SIGNATURE_HEADER);
            if (!OrdersSignatureVerifier.isValid(request.requestBody, signature, OrdersIntegrationConfig.webhookSecret())) {
                respond(response, 401, error('invalid_signature', 'Missing or invalid ' + SIGNATURE_HEADER + ' header.'));
                return;
            }
        } catch (OrdersIntegrationException e) {
            System.debug(LoggingLevel.ERROR, 'Orders webhook misconfigured: ' + e.getMessage());
            respond(response, 500, error('not_configured', 'Endpoint is not configured.'));
            return;
        }

        OrderEvent evt;
        try {
            evt = OrderEvent.parse(request.requestBody.toString());
        } catch (OrderEvent.InvalidEventException e) {
            respond(response, 400, error('invalid_event', e.getMessage()));
            return;
        }

        Savepoint savepoint = Database.setSavepoint();
        try {
            OrderEventService.ProcessResult result = new OrderEventService().process(new List<OrderEvent>{ evt });
            // Enqueue last: once the job is queued, nothing after it can fail and leave a half-done state.
            OrderDetailsSyncJob.enqueue(result.changedOrderIds);
            respond(
                response,
                200,
                new Map<String, Object>{ 'eventId' => evt.eventId, 'outcome' => result.results[0].outcome.name() }
            );
        } catch (Exception e) {
            Database.rollback(savepoint);
            System.debug(
                LoggingLevel.ERROR,
                'Orders event ' + evt.eventId + ' failed: ' + e.getMessage() + '\n' + e.getStackTraceString()
            );
            respond(response, 500, error('processing_failed', 'Event was not stored; please retry.'));
        }
    }

    /** Header names are case-insensitive in HTTP, but RestRequest.headers is a case-sensitive map. */
    private static String headerValue(RestRequest request, String name) {
        for (String key : request.headers.keySet()) {
            if (key.equalsIgnoreCase(name)) {
                return request.headers.get(key);
            }
        }
        return null;
    }

    private static Map<String, Object> error(String code, String message) {
        return new Map<String, Object>{ 'error' => code, 'message' => message };
    }

    private static void respond(RestResponse response, Integer statusCode, Map<String, Object> body) {
        response.statusCode = statusCode;
        response.addHeader('Content-Type', 'application/json');
        response.responseBody = Blob.valueOf(JSON.serialize(body));
    }
}

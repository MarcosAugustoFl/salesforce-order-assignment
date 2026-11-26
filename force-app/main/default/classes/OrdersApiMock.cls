/**
 * HttpCalloutMock for the Orders API. Register a response per path (relative to the Named Credential,
 * query string included). Unregistered paths return 404. Records every path called.
 */
@IsTest
public class OrdersApiMock implements HttpCalloutMock {
    private final Map<String, HttpResponse> responses = new Map<String, HttpResponse>();
    public final List<String> calledPaths = new List<String>();

    public OrdersApiMock respond(String path, Integer statusCode, String body) {
        HttpResponse response = new HttpResponse();
        response.setStatusCode(statusCode);
        response.setHeader('Content-Type', 'application/json');
        response.setBody(body == null ? '' : body);
        responses.put(path, response);
        return this;
    }

    public OrdersApiMock rateLimit(String path, Integer retryAfterSeconds) {
        respond(path, 429, '{"error":"rate_limited"}');
        responses.get(path).setHeader('Retry-After', String.valueOf(retryAfterSeconds));
        return this;
    }

    public HttpResponse respond(HttpRequest request) {
        String path = request.getEndpoint().removeStart(OrdersIntegrationConfig.ORDERS_API);
        calledPaths.add(path);
        Assert.areEqual('GET', request.getMethod(), 'Orders is read-only for Salesforce');
        if (responses.containsKey(path)) {
            return responses.get(path);
        }
        HttpResponse notFound = new HttpResponse();
        notFound.setStatusCode(404);
        notFound.setBody('{"error":"not_found"}');
        return notFound;
    }
}

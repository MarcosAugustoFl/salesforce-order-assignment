/**
 * Read-only client for the Orders API, called through the Orders_API Named Credential
 * (the Named Credential adds "Authorization: Bearer <token>", so no secret lives in code).
 *
 * Returns plain Apex objects and throws OrdersApiException with the HTTP status (and Retry-After on 429)
 * so callers can decide what is retryable. It has no knowledge of Salesforce records.
 */
public inherited sharing class OrdersApiClient {
    public static final Integer PAGE_SIZE = 50;
    private static final Integer TIMEOUT_MS = 20000;

    public class OrdersApiException extends Exception {
        public Integer statusCode;
        public Integer retryAfterSeconds;

        public Boolean isRateLimited() {
            return statusCode == 429;
        }

        public Boolean isNotFound() {
            return statusCode == 404;
        }

        /** Rate limiting, server errors and network failures may succeed later; 4xx otherwise will not. */
        public Boolean isRetryable() {
            return statusCode == null || statusCode == 429 || statusCode >= 500;
        }
    }

    public class ApiAccount {
        public String id;
        public String friendlyId;
        public String name;
        public String status;
        public Datetime updatedAt;
    }

    public class ApiOrderLine {
        public String id;
        public String lineType;
        public String status;
        public Decimal amount;
        public String currencyCode;
    }

    public class ApiOrder {
        public String id;
        public String friendlyId;
        public String accountId;
        public String participantRef;
        public String status;
        public Decimal amount;
        public String currencyCode;
        public Datetime createdAt;
        public Datetime updatedAt;
        /** Only GET /orders/{id} returns lines; list items do not. */
        public Boolean hasDetails = false;
        public List<ApiOrderLine> lines = new List<ApiOrderLine>();
    }

    public class OrdersPage {
        public List<ApiOrder> items = new List<ApiOrder>();
        public Integer nextPage;
    }

    public ApiAccount getAccount(String accountId) {
        JsonReader body = get('/accounts/' + encode(accountId));
        ApiAccount account = new ApiAccount();
        account.id = body.getString('id');
        account.friendlyId = body.getString('friendlyId');
        account.name = body.getString('name');
        account.status = body.getString('status');
        account.updatedAt = body.getDatetime('updatedAt');
        return account;
    }

    public ApiOrder getOrder(String orderId) {
        ApiOrder order = toOrder(get('/orders/' + encode(orderId)));
        order.hasDetails = true;
        return order;
    }

    public OrdersPage getAccountOrders(String accountId, Integer page) {
        JsonReader body = get('/accounts/' + encode(accountId) + '/orders?page=' + page + '&pageSize=' + PAGE_SIZE);
        OrdersPage result = new OrdersPage();
        for (JsonReader item : body.getObjectList('items')) {
            result.items.add(toOrder(item));
        }
        result.nextPage = body.getInteger('nextPage');
        return result;
    }

    private static ApiOrder toOrder(JsonReader json) {
        ApiOrder order = new ApiOrder();
        order.id = json.requireString('id');
        order.friendlyId = json.getString('friendlyId');
        order.accountId = json.getString('accountId');
        order.participantRef = json.getString('participantRef');
        order.status = json.getString('status');
        order.createdAt = json.getDatetime('createdAt');
        order.updatedAt = json.getDatetime('updatedAt');
        JsonReader amount = json.getObject('amount');
        if (amount != null) {
            order.amount = amount.getDecimal('value');
            order.currencyCode = amount.getString('currency');
        }
        for (JsonReader lineJson : json.getObjectList('lines')) {
            ApiOrderLine line = new ApiOrderLine();
            line.id = lineJson.requireString('id');
            line.lineType = lineJson.getString('type');
            line.status = lineJson.getString('status');
            JsonReader lineAmount = lineJson.getObject('amount');
            if (lineAmount != null) {
                line.amount = lineAmount.getDecimal('value');
                line.currencyCode = lineAmount.getString('currency');
            }
            order.lines.add(line);
        }
        return order;
    }

    private JsonReader get(String path) {
        HttpRequest request = new HttpRequest();
        request.setMethod('GET');
        request.setEndpoint(OrdersIntegrationConfig.ORDERS_API + path);
        request.setHeader('Accept', 'application/json');
        request.setTimeout(TIMEOUT_MS);

        HttpResponse response;
        try {
            response = new Http().send(request);
        } catch (CalloutException e) {
            throw failure(null, null, 'Orders API unreachable: ' + e.getMessage());
        }

        Integer status = response.getStatusCode();
        if (status == 200) {
            try {
                return JsonReader.parse(response.getBody());
            } catch (JsonReader.JsonReaderException e) {
                throw failure(status, null, 'Orders API returned an unreadable body: ' + e.getMessage());
            }
        }
        String retryAfter = response.getHeader('Retry-After');
        throw failure(
            status,
            String.isNotBlank(retryAfter) && retryAfter.isNumeric() ? Integer.valueOf(retryAfter) : null,
            'Orders API ' + path + ' returned HTTP ' + status
        );
    }

    private static OrdersApiException failure(Integer statusCode, Integer retryAfterSeconds, String message) {
        OrdersApiException e = new OrdersApiException(message);
        e.statusCode = statusCode;
        e.retryAfterSeconds = retryAfterSeconds;
        return e;
    }

    private static String encode(String value) {
        return EncodingUtil.urlEncode(value, 'UTF-8');
    }
}

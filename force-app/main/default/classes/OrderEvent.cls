/**
 * One order status event as delivered by Orders, parsed and validated.
 * Holds only what the payload carries; anything else (amount, lines, names) is read from the API later.
 */
public inherited sharing class OrderEvent {
    public class InvalidEventException extends Exception {
    }

    private static final Integer MAX_PAYLOAD_LENGTH = 32768; // External_Order_Event__c.Raw_Payload__c

    public String subscriptionId;
    public String eventId;
    public String eventType;
    public String status; // derived from eventType
    public Datetime occurredAt;
    public String version;
    public String orderId;
    public String orderFriendlyId;
    public String accountId;
    public String accountFriendlyId;
    public String rawPayload;

    public static OrderEvent parse(String body) {
        try {
            JsonReader root = JsonReader.parse(body);
            JsonReader meta = root.requireObject('event');
            JsonReader data = root.requireObject('data');

            OrderEvent evt = new OrderEvent();
            evt.subscriptionId = root.getString('subscriptionId');
            evt.eventId = meta.requireString('id');
            evt.eventType = meta.requireString('type');
            evt.occurredAt = meta.requireDatetime('occurredAt');
            evt.version = meta.getString('version');
            evt.orderId = data.requireString('orderId');
            evt.orderFriendlyId = data.getString('orderFriendlyId');
            evt.accountId = data.requireString('accountId');
            evt.accountFriendlyId = data.getString('accountFriendlyId');
            evt.rawPayload = body.abbreviate(MAX_PAYLOAD_LENGTH);

            evt.status = OrderStatus.fromEventType(evt.eventType);
            if (evt.status == null) {
                throw new InvalidEventException('Unsupported event type: ' + evt.eventType);
            }
            if (evt.version != null && !evt.version.startsWith('1.')) {
                throw new InvalidEventException('Unsupported event version: ' + evt.version);
            }
            return evt;
        } catch (JsonReader.JsonReaderException e) {
            throw new InvalidEventException(e.getMessage());
        }
    }
}

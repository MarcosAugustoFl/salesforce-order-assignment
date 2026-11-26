/**
 * Order status vocabulary and the single rule that decides which information about an order wins.
 *
 * Rule: information with a later timestamp (event occurredAt, or the API's updatedAt) replaces older
 * information. On an exact tie, the status further along the lifecycle wins, since the spec says statuses
 * only move forward. Every writer (webhook, detail sync, backfill) uses this rule, so arrival order and
 * the source of the information never matter.
 */
public inherited sharing class OrderStatus {
    // Lifecycle order from the spec. "returned" can follow "sent" or "cleared", so it ranks last.
    private static final List<String> LIFECYCLE = new List<String>{
        'created',
        'inProgress',
        'waitingForParticipant',
        'sent',
        'cleared',
        'returned'
    };
    private static final String EVENT_TYPE_PREFIX = 'order.';

    public static Boolean isKnown(String status) {
        return status != null && LIFECYCLE.contains(status);
    }

    /** Position in the lifecycle; -1 for blank or unknown. */
    public static Integer rank(String status) {
        return status == null ? -1 : LIFECYCLE.indexOf(status);
    }

    /** "order.sent" -> "sent"; null if the type is not an order status event we know. */
    public static String fromEventType(String eventType) {
        if (eventType == null || !eventType.startsWith(EVENT_TYPE_PREFIX)) {
            return null;
        }
        String status = eventType.substringAfter(EVENT_TYPE_PREFIX);
        return isKnown(status) ? status : null;
    }

    /** True when (candidateStatus as of candidateAsOf) is newer than what Salesforce currently holds. */
    public static Boolean supersedes(
        String currentStatus,
        Datetime currentAsOf,
        String candidateStatus,
        Datetime candidateAsOf
    ) {
        if (currentAsOf == null) {
            return true;
        }
        if (candidateAsOf == null) {
            return false;
        }
        if (candidateAsOf != currentAsOf) {
            return candidateAsOf > currentAsOf;
        }
        return rank(candidateStatus) > rank(currentStatus);
    }
}

/**
 * Small typed reader over JSON.deserializeUntyped output.
 *
 * Used for both inbound events and Orders API responses. Reading untyped (instead of
 * JSON.deserialize into DTO classes) lets us give precise errors ("event.occurredAt is required")
 * and avoids Apex reserved words in JSON keys such as "type".
 */
public inherited sharing class JsonReader {
    public class JsonReaderException extends Exception {
    }

    private final Map<String, Object> values;
    private final String path;

    public static JsonReader parse(String body) {
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(body);
        } catch (Exception e) {
            throw new JsonReaderException('Body is not valid JSON.');
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw new JsonReaderException('Body is not a JSON object.');
        }
        return new JsonReader((Map<String, Object>) parsed, '');
    }

    private JsonReader(Map<String, Object> values, String path) {
        this.values = values;
        this.path = path;
    }

    public String getString(String key) {
        Object value = values.get(key);
        if (value == null) {
            return null;
        }
        if (value instanceof String) {
            return (String) value;
        }
        throw invalid(key, 'a string');
    }

    public String requireString(String key) {
        String value = getString(key);
        if (String.isBlank(value)) {
            throw missing(key);
        }
        return value;
    }

    /** ISO-8601, e.g. 2026-10-12T14:03:11Z. */
    public Datetime getDatetime(String key) {
        String value = getString(key);
        if (value == null) {
            return null;
        }
        try {
            return (Datetime) JSON.deserialize('"' + value + '"', Datetime.class);
        } catch (Exception e) {
            throw invalid(key, 'an ISO-8601 timestamp');
        }
    }

    public Datetime requireDatetime(String key) {
        Datetime value = getDatetime(key);
        if (value == null) {
            throw missing(key);
        }
        return value;
    }

    /** Accepts a JSON number or a numeric string (Orders sends amounts as strings, e.g. "1250.00"). */
    public Decimal getDecimal(String key) {
        Object value = values.get(key);
        if (value == null) {
            return null;
        }
        try {
            return value instanceof String ? Decimal.valueOf((String) value) : (Decimal) value;
        } catch (Exception e) {
            throw invalid(key, 'a number');
        }
    }

    public Integer getInteger(String key) {
        Decimal value = getDecimal(key);
        return value == null ? null : value.intValue();
    }

    public JsonReader getObject(String key) {
        Object value = values.get(key);
        if (value == null) {
            return null;
        }
        if (!(value instanceof Map<String, Object>)) {
            throw invalid(key, 'an object');
        }
        return new JsonReader((Map<String, Object>) value, qualify(key) + '.');
    }

    public JsonReader requireObject(String key) {
        JsonReader value = getObject(key);
        if (value == null) {
            throw missing(key);
        }
        return value;
    }

    public List<JsonReader> getObjectList(String key) {
        List<JsonReader> result = new List<JsonReader>();
        Object value = values.get(key);
        if (value == null) {
            return result;
        }
        if (!(value instanceof List<Object>)) {
            throw invalid(key, 'an array');
        }
        List<Object> items = (List<Object>) value;
        for (Integer i = 0; i < items.size(); i++) {
            if (!(items[i] instanceof Map<String, Object>)) {
                throw invalid(key + '[' + i + ']', 'an object');
            }
            result.add(new JsonReader((Map<String, Object>) items[i], qualify(key) + '[' + i + '].'));
        }
        return result;
    }

    private String qualify(String key) {
        return path + key;
    }

    private JsonReaderException missing(String key) {
        return new JsonReaderException(qualify(key) + ' is required.');
    }

    private JsonReaderException invalid(String key, String expected) {
        return new JsonReaderException(qualify(key) + ' must be ' + expected + '.');
    }
}

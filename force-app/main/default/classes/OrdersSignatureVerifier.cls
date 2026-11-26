/**
 * Verifies the Orders-Signature header: hex(HMAC-SHA256(key = shared secret, message = raw body bytes)).
 *
 * The HMAC must be computed over the exact bytes received (RestRequest.requestBody), never over
 * re-serialized JSON, because any whitespace or key-order change would alter the signature.
 */
public inherited sharing class OrdersSignatureVerifier {
    public static String sign(Blob body, String secret) {
        return EncodingUtil.convertToHex(Crypto.generateMac('hmacSHA256', body, Blob.valueOf(secret)));
    }

    public static Boolean isValid(Blob rawBody, String signatureHeader, String secret) {
        if (rawBody == null || String.isBlank(signatureHeader)) {
            return false;
        }
        return constantTimeEquals(sign(rawBody, secret), signatureHeader.trim().toLowerCase());
    }

    /**
     * Compares every character instead of stopping at the first mismatch, so response time does not
     * reveal how many leading characters of a forged signature were correct.
     */
    private static Boolean constantTimeEquals(String expected, String actual) {
        if (expected.length() != actual.length()) {
            return false;
        }
        Integer difference = 0;
        for (Integer i = 0; i < expected.length(); i++) {
            difference |= expected.charAt(i) ^ actual.charAt(i);
        }
        return difference == 0;
    }
}

@IsTest
private class OrdersSignatureVerifierTest {
    // Reference value computed outside Salesforce:
    //   printf '%s' '{"hello":"world"}' | openssl dgst -sha256 -hmac 'orders-takehome-2026'
    private static final String BODY = '{"hello":"world"}';
    private static final String EXPECTED = 'e5b6b81e15c0ba590bbe4983642f5ecafa21de982f9e3c9e5b657b2494d6a209';
    private static final String SECRET = 'orders-takehome-2026';

    @IsTest
    static void signMatchesExternalImplementation() {
        Assert.areEqual(EXPECTED, OrdersSignatureVerifier.sign(Blob.valueOf(BODY), SECRET));
    }

    @IsTest
    static void acceptsCorrectSignatureInAnyCase() {
        Assert.isTrue(OrdersSignatureVerifier.isValid(Blob.valueOf(BODY), EXPECTED, SECRET));
        Assert.isTrue(OrdersSignatureVerifier.isValid(Blob.valueOf(BODY), EXPECTED.toUpperCase(), SECRET));
    }

    @IsTest
    static void rejectsWrongMissingOrTamperedSignatures() {
        Assert.isFalse(OrdersSignatureVerifier.isValid(Blob.valueOf(BODY), null, SECRET), 'missing');
        Assert.isFalse(OrdersSignatureVerifier.isValid(Blob.valueOf(BODY), 'abc', SECRET), 'wrong length');
        Assert.isFalse(OrdersSignatureVerifier.isValid(Blob.valueOf(BODY), EXPECTED, 'other-secret'), 'wrong secret');
        Assert.isFalse(OrdersSignatureVerifier.isValid(Blob.valueOf(BODY + ' '), EXPECTED, SECRET), 'body changed by one byte');
    }

    @IsTest
    static void configuredSecretIsTheFixture() {
        Assert.areEqual(SECRET, OrdersIntegrationConfig.webhookSecret());
    }
}

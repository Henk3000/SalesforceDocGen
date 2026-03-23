@isTest
private class BarcodeGeneratorTest {

    @isTest
    static void testGetPatternCode128() {
        String pattern = BarcodeGenerator.getPattern('TEST-123', 'code128');
        System.assertNotEquals(null, pattern, 'Pattern should not be null');
        // Code 128: Start B (11) + 8 chars * 11 modules + checksum (11) + stop (13) = 123 modules
        System.assert(pattern.length() > 0, 'Pattern should have length');
        // Every character in pattern should be 0 or 1
        for (Integer i = 0; i < pattern.length(); i++) {
            String c = pattern.substring(i, i + 1);
            System.assert(c == '0' || c == '1', 'Pattern should only contain 0s and 1s: ' + c);
        }
    }

    @isTest
    static void testGetPatternNullAndBlank() {
        System.assertEquals(null, BarcodeGenerator.getPattern(null, 'code128'));
        System.assertEquals(null, BarcodeGenerator.getPattern('', 'code128'));
        System.assertEquals(null, BarcodeGenerator.getPattern('test', 'unsupported'));
    }

    @isTest
    static void testGetPatternDefaultType() {
        String pattern = BarcodeGenerator.getPattern('ABC', null);
        System.assertNotEquals(null, pattern, 'Null type should default to code128');
    }

    @isTest
    static void testGenerateBmp() {
        Blob bmp = BarcodeGenerator.generate('HELLO', 'code128');
        System.assertNotEquals(null, bmp, 'BMP blob should not be null');
        System.assert(bmp.size() > 62, 'BMP should be larger than the header (62 bytes)');
        // Verify BMP magic bytes: 0x42 0x4D = 'BM'
        String hex = EncodingUtil.convertToHex(bmp);
        System.assertEquals('424d', hex.substring(0, 4).toLowerCase(), 'Should start with BM magic bytes');
    }

    @isTest
    static void testGenerateNullAndBlank() {
        System.assertEquals(null, BarcodeGenerator.generate(null, 'code128'));
        System.assertEquals(null, BarcodeGenerator.generate('', 'code128'));
    }

    @isTest
    static void testSpecialCharacters() {
        // Should handle all printable ASCII without error
        String pattern = BarcodeGenerator.getPattern('!@#$%^&*()_+-=[]{}|;:,.<>?', 'code128');
        System.assertNotEquals(null, pattern);
        Blob bmp = BarcodeGenerator.generate('Special: 100% Done!', 'code128');
        System.assertNotEquals(null, bmp);
    }

    @isTest
    static void testConsistentOutput() {
        // Same input should produce same pattern
        String p1 = BarcodeGenerator.getPattern('SAME', 'code128');
        String p2 = BarcodeGenerator.getPattern('SAME', 'code128');
        System.assertEquals(p1, p2, 'Same input should produce same pattern');
    }
}

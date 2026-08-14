import 'package:flutter_test/flutter_test.dart';
import 'package:iraq_cycling/utils/heart_rate_parser.dart';

void main() {
  group('parseHeartRateBpm', () {
    test('flags bit0=0 (UINT8): extracts BPM from byte 1', () {
      // flags = 0x00 (UINT8, no other flags), HR value = 72 bpm.
      final bytes = [0x00, 72];
      expect(parseHeartRateBpm(bytes), 72);
    });

    test('flags bit0=1 (UINT16): extracts BPM from little-endian bytes 1-2 '
        '(the case most likely to be implemented incorrectly, e.g. by some '
        'Fitbit devices)', () {
      // flags = 0x01 (UINT16), HR value = 300 bpm = 0x012C -> low byte
      // 0x2C, high byte 0x01. A naive UINT8-only parser would incorrectly
      // read this as 44 (0x2C) instead of 300.
      final bytes = [0x01, 0x2C, 0x01];
      expect(parseHeartRateBpm(bytes), 300);
    });

    test('flags bit0=1 with a realistic BPM value under 256 still decodes '
        'correctly as UINT16, not truncated to UINT8', () {
      // HR value = 88 bpm encoded as UINT16: low byte 0x58, high byte 0x00.
      final bytes = [0x01, 0x58, 0x00];
      expect(parseHeartRateBpm(bytes), 88);
    });

    test('empty byte array returns null instead of throwing', () {
      expect(parseHeartRateBpm(const []), isNull);
    });

    test('UINT8-flagged byte array missing the value byte returns null '
        'instead of throwing', () {
      final bytes = [0x00]; // flags only, no HR value byte
      expect(parseHeartRateBpm(bytes), isNull);
    });

    test('UINT16-flagged byte array missing the second value byte returns '
        'null instead of throwing', () {
      final bytes = [0x01, 0x2C]; // flags + only 1 of 2 value bytes
      expect(parseHeartRateBpm(bytes), isNull);
    });
  });
}

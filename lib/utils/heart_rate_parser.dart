/// Parses the raw bytes of a Bluetooth GATT Heart Rate Measurement
/// characteristic (UUID 0x2A37, part of the standard Heart Rate Service
/// 0x180D) per the official Bluetooth SIG specification.
///
/// Byte 0 is a flags byte; bit 0 selects the encoding of the heart rate
/// value that follows: 0 = UINT8 (byte 1 only), 1 = UINT16 (bytes 1-2,
/// little-endian). Devices are free to use either encoding, so both must be
/// handled — some devices (including Fitbit) use UINT16.
///
/// Returns null for a malformed/too-short byte array instead of throwing,
/// so a single bad reading cannot crash the BPM stream.
int? parseHeartRateBpm(List<int> bytes) {
  if (bytes.isEmpty) return null;

  final flags = bytes[0];
  final isUint16 = (flags & 0x01) != 0;

  if (isUint16) {
    if (bytes.length < 3) return null;
    return bytes[1] | (bytes[2] << 8);
  }

  if (bytes.length < 2) return null;
  return bytes[1];
}

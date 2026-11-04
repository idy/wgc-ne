import 'dart:convert';

void validateWireGuardKey(String value) {
  try {
    final decoded = base64Decode(value);
    if (decoded.length == 32 && base64Encode(decoded) == value) {
      return;
    }
  } catch (_) {/* Return only a fixed, non-secret validation error. */}
  throw const FormatException(
      'WireGuard keys must be canonical Base64 with 32 bytes.');
}

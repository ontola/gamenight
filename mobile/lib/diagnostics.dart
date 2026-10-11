/// Only static operation descriptions belong here, never request bodies or URLs.
class Diagnostics {
  static void Function(String message)? onFailure;
  static void failure(String message) {
    try {
      onFailure?.call(message);
    } catch (_) {/* Reporting cannot break play. */}
  }
}

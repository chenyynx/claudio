typedef DeepLinkHandler = void Function(Uri uri);

/// Delays deep-link delivery until the app router is mounted.
///
/// Every platform event is dispatched exactly once and in arrival order. The
/// same URI may still be opened again later as a separate, valid user action.
class DeepLinkDispatcher {
  DeepLinkDispatcher(this._handler);

  final DeepLinkHandler _handler;
  final List<Uri> _pending = [];
  bool _ready = false;
  bool _draining = false;

  void add(Uri uri) {
    if (_ready) {
      _handler(uri);
      return;
    }
    _pending.add(uri);
  }

  void markReady() {
    if (_ready || _draining) return;
    _draining = true;
    try {
      // Keep newly arriving links behind those already queued, even if the
      // handler synchronously triggers another platform event.
      while (_pending.isNotEmpty) {
        _handler(_pending.removeAt(0));
      }
      _ready = true;
    } finally {
      _draining = false;
    }
  }
}

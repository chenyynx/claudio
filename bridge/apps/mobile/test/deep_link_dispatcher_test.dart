import 'package:flutter_test/flutter_test.dart';

import 'package:ccpocket/services/deep_link_dispatcher.dart';

void main() {
  group('DeepLinkDispatcher', () {
    test('queues links until ready and preserves arrival order', () {
      final received = <Uri>[];
      final dispatcher = DeepLinkDispatcher(received.add);
      final first = Uri.parse('ccpocket://session/first');
      final second = Uri.parse('ccpocket://session/second');

      dispatcher
        ..add(first)
        ..add(second);

      expect(received, isEmpty);

      dispatcher.markReady();

      expect(received, [first, second]);
    });

    test('dispatches links immediately after becoming ready', () {
      final received = <Uri>[];
      final dispatcher = DeepLinkDispatcher(received.add)..markReady();
      final uri = Uri.parse('ccpocket://connect?url=ws://localhost:8765');

      dispatcher.add(uri);

      expect(received, [uri]);
    });

    test('allows the same URI to be opened again later', () {
      final received = <Uri>[];
      final dispatcher = DeepLinkDispatcher(received.add)..markReady();
      final uri = Uri.parse('ccpocket://session/repeated');

      dispatcher
        ..add(uri)
        ..add(uri);

      expect(received, [uri, uri]);
    });

    test('markReady is idempotent', () {
      final received = <Uri>[];
      final dispatcher = DeepLinkDispatcher(received.add);
      final uri = Uri.parse('ccpocket://session/once');
      dispatcher.add(uri);

      dispatcher
        ..markReady()
        ..markReady();

      expect(received, [uri]);
    });

    test('keeps queued order when a handler adds another link', () {
      final first = Uri.parse('ccpocket://session/first');
      final second = Uri.parse('ccpocket://session/second');
      final third = Uri.parse('ccpocket://session/third');
      final received = <Uri>[];
      late final DeepLinkDispatcher dispatcher;
      dispatcher = DeepLinkDispatcher((uri) {
        received.add(uri);
        if (uri == first) dispatcher.add(third);
      });

      dispatcher
        ..add(first)
        ..add(second)
        ..markReady();

      expect(received, [first, second, third]);
    });
  });
}

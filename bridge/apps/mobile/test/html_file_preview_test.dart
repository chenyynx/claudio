import 'package:ccpocket/features/file_peek/widgets/html_file_preview.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('claims gestures before the draggable sheet', () {
    final factories = createHtmlPreviewGestureRecognizers();
    final recognizer = factories.single.constructor();
    addTearDown(recognizer.dispose);

    expect(recognizer, isA<EagerGestureRecognizer>());
  });
}

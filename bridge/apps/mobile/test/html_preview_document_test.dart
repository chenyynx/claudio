import 'package:ccpocket/features/file_peek/html_preview_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isHtmlPreviewPath', () {
    test('accepts html and htm paths case-insensitively', () {
      expect(isHtmlPreviewPath('docs/design.html'), isTrue);
      expect(isHtmlPreviewPath('docs/legacy.HTM'), isTrue);
      expect(isHtmlPreviewPath('docs/readme.md'), isFalse);
    });
  });

  group('buildSafeHtmlPreviewDocument', () {
    test('places restrictions before all source markup', () {
      const source =
          '<!doctype html><html><head><title>Demo</title></head>'
          '<body>Hello</body></html>';

      final document = buildSafeHtmlPreviewDocument(source);
      final cspIndex = document.indexOf('Content-Security-Policy');
      final sourceIndex = document.indexOf(source);

      expect(cspIndex, greaterThan(document.indexOf('<!doctype html>')));
      expect(cspIndex, lessThan(sourceIndex));
      expect(document, contains("script-src 'none'"));
      expect(document, contains("connect-src 'none'"));
      expect(document, contains("form-action 'none'"));
      expect(document, contains('name="viewport"'));
      expect(document, contains('<body>Hello</body>'));
    });

    test('a fake head in a comment cannot capture the policy', () {
      const source =
          '<!-- <head> -->'
          '<html><head><title>Demo</title></head>'
          '<body><img src="https://example.com/pixel"></body></html>';

      final document = buildSafeHtmlPreviewDocument(source);
      final cspIndex = document.indexOf('Content-Security-Policy');
      final commentIndex = document.indexOf('<!-- <head> -->');

      expect(cspIndex, lessThan(commentIndex));
      expect(document.substring(0, commentIndex), isNot(contains('<!--')));
    });

    test('prefixes an HTML fragment with a protected document head', () {
      final document = buildSafeHtmlPreviewDocument('<h1>Hello</h1>');

      expect(document, startsWith('<!doctype html>'));
      expect(
        document.indexOf('Content-Security-Policy'),
        lessThan(document.indexOf('<h1>Hello</h1>')),
      );
    });

    test('removes meta refresh navigation', () {
      const source =
          '<html><head>'
          '<meta http-equiv="refresh" content="0;url=https://example.com">'
          '</head><body></body></html>';

      final document = buildSafeHtmlPreviewDocument(source);

      expect(document.toLowerCase(), isNot(contains('http-equiv="refresh"')));
      expect(document, contains('Content-Security-Policy'));
    });
  });

  group('HtmlPreviewNavigationGate', () {
    test('allows at most one internal initial navigation', () {
      final gate = HtmlPreviewNavigationGate();

      expect(gate.allowNavigation('data:text/html,preview'), isTrue);
      expect(gate.allowNavigation('data:text/html,replacement'), isFalse);
      expect(gate.allowNavigation('about:blank'), isFalse);
    });

    test('blocks external navigation and closes the initial gate', () {
      final gate = HtmlPreviewNavigationGate();

      expect(gate.allowNavigation('https://example.com'), isFalse);
      expect(gate.allowNavigation('data:text/html,preview'), isFalse);
    });

    test('blocks replacement navigation after the page starts', () {
      final gate = HtmlPreviewNavigationGate()..markPageStarted();

      expect(gate.allowNavigation('data:text/html,replacement'), isFalse);
      expect(gate.allowNavigation('about:blank'), isFalse);
    });
  });
}

const _previewContentSecurityPolicy =
    "default-src 'none'; "
    "img-src data: blob:; "
    "media-src data: blob:; "
    "font-src data:; "
    "style-src 'unsafe-inline' data:; "
    "script-src 'none'; "
    "connect-src 'none'; "
    "frame-src 'none'; "
    "object-src 'none'; "
    "base-uri 'none'; "
    "form-action 'none'";

const _contentSecurityPolicyMeta =
    '<meta http-equiv="Content-Security-Policy" '
    'content="$_previewContentSecurityPolicy">';

const _viewportMeta =
    '<meta name="viewport" '
    'content="width=device-width, initial-scale=1">';

final _refreshPattern = RegExp(
  r'''<meta\s+[^>]*http-equiv\s*=\s*["']?refresh["']?[^>]*>''',
  caseSensitive: false,
);

bool isHtmlPreviewPath(String filePath) {
  final lowerPath = filePath.toLowerCase();
  return lowerPath.endsWith('.html') || lowerPath.endsWith('.htm');
}

/// Prepares agent-generated HTML for an isolated, read-only preview.
///
/// Inline styles and data/blob media remain available so standalone design
/// documents render correctly. Scripts, external requests, frames, forms, and
/// base URL changes are blocked by the injected Content Security Policy.
String buildSafeHtmlPreviewDocument(String source) {
  final safeSource = source.replaceAll(_refreshPattern, '');

  // Keep the trusted policy before every byte of agent-provided markup.
  // Browsers place these leading meta elements in the implied document head,
  // so a fake `<head>` inside a comment or malformed source cannot capture the
  // policy and leave the actual document unrestricted.
  return '<!doctype html>\n'
      '$_contentSecurityPolicyMeta\n'
      '$_viewportMeta\n'
      '$safeSource';
}

/// Allows only the WebView's first internal HTML-document navigation.
///
/// The gate is also closed as soon as the initial page starts. That prevents a
/// meta refresh or link from replacing the protected document with a second
/// `data:`/`about:` document before the first page finishes loading.
class HtmlPreviewNavigationGate {
  bool _initialNavigationPending = true;

  bool allowNavigation(String url) {
    final uri = Uri.tryParse(url);
    final allowed =
        _initialNavigationPending &&
        uri != null &&
        (uri.scheme == 'data' || uri.scheme == 'about');
    _initialNavigationPending = false;
    return allowed;
  }

  void markPageStarted() {
    _initialNavigationPending = false;
  }
}

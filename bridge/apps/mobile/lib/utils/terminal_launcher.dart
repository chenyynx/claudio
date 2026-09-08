import 'package:url_launcher/url_launcher.dart';

import '../models/terminal_app.dart';

/// Expands a URL template by replacing placeholders with actual values.
///
/// Supported placeholders: `{{host}}`, `{{user}}`, `{{port}}`,
/// `{{project_path}}`.
String expandTerminalUrl({
  required String template,
  required String host,
  String user = '',
  int port = 22,
  String projectPath = '',
}) {
  return template
      .replaceAll('{{host}}', host)
      .replaceAll('{{user}}', user)
      .replaceAll('{{port}}', port.toString())
      .replaceAll('{{project_path}}', projectPath);
}

/// Launch the configured terminal app for the given session context.
///
/// Returns `true` if the URL was successfully launched.
Future<bool> launchTerminalApp({
  required TerminalAppConfig config,
  required String host,
  String? sshUser,
  int port = 22,
  String projectPath = '',
}) async {
  if (!config.isConfigured) return false;

  final user = config.sshUser?.isNotEmpty == true
      ? config.sshUser!
      : sshUser ?? '';

  final url = expandTerminalUrl(
    template: config.urlTemplate,
    host: host,
    user: user,
    port: port,
    projectPath: projectPath,
  );

  final uri = Uri.parse(url);
  // Don't use canLaunchUrl — it requires declaring every possible URL scheme
  // in Info.plist (iOS) / AndroidManifest.xml (Android), which is impractical
  // for user-configurable custom URLs. Instead, try launching directly.
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

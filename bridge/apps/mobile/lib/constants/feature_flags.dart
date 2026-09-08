enum AppFeature { terminalAppIntegration }

/// Minimal compile-time feature flags.
///
/// Re-enable a flag with `--dart-define`, for example:
/// `--dart-define=FEATURE_TERMINAL_APP_INTEGRATION=true`
class FeatureFlags {
  const FeatureFlags({this.terminalAppIntegration = false});

  static const current = FeatureFlags(
    terminalAppIntegration: bool.fromEnvironment(
      'FEATURE_TERMINAL_APP_INTEGRATION',
      defaultValue: false,
    ),
  );

  final bool terminalAppIntegration;

  bool isEnabled(AppFeature feature) {
    switch (feature) {
      case AppFeature.terminalAppIntegration:
        return terminalAppIntegration;
    }
  }
}

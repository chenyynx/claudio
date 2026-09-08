import 'package:ccpocket/constants/feature_flags.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FeatureFlags', () {
    test('defaults terminal app integration to disabled', () {
      expect(FeatureFlags.current.terminalAppIntegration, isFalse);
    });

    test('isEnabled resolves terminal app integration', () {
      const flags = FeatureFlags(terminalAppIntegration: false);
      expect(flags.isEnabled(AppFeature.terminalAppIntegration), isFalse);
    });
  });
}

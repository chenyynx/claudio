import 'package:ccpocket/services/platform_environment_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlatformEnvironmentService', () {
    test('returns gateway value', () async {
      final service = PlatformEnvironmentService.test(
        gateway: const _FakePlatformEnvironmentGateway(
          isIOSAppOnMacValue: true,
          iosUserInterfaceIdiomValue: 'pad',
        ),
      );

      expect(await service.isIOSAppOnMac(), isTrue);
      expect(await service.iosUserInterfaceIdiom(), 'pad');
    });
  });

  group('MethodChannelPlatformEnvironmentGateway', () {
    const channel = MethodChannel('ccpocket/platform_environment_test');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('reads isIOSAppOnMac from the platform channel', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'isIOSAppOnMac');
            return true;
          });

      final gateway = MethodChannelPlatformEnvironmentGateway(channel);

      expect(await gateway.isIOSAppOnMac(), isTrue);
    });

    test('reads iosUserInterfaceIdiom from the platform channel', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'iosUserInterfaceIdiom');
            return 'pad';
          });

      final gateway = MethodChannelPlatformEnvironmentGateway(channel);

      expect(await gateway.iosUserInterfaceIdiom(), 'pad');
    });

    test('falls back to false when the channel is unavailable', () async {
      final gateway = MethodChannelPlatformEnvironmentGateway(channel);

      expect(await gateway.isIOSAppOnMac(), isFalse);
      expect(await gateway.iosUserInterfaceIdiom(), isNull);
    });

    test('falls back to false on platform errors', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'unavailable');
          });

      final gateway = MethodChannelPlatformEnvironmentGateway(channel);

      expect(await gateway.isIOSAppOnMac(), isFalse);
      expect(await gateway.iosUserInterfaceIdiom(), isNull);
    });
  });
}

class _FakePlatformEnvironmentGateway implements PlatformEnvironmentGateway {
  const _FakePlatformEnvironmentGateway({
    required this.isIOSAppOnMacValue,
    required this.iosUserInterfaceIdiomValue,
  });

  final bool isIOSAppOnMacValue;
  final String? iosUserInterfaceIdiomValue;

  @override
  Future<bool> isIOSAppOnMac() async => isIOSAppOnMacValue;

  @override
  Future<String?> iosUserInterfaceIdiom() async => iosUserInterfaceIdiomValue;
}

import 'package:flutter_test/flutter_test.dart';
import 'package:infra_go/heng/driver_models.dart';

void main() {
  group('driver onboarding validation', () {
    test(
      'normalises Malaysian plate formatting without over-restricting it',
      () {
        expect(
          DriverOnboardingValidator.normalisePlate('v aa-1234'),
          'VAA1234',
        );
        expect(DriverOnboardingValidator.plate('W1'), isNotNull);
        expect(DriverOnboardingValidator.plate('PUTRAJAYA1'), isNull);
        expect(DriverOnboardingValidator.plate('ABC#123'), isNotNull);
      },
    );

    test('capacity is limited to one through six passengers', () {
      expect(DriverOnboardingValidator.capacity(1), isNull);
      expect(DriverOnboardingValidator.capacity(6), isNull);
      expect(DriverOnboardingValidator.capacity(0), isNotNull);
      expect(DriverOnboardingValidator.capacity(7), isNotNull);
    });

    test('document must be a small supported image', () {
      expect(
        DriverOnboardingValidator.isSupportedImage(
          name: 'licence.jpg',
          bytes: 1000,
        ),
        isTrue,
      );
      expect(
        DriverOnboardingValidator.isSupportedImage(
          name: 'licence.pdf',
          bytes: 1000,
        ),
        isFalse,
      );
      expect(
        DriverOnboardingValidator.isSupportedImage(
          name: 'selfie.png',
          bytes: 6 * 1024 * 1024,
        ),
        isFalse,
      );
    });
  });
}

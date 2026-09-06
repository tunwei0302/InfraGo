import 'package:flutter_test/flutter_test.dart';

import 'package:infra_go/foo/fare_estimator.dart';

void main() {
  group('economyFare', () {
    test('applies RM5 minimum for a very short trip', () {
      final fare = FareEstimator.economyFare(
        distanceMeters: 200,
        durationSeconds: 60,
      );
      expect(fare, 5.0);
    });

    test('uses the raw formula once it exceeds the minimum', () {
      final fare = FareEstimator.economyFare(
        distanceMeters: 10000,
        durationSeconds: 20 * 60,
      );
      expect(fare, closeTo(3 + 1.10 * 10 + 0.20 * 20, 1e-9));
    });

    test('rejects negative distance or duration', () {
      expect(
        () =>
            FareEstimator.economyFare(distanceMeters: -1, durationSeconds: 60),
        throwsArgumentError,
      );
      expect(
        () => FareEstimator.economyFare(
          distanceMeters: 1000,
          durationSeconds: -1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('quote', () {
    const distanceMeters = 10000.0;
    const durationSeconds = 20 * 60.0;

    test('economy_4 charges the base economy amount with multiplier 1.0', () {
      final quote = FareEstimator.quote(
        serviceType: FareServiceType.economy4,
        distanceMeters: distanceMeters,
        durationSeconds: durationSeconds,
      );
      expect(quote.vehicleMultiplier, 1.0);
      expect(quote.amount, quote.baseAmount);
      expect(quote.soloAmount, quote.amount);
      expect(quote.sharedAmount, isNull);
    });

    test('six_seater applies the 1.35x multiplier', () {
      final quote = FareEstimator.quote(
        serviceType: FareServiceType.sixSeater,
        distanceMeters: distanceMeters,
        durationSeconds: durationSeconds,
      );
      expect(quote.vehicleMultiplier, 1.35);
      expect(quote.amount, closeTo(quote.baseAmount * 1.35, 0.01));
      expect(quote.sharedAmount, isNull);
    });

    test(
      'shared_economy discounts by 0.75x and still reports the solo fare',
      () {
        final quote = FareEstimator.quote(
          serviceType: FareServiceType.sharedEconomy,
          distanceMeters: distanceMeters,
          durationSeconds: durationSeconds,
        );
        expect(quote.vehicleMultiplier, 0.75);
        expect(quote.amount, closeTo(quote.baseAmount * 0.75, 0.01));
        expect(quote.soloAmount, quote.baseAmount);
        expect(quote.sharedAmount, quote.amount);
      },
    );

    test(
      'rounds only the final money values, not distance/duration inputs',
      () {
        final quote = FareEstimator.quote(
          serviceType: FareServiceType.sixSeater,
          distanceMeters: 10333,
          durationSeconds: 777,
        );
        expect(quote.distanceMeters, 10333);
        expect(quote.durationSeconds, 777);
        final decimals = (quote.amount * 100).round() / 100;
        expect(quote.amount, decimals);
      },
    );

    test('records formula version, currency and quoted time', () {
      final now = DateTime.utc(2026, 8, 29, 10, 0, 0);
      final quote = FareEstimator.quote(
        serviceType: FareServiceType.economy4,
        distanceMeters: distanceMeters,
        durationSeconds: durationSeconds,
        quotedAt: now,
      );
      expect(quote.formulaVersion, 'mvp_v1');
      expect(quote.currency, 'MYR');
      expect(quote.quotedAt, now);
    });

    test(
      'a shared_economy quote below the minimum still floors at RM5 before discount',
      () {
        final quote = FareEstimator.quote(
          serviceType: FareServiceType.sharedEconomy,
          distanceMeters: 100,
          durationSeconds: 30,
        );
        expect(quote.baseAmount, 5.0);
        expect(quote.amount, 3.75);
      },
    );
  });

  group('quoteAllServices', () {
    test(
      'returns one quote per service type sharing the same route inputs',
      () {
        final quotes = FareEstimator.quoteAllServices(
          distanceMeters: 5000,
          durationSeconds: 600,
        );
        expect(
          quotes.map((q) => q.serviceType).toSet(),
          FareServiceType.values.toSet(),
        );
        for (final quote in quotes) {
          expect(quote.distanceMeters, 5000);
          expect(quote.durationSeconds, 600);
        }
      },
    );
  });

  group('FareServiceType.fromDbValue', () {
    test('round-trips each contract string', () {
      for (final type in FareServiceType.values) {
        expect(FareServiceType.fromDbValue(type.dbValue), type);
      }
    });

    test('rejects an unknown service_type', () {
      expect(() => FareServiceType.fromDbValue('suv'), throwsArgumentError);
    });
  });
}

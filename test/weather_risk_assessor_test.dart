import 'package:flutter_test/flutter_test.dart';

import 'package:infra_go/weather/route_weather_service.dart';

WeatherSnapshot _snapshot({
  double precipitation = 0,
  double wind = 0,
  String condition = 'Clear',
}) => WeatherSnapshot(
  precipitationMmPerHour: precipitation,
  windSpeedKph: wind,
  condition: condition,
  fetchedAt: DateTime(2026, 9, 2, 12),
);

void main() {
  group('WeatherRiskAssessor.classify', () {
    test('no rain and calm wind is none', () {
      expect(WeatherRiskAssessor.classify(_snapshot()), RouteRiskLevel.none);
    });

    test('light rain below caution threshold is none', () {
      expect(
        WeatherRiskAssessor.classify(_snapshot(precipitation: 4.9)),
        RouteRiskLevel.none,
      );
    });

    test('rain at or above caution threshold is caution', () {
      expect(
        WeatherRiskAssessor.classify(_snapshot(precipitation: 5.0)),
        RouteRiskLevel.caution,
      );
      expect(
        WeatherRiskAssessor.classify(_snapshot(precipitation: 19.9)),
        RouteRiskLevel.caution,
      );
    });

    test('rain at or above high threshold is high', () {
      expect(
        WeatherRiskAssessor.classify(_snapshot(precipitation: 20.0)),
        RouteRiskLevel.high,
      );
      expect(
        WeatherRiskAssessor.classify(_snapshot(precipitation: 55.0)),
        RouteRiskLevel.high,
      );
    });

    test('strong wind alone raises caution even with no rain', () {
      expect(
        WeatherRiskAssessor.classify(_snapshot(wind: 50.0)),
        RouteRiskLevel.caution,
      );
    });

    test('strong wind never escalates to high on its own', () {
      expect(
        WeatherRiskAssessor.classify(_snapshot(wind: 120.0)),
        RouteRiskLevel.caution,
      );
    });
  });

  group('WeatherRiskAssessor.messageFor', () {
    test('includes the leg label at every risk level', () {
      for (final risk in RouteRiskLevel.values) {
        expect(
          WeatherRiskAssessor.messageFor(risk, 'Setapak'),
          contains('Setapak'),
        );
      }
    });

    test('high risk message mentions flooding', () {
      expect(
        WeatherRiskAssessor.messageFor(RouteRiskLevel.high, 'Setapak'),
        contains('flooding'),
      );
    });
  });

  group('WeatherRiskAssessor.assess', () {
    test('bundles the classified risk and message with the snapshot', () {
      final snapshot = _snapshot(precipitation: 25.0);
      final leg = WeatherRiskAssessor.assess(
        label: 'Wangsa Maju',
        snapshot: snapshot,
      );
      expect(leg.risk, RouteRiskLevel.high);
      expect(leg.snapshot, snapshot);
      expect(leg.message, contains('Wangsa Maju'));
    });
  });

  group('RouteWeatherAdvisory', () {
    test('overallRisk is the worst of its legs', () {
      final advisory = RouteWeatherAdvisory(
        legs: [
          WeatherRiskAssessor.assess(
            label: 'pickup',
            snapshot: _snapshot(precipitation: 1),
          ),
          WeatherRiskAssessor.assess(
            label: 'destination',
            snapshot: _snapshot(precipitation: 25),
          ),
        ],
      );
      expect(advisory.overallRisk, RouteRiskLevel.high);
    });

    test(
      'mostSevereLeg picks the highest-risk leg, preferring high over caution',
      () {
        final cautionLeg = WeatherRiskAssessor.assess(
          label: 'pickup',
          snapshot: _snapshot(precipitation: 6),
        );
        final highLeg = WeatherRiskAssessor.assess(
          label: 'destination',
          snapshot: _snapshot(precipitation: 25),
        );
        final advisory = RouteWeatherAdvisory(legs: [cautionLeg, highLeg]);
        expect(advisory.mostSevereLeg, highLeg);
      },
    );

    test('mostSevereLeg is null when every leg is risk-free', () {
      final advisory = RouteWeatherAdvisory(
        legs: [
          WeatherRiskAssessor.assess(label: 'pickup', snapshot: _snapshot()),
          WeatherRiskAssessor.assess(
            label: 'destination',
            snapshot: _snapshot(),
          ),
        ],
      );
      expect(advisory.mostSevereLeg, isNull);
      expect(advisory.overallRisk, RouteRiskLevel.none);
    });
  });

  group('conditionLabelForWmoCode', () {
    test('maps common codes to expected labels', () {
      expect(conditionLabelForWmoCode(0), 'Clear');
      expect(conditionLabelForWmoCode(2), 'Partly cloudy');
      expect(conditionLabelForWmoCode(45), 'Fog');
      expect(conditionLabelForWmoCode(63), 'Rain');
      expect(conditionLabelForWmoCode(81), 'Rain showers');
      expect(conditionLabelForWmoCode(95), 'Thunderstorm');
    });
  });
}

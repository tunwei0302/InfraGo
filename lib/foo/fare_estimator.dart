enum FareServiceType {
  economy4('economy_4'),
  sixSeater('six_seater'),
  sharedEconomy('shared_economy');

  const FareServiceType(this.dbValue);

  final String dbValue;

  static FareServiceType fromDbValue(String value) => FareServiceType.values
      .firstWhere((type) => type.dbValue == value, orElse: () {
    throw ArgumentError.value(value, 'value', 'unknown service_type');
  });
}

class FareQuote {
  const FareQuote({
    required this.formulaVersion,
    required this.serviceType,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.baseAmount,
    required this.vehicleMultiplier,
    required this.amount,
    required this.soloAmount,
    required this.sharedAmount,
    required this.currency,
    required this.quotedAt,
  });

  final String formulaVersion;
  final FareServiceType serviceType;
  final double distanceMeters;
  final double durationSeconds;
  final double baseAmount;
  final double vehicleMultiplier;
  final double amount;
  final double soloAmount;
  final double? sharedAmount;
  final String currency;
  final DateTime quotedAt;
}

class FareEstimator {
  const FareEstimator._();

  static const String formulaVersion = 'mvp_v1';
  static const String currency = 'MYR';

  static const double _baseFare = 3.0;
  static const double _perKm = 1.10;
  static const double _perMinute = 0.20;
  static const double _minimumFare = 5.0;
  static const double sixSeaterMultiplier = 1.35;
  static const double sharedMultiplier = 0.75;

  static double _multiplierFor(FareServiceType serviceType) {
    switch (serviceType) {
      case FareServiceType.economy4:
        return 1.0;
      case FareServiceType.sixSeater:
        return sixSeaterMultiplier;
      case FareServiceType.sharedEconomy:
        return sharedMultiplier;
    }
  }

  static double economyFare({
    required double distanceMeters,
    required double durationSeconds,
  }) {
    if (distanceMeters < 0 || durationSeconds < 0) {
      throw ArgumentError('distanceMeters and durationSeconds must not be negative');
    }
    final km = distanceMeters / 1000;
    final minutes = durationSeconds / 60;
    final raw = _baseFare + _perKm * km + _perMinute * minutes;
    return raw < _minimumFare ? _minimumFare : raw;
  }

  static FareQuote quote({
    required FareServiceType serviceType,
    required double distanceMeters,
    required double durationSeconds,
    DateTime? quotedAt,
  }) {
    final economy = economyFare(
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
    );
    final multiplier = _multiplierFor(serviceType);
    final amount = _roundMoney(economy * multiplier);
    final soloAmount = _roundMoney(economy);
    final sharedAmount = serviceType == FareServiceType.sharedEconomy
        ? _roundMoney(economy * sharedMultiplier)
        : null;

    return FareQuote(
      formulaVersion: formulaVersion,
      serviceType: serviceType,
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
      baseAmount: _roundMoney(economy),
      vehicleMultiplier: multiplier,
      amount: amount,
      soloAmount: soloAmount,
      sharedAmount: sharedAmount,
      currency: currency,
      quotedAt: quotedAt ?? DateTime.now().toUtc(),
    );
  }

  static List<FareQuote> quoteAllServices({
    required double distanceMeters,
    required double durationSeconds,
    DateTime? quotedAt,
  }) {
    return FareServiceType.values
        .map((type) => quote(
              serviceType: type,
              distanceMeters: distanceMeters,
              durationSeconds: durationSeconds,
              quotedAt: quotedAt,
            ))
        .toList();
  }

  static double _roundMoney(double value) => (value * 100).round() / 100;
}

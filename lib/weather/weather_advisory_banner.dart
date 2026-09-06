import 'package:flutter/material.dart';

import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/weather/route_weather_service.dart';

class WeatherAdvisoryBanner extends StatelessWidget {
  const WeatherAdvisoryBanner({super.key, this.advisory});

  final RouteWeatherAdvisory? advisory;

  @override
  Widget build(BuildContext context) {
    final leg = advisory?.mostSevereLeg;
    if (leg == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final isHigh = leg.risk == RouteRiskLevel.high;
    final background = isHigh
        ? scheme.errorContainer
        : scheme.tertiaryContainer;
    final foreground = isHigh
        ? scheme.onErrorContainer
        : scheme.onTertiaryContainer;

    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.standard),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isHigh ? Icons.warning_amber_rounded : Icons.water_drop_outlined,
            color: foreground,
            size: 18,
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              leg.message,
              style: TextStyle(color: foreground, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

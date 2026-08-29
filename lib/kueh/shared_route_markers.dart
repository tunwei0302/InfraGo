import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/kueh/carpool_matcher.dart';
import 'package:infra_go/kueh/location_search_service.dart';

class RiderMarkerSet {
  const RiderMarkerSet({
    required this.riderIndex,
    required this.pickup,
    this.pickupPlace,
    required this.destination,
    this.destinationPlace,
    this.isMe = false,
  });

  final int riderIndex;
  final LatLng pickup;
  final GeoPlace? pickupPlace;
  final LatLng destination;
  final GeoPlace? destinationPlace;
  final bool isMe;
}

class SharedRouteMarkers {
  static List<Marker> buildForRider({
    required RiderMarkerSet me,
    RiderMarkerSet? partner,
    CarpoolMatch? match,
  }) {
    final markers = <Marker>[_buildMePickup(me), _buildMeDestination(me)];
    if (partner != null) {
      markers.add(_buildPartnerPickup(partner));
      markers.add(_buildPartnerDestination(partner));
    }
    return markers;
  }

  static Marker _buildMePickup(RiderMarkerSet me) => Marker(
    point: me.pickup,
    width: 60,
    height: 60,
    alignment: Alignment.bottomCenter,
    child: Semantics(
      label: 'My pickup point',
      child: Stack(
        alignment: Alignment.bottomCenter,
        clipBehavior: Clip.none,
        children: [
          Positioned(
            bottom: 0,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFF1DB173),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Icons.trip_origin,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
          Positioned(
            top: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF1DB173),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: const Text(
                'ME · Pickup',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  static Marker _buildMeDestination(RiderMarkerSet me) => Marker(
    point: me.destination,
    width: 60,
    height: 60,
    alignment: Alignment.bottomCenter,
    child: Semantics(
      label: 'My destination',
      child: Stack(
        alignment: Alignment.bottomCenter,
        clipBehavior: Clip.none,
        children: [
          Positioned(
            bottom: 0,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFFBA1A1A),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Icons.location_pin,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
          Positioned(
            top: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFBA1A1A),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: const Text(
                'ME · Drop-off',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  static Marker _buildPartnerPickup(RiderMarkerSet partner) => Marker(
    point: partner.pickup,
    width: 52,
    height: 52,
    alignment: Alignment.bottomCenter,
    child: Semantics(
      label: 'Shared rider pickup',
      child: Stack(
        alignment: Alignment.bottomCenter,
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFF705D00),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: const Icon(
              Icons.people_outline,
              color: Colors.white,
              size: 18,
            ),
          ),
          Positioned(
            top: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFFCD400),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: Text(
                'R${partner.riderIndex + 1} · Pickup',
                style: const TextStyle(
                  color: Color(0xFF705D00),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  static Marker _buildPartnerDestination(RiderMarkerSet partner) => Marker(
    point: partner.destination,
    width: 52,
    height: 52,
    alignment: Alignment.bottomCenter,
    child: Semantics(
      label: 'Shared rider destination',
      child: Stack(
        alignment: Alignment.bottomCenter,
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFF544600),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: const Icon(
              Icons.flag_outlined,
              color: Colors.white,
              size: 18,
            ),
          ),
          Positioned(
            top: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF544600),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: Text(
                'R${partner.riderIndex + 1} · Drop-off',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  static Widget buildMatchBottomSheet({
    required BuildContext context,
    required CarpoolMatch match,
    required int myRiderIndex,
    required VoidCallback onAccept,
    required VoidCallback onDismiss,
  }) {
    final score = match.score;
    final partnerIndex = myRiderIndex == 0 ? 1 : 0;
    final partnerDetour = match.riderDetourPercent[partnerIndex] ?? 0;
    final myDetour = match.riderDetourPercent[myRiderIndex] ?? 0;
    final soloA = match.bestRoute.riderDetourPercent[0] ?? 0;
    final soloB = match.bestRoute.riderDetourPercent[1] ?? 0;
    final savedKm =
        ((soloA + soloB) * match.bestRoute.totalDistanceMeters / 100 / 1000)
            .toStringAsFixed(1);

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.lg),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.base,
          AppSpacing.gutter,
          AppSpacing.gutter,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Text(
                  'Shared match found',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: score >= 80
                        ? Theme.of(context).colorScheme.tertiaryContainer
                        : Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.standard),
                  ),
                  child: Text(
                    'Score $score/100',
                    style: TextStyle(
                      fontFamily: 'JetBrains Mono',
                      fontWeight: FontWeight.w600,
                      color: score >= 80
                          ? Theme.of(context).colorScheme.onTertiaryContainer
                          : Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Column(
                  children: [
                    _ScoreRow(
                      icon: Icons.route,
                      label: 'My detour',
                      value: '${myDetour.toStringAsFixed(1)}%',
                      ok: myDetour <= 25,
                    ),
                    const SizedBox(height: AppSpacing.base),
                    _ScoreRow(
                      icon: Icons.people_alt_outlined,
                      label: 'Partner detour',
                      value: '${partnerDetour.toStringAsFixed(1)}%',
                      ok: partnerDetour <= 25,
                    ),
                    const SizedBox(height: AppSpacing.base),
                    _ScoreRow(
                      icon: Icons.eco_outlined,
                      label: 'Vehicle-km avoided',
                      value: '~$savedKm km',
                      ok: true,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text('Why this match works', style: AppTextStyles.labelCaps),
            const SizedBox(height: AppSpacing.xs),
            ...match.reasons.map(
              (r) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 3),
                      child: Icon(
                        Icons.check_circle,
                        size: 14,
                        color: Color(0xFF1DB173),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        r,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onDismiss,
                    child: const Text('Ride solo instead'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: onAccept,
                    icon: const Icon(Icons.people_alt_outlined, size: 18),
                    label: const Text('Share ride'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ScoreRow extends StatelessWidget {
  const _ScoreRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.ok,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(label)),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: ok
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.error,
          ),
        ),
      ],
    );
  }
}

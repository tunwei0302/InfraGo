import 'package:flutter/material.dart';

import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/kueh/location_search_service.dart';
import 'package:infra_go/kueh/trip_planner_state.dart';

class PickupConfirmationResult {
  const PickupConfirmationResult({this.pickupNote});

  final String? pickupNote;
}

class PickupConfirmationSheet extends StatefulWidget {
  const PickupConfirmationSheet({
    super.key,
    required this.pickup,
    required this.destination,
    required this.vehicle,
    required this.route,
    required this.pickupNote,
    required this.onNoteChanged,
    required this.onConfirm,
    required this.passengerCount,
    this.scheduledDeparture,
    this.transitStopName,
    this.isSubmitting = false,
    this.errorMessage,
  });

  final GeoPlace pickup;
  final GeoPlace destination;
  final VehicleOption vehicle;
  final TripPlanRoute route;
  final String? pickupNote;
  final ValueChanged<String?> onNoteChanged;
  final VoidCallback onConfirm;
  final int passengerCount;
  final DateTime? scheduledDeparture;
  final String? transitStopName;
  final bool isSubmitting;
  final String? errorMessage;

  static Future<PickupConfirmationResult?> show(
    BuildContext context, {
    required GeoPlace pickup,
    required GeoPlace destination,
    required VehicleOption vehicle,
    required TripPlanRoute route,
    required int passengerCount,
    DateTime? scheduledDeparture,
    String? transitStopName,
  }) async {
    final noteController = TextEditingController();
    final error = ValueNotifier<String?>(null);
    final submitting = ValueNotifier<bool>(false);
    final confirmed = await showModalBottomSheet<PickupConfirmationResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.gutter,
          right: AppSpacing.gutter,
          top: AppSpacing.gutter,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.gutter,
        ),
        child: StatefulBuilder(
          builder: (context, setSheetState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.62,
              minChildSize: 0.45,
              maxChildSize: 0.9,
              expand: false,
              builder: (context, scroll) => Container(
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
                      const SizedBox(height: AppSpacing.base),
                      Text(
                        'Confirm pickup',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: AppSpacing.gutter),
                      Expanded(
                        child: ListView(
                          controller: scroll,
                          children: [
                            _PlaceRow(
                              icon: Icons.trip_origin,
                              color: const Color(0xFF1DB173),
                              label: 'Pickup',
                              title: pickup.name,
                              subtitle: pickup.subtitle,
                            ),
                            const Padding(
                              padding: EdgeInsets.only(left: 11),
                              child: SizedBox(
                                height: 28,
                                child: VerticalDivider(width: 2, thickness: 2),
                              ),
                            ),
                            _PlaceRow(
                              icon: Icons.location_pin,
                              color: Theme.of(context).colorScheme.error,
                              label: 'Destination',
                              title: destination.name,
                              subtitle: destination.subtitle,
                            ),
                            const SizedBox(height: AppSpacing.md),
                            _TripSummaryCard(
                              vehicle: vehicle,
                              route: route,
                              passengerCount: passengerCount,
                              scheduledDeparture: scheduledDeparture,
                              transitStopName: transitStopName,
                            ),
                            const SizedBox(height: AppSpacing.md),
                            Text(
                              'Pickup note / landmark',
                              style: AppTextStyles.labelCaps,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            TextField(
                              controller: noteController,
                              decoration: const InputDecoration(
                                hintText: 'e.g. blue bench, by the LRT exit',
                              ),
                              maxLength: 80,
                            ),
                            if (error.value != null) ...[
                              const SizedBox(height: AppSpacing.sm),
                              Text(
                                error.value!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ],
                            const SizedBox(height: AppSpacing.md),
                            Text(
                              'You can cancel for free while searching. '
                              'After assignment, the first 3 minutes are free; '
                              'a cancellation fee may apply after that.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.base),
                      SafeArea(
                        top: false,
                        child: ElevatedButton.icon(
                          onPressed: submitting.value
                              ? null
                              : () async {
                                  submitting.value = true;
                                  error.value = null;
                                  final note = noteController.text.trim();
                                  Navigator.of(context).pop(
                                    PickupConfirmationResult(
                                      pickupNote: note.isEmpty ? null : note,
                                    ),
                                  );
                                },
                          icon: submitting.value
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.local_taxi),
                          label: Text(
                            submitting.value
                                ? 'Submitting…'
                                : 'Confirm and find a driver',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    noteController.dispose();
    return confirmed;
  }

  @override
  State<PickupConfirmationSheet> createState() =>
      _PickupConfirmationSheetState();
}

class _PickupConfirmationSheetState extends State<PickupConfirmationSheet> {
  late final TextEditingController _noteController;

  @override
  void initState() {
    super.initState();
    _noteController = TextEditingController(text: widget.pickupNote);
    _noteController.addListener(() {
      final v = _noteController.text.trim();
      widget.onNoteChanged(v.isEmpty ? null : v);
    });
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

class _PlaceRow extends StatelessWidget {
  const _PlaceRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.title,
    this.subtitle,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: AppTextStyles.labelCaps),
              const SizedBox(height: AppSpacing.xs),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

class _TripSummaryCard extends StatelessWidget {
  const _TripSummaryCard({
    required this.vehicle,
    required this.route,
    required this.passengerCount,
    this.scheduledDeparture,
    this.transitStopName,
  });

  final VehicleOption vehicle;
  final TripPlanRoute route;
  final int passengerCount;
  final DateTime? scheduledDeparture;
  final String? transitStopName;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  vehicle.isShared
                      ? Icons.people_alt_outlined
                      : Icons.local_taxi,
                  size: 28,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        vehicle.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '${vehicle.fareLabel} · $passengerCount passenger${passengerCount == 1 ? '' : 's'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (scheduledDeparture != null) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          'Scheduled ${MaterialLocalizations.of(context).formatMediumDate(scheduledDeparture!)} '
                          '${TimeOfDay.fromDateTime(scheduledDeparture!).format(context)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      if (transitStopName != null) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Row(
                          children: [
                            const Icon(Icons.directions_transit, size: 16),
                            const SizedBox(width: AppSpacing.xs),
                            Expanded(
                              child: Text(
                                'Transit connection: $transitStopName',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.base),
            const Divider(height: 1),
            const SizedBox(height: AppSpacing.base),
            Row(
              children: [
                Expanded(
                  child: _SummaryCell(
                    icon: Icons.route,
                    title: route.distanceText,
                    subtitle: 'Route distance',
                  ),
                ),
                Container(
                  width: 1,
                  height: 40,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                Expanded(
                  child: _SummaryCell(
                    icon: Icons.schedule,
                    title: route.etaText,
                    subtitle: 'Trip ETA',
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

class _SummaryCell extends StatelessWidget {
  const _SummaryCell({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: AppSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }
}

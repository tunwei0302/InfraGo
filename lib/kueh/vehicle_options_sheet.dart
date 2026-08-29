import 'package:flutter/material.dart';

import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/kueh/trip_planner_state.dart';

class RideSelection {
  const RideSelection({
    required this.vehicle,
    required this.passengerCount,
    this.scheduledDeparture,
  });

  final VehicleOption vehicle;
  final int passengerCount;
  final DateTime? scheduledDeparture;
}

class VehicleOptionsSheet extends StatelessWidget {
  const VehicleOptionsSheet({
    super.key,
    required this.options,
    required this.selectedId,
    required this.onSelect,
    required this.onContinue,
    required this.passengerCount,
    required this.scheduledDeparture,
    required this.onPassengerCountChanged,
    required this.onScheduleChanged,
    this.routeSummary,
  });

  final List<VehicleOption> options;
  final String? selectedId;
  final ValueChanged<VehicleOption> onSelect;
  final VoidCallback onContinue;
  final int passengerCount;
  final DateTime? scheduledDeparture;
  final ValueChanged<int> onPassengerCountChanged;
  final ValueChanged<DateTime?> onScheduleChanged;
  final String? routeSummary;

  static Future<RideSelection?> show(
    BuildContext context, {
    required List<VehicleOption> options,
    String? selectedId,
    String? routeSummary,
  }) {
    var currentId = selectedId ?? options.first.id;
    var currentPassengerCount = 1;
    DateTime? scheduledDeparture;
    return showModalBottomSheet<RideSelection>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          final selected = options.firstWhere((o) => o.id == currentId);
          final maxPassengers = selected.isShared ? 2 : selected.seats;
          currentPassengerCount = currentPassengerCount.clamp(1, maxPassengers);

          Future<void> chooseSchedule() async {
            final now = DateTime.now();
            final date = await showDatePicker(
              context: context,
              initialDate:
                  scheduledDeparture ?? now.add(const Duration(days: 1)),
              firstDate: now,
              lastDate: now.add(const Duration(days: 7)),
            );
            if (date == null || !context.mounted) return;
            final time = await showTimePicker(
              context: context,
              initialTime: TimeOfDay.fromDateTime(
                scheduledDeparture ?? now.add(const Duration(minutes: 30)),
              ),
            );
            if (time == null) return;
            var value = DateTime(
              date.year,
              date.month,
              date.day,
              time.hour,
              time.minute,
            );
            final minimum = DateTime.now().add(const Duration(minutes: 16));
            if (value.isBefore(minimum)) value = minimum;
            setModalState(() => scheduledDeparture = value);
          }

          return DraggableScrollableSheet(
            initialChildSize: 0.78,
            minChildSize: 0.4,
            maxChildSize: 0.88,
            expand: false,
            builder: (context, scroll) => Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppRadius.lg),
                ),
              ),
              child: VehicleOptionsSheet(
                options: options,
                selectedId: currentId,
                routeSummary: routeSummary,
                passengerCount: currentPassengerCount,
                scheduledDeparture: scheduledDeparture,
                onPassengerCountChanged: (value) =>
                    setModalState(() => currentPassengerCount = value),
                onScheduleChanged: (value) {
                  if (value == null) {
                    setModalState(() => scheduledDeparture = null);
                  } else {
                    chooseSchedule();
                  }
                },
                onSelect: (o) => setModalState(() {
                  currentId = o.id;
                  final maximum = o.isShared ? 2 : o.seats;
                  currentPassengerCount = currentPassengerCount.clamp(
                    1,
                    maximum,
                  );
                }),
                onContinue: () => Navigator.of(context).pop(
                  RideSelection(
                    vehicle: selected,
                    passengerCount: currentPassengerCount,
                    scheduledDeparture: scheduledDeparture,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
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
          Row(
            children: [
              Text(
                'Choose a ride',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              if (routeSummary != null)
                Text(
                  routeSummary!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          const Text(
            'Prices are estimates provided by pricing service.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('Passengers', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            children: List.generate(
              (options.firstWhere((o) => o.id == selectedId).isShared
                  ? 2
                  : options.firstWhere((o) => o.id == selectedId).seats),
              (index) {
                final count = index + 1;
                return ChoiceChip(
                  label: Text('$count'),
                  selected: passengerCount == count,
                  onSelected: (_) => onPassengerCountChanged(count),
                );
              },
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('Departure', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                label: Text('Now'),
                icon: Icon(Icons.bolt),
              ),
              ButtonSegment(
                value: true,
                label: Text('Schedule'),
                icon: Icon(Icons.schedule),
              ),
            ],
            selected: {scheduledDeparture != null},
            onSelectionChanged: (values) =>
                onScheduleChanged(values.first ? DateTime.now() : null),
          ),
          if (scheduledDeparture != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Scheduled: ${MaterialLocalizations.of(context).formatMediumDate(scheduledDeparture!)} '
              '${TimeOfDay.fromDateTime(scheduledDeparture!).format(context)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: ListView.separated(
              itemCount: options.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (context, index) {
                final option = options[index];
                final isSelected = option.id == selectedId;
                return Material(
                  color: isSelected
                      ? Theme.of(context).colorScheme.secondaryContainer
                      : Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(AppRadius.standard),
                  child: InkWell(
                    onTap: () => onSelect(option),
                    borderRadius: BorderRadius.circular(AppRadius.standard),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      child: Row(
                        children: [
                          Icon(
                            option.isShared
                                ? Icons.people_alt_outlined
                                : Icons.local_taxi,
                            size: 32,
                            color: isSelected
                                ? Theme.of(
                                    context,
                                  ).colorScheme.onSecondaryContainer
                                : Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      option.name,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                    const SizedBox(width: AppSpacing.xs),
                                    if (option.isShared)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.tertiaryContainer,
                                          borderRadius: BorderRadius.circular(
                                            AppRadius.sm,
                                          ),
                                        ),
                                        child: Text(
                                          'Shared',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onTertiaryContainer,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: AppSpacing.xs),
                                Text(
                                  'Up to ${option.seats} seats · Live availability',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                option.fareLabel,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              if (isSelected)
                                Icon(
                                  Icons.check_circle,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSecondaryContainer,
                                  size: 18,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: AppSpacing.base),
          SafeArea(
            top: false,
            child: ElevatedButton(
              onPressed: selectedId == null ? null : onContinue,
              child: Text(selectedId == null ? 'Select a vehicle' : 'Continue'),
            ),
          ),
        ],
      ),
    );
  }
}

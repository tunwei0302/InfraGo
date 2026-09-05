import 'package:flutter/material.dart';

import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/kueh/trip_planner_state.dart';

class DriverAssignedPanel extends StatelessWidget {
  const DriverAssignedPanel({
    super.key,
    required this.driver,
    required this.phase,
    required this.cancelCountdownSeconds,
    required this.canCancelForFree,
    this.sharedMatchFound = false,
    this.onContactDriver,
    this.onCancelRide,
    this.onTrackDriver,
  });

  final AssignedDriverInfo driver;
  final TripPlannerPhase phase;
  final int cancelCountdownSeconds;
  final bool canCancelForFree;
  final bool sharedMatchFound;
  final VoidCallback? onContactDriver;
  final VoidCallback? onCancelRide;
  final VoidCallback? onTrackDriver;

  @override
  Widget build(BuildContext context) {
    final isSearching = phase == TripPlannerPhase.searchingDriver;
    final isAssigned = phase == TripPlannerPhase.driverAssigned;
    final isEnRoute = phase == TripPlannerPhase.enRoute;

    if (isSearching) {
      return _SearchingCard(
        canCancelForFree: canCancelForFree,
        sharedMatchFound: sharedMatchFound,
        onCancel: onCancelRide,
      );
    }
    if (isAssigned) {
      return _AssignedCard(
        driver: driver,
        cancelCountdownSeconds: cancelCountdownSeconds,
        canCancelForFree: canCancelForFree,
        onContact: onContactDriver,
        onCancel: onCancelRide,
        onTrack: onTrackDriver,
      );
    }
    if (isEnRoute) {
      return _EnRouteCard(driver: driver, onContact: onContactDriver);
    }
    return const SizedBox.shrink();
  }
}

class _SearchingCard extends StatelessWidget {
  const _SearchingCard({
    required this.canCancelForFree,
    required this.sharedMatchFound,
    this.onCancel,
  });

  final bool canCancelForFree;
  final bool sharedMatchFound;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.lg),
          ),
          boxShadow: const [
            BoxShadow(
              blurRadius: 12,
              color: Colors.black12,
              offset: Offset(0, -2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: AppSpacing.base),
                  Expanded(
                    child: Text(
                      sharedMatchFound
                          ? 'Matched — waiting for a driver…'
                          : 'Finding drivers near you…',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.base),
              LinearProgressIndicator(
                minHeight: 4,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHigh,
              ),
              const SizedBox(height: AppSpacing.base),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      canCancelForFree
                          ? sharedMatchFound
                                ? 'Rider match confirmed · cancel free while waiting'
                                : 'Cancel free while searching'
                          : 'Cancellation fees may apply',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onCancel,
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Cancel'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssignedCard extends StatelessWidget {
  const _AssignedCard({
    required this.driver,
    required this.cancelCountdownSeconds,
    required this.canCancelForFree,
    this.onContact,
    this.onCancel,
    this.onTrack,
  });

  final AssignedDriverInfo driver;
  final int cancelCountdownSeconds;
  final bool canCancelForFree;
  final VoidCallback? onContact;
  final VoidCallback? onCancel;
  final VoidCallback? onTrack;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.lg),
          ),
          boxShadow: const [
            BoxShadow(
              blurRadius: 12,
              color: Colors.black12,
              offset: Offset(0, -2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer,
                    child: Icon(
                      Icons.person,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.base),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          driver.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Row(
                          children: [
                            const Icon(
                              Icons.star,
                              size: 14,
                              color: Color(0xFFFCD400),
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            Text(
                              driver.rating.toStringAsFixed(1),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(width: AppSpacing.base),
                            Text(
                              driver.etaLabel,
                              style: AppTextStyles.labelCaps.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(AppRadius.standard),
                    ),
                    child: Text(
                      driver.vehiclePlate,
                      style: TextStyle(
                        fontFamily: 'JetBrains Mono',
                        fontWeight: FontWeight.w600,
                        color: Theme.of(
                          context,
                        ).colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.base),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  child: Row(
                    children: [
                      Icon(
                        Icons.directions_car,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          driver.vehicleSummary,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.base),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onContact,
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      label: const Text('Contact'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: onTrack,
                      icon: const Icon(Icons.navigation, size: 18),
                      label: const Text('Track'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.base),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      canCancelForFree
                          ? 'Cancel free for ${_fmtCountdown(cancelCountdownSeconds)}'
                          : 'Cancellation fee may apply',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: onCancel,
                    child: const Text('Cancel ride'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EnRouteCard extends StatelessWidget {
  const _EnRouteCard({required this.driver, this.onContact});

  final AssignedDriverInfo driver;
  final VoidCallback? onContact;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.lg),
          ),
          boxShadow: const [
            BoxShadow(
              blurRadius: 12,
              color: Colors.black12,
              offset: Offset(0, -2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.navigation,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: AppSpacing.base),
                  Text(
                    'En route to destination',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(AppRadius.standard),
                    ),
                    child: Text(
                      driver.vehiclePlate,
                      style: const TextStyle(
                        fontFamily: 'JetBrains Mono',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.base),
              Text(
                '${driver.name} · ${driver.vehicleSummary}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: AppSpacing.base),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(
                    context,
                  ).colorScheme.onPrimaryContainer,
                  side: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.onPrimaryContainer.withValues(alpha: 0.4),
                  ),
                ),
                onPressed: onContact,
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                label: const Text('Message your driver'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _fmtCountdown(int totalSeconds) {
  if (totalSeconds <= 0) return '0:00';
  final m = totalSeconds ~/ 60;
  final s = totalSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

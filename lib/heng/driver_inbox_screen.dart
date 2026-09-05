import 'package:flutter/material.dart';

import 'package:infra_go/heng/driver_repository.dart';
import 'package:infra_go/kueh/chat_with_driver_screen.dart';
import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/shared/supabase_config.dart';

class DriverInboxScreen extends StatefulWidget {
  const DriverInboxScreen({super.key});

  @override
  State<DriverInboxScreen> createState() => _DriverInboxScreenState();
}

class _DriverInboxScreenState extends State<DriverInboxScreen> {
  final _repository = DriverRepository(supabase);

  Stream<List<Map<String, dynamic>>> _assignedRidesStream() {
    final driverId = supabase.auth.currentUser?.id;
    if (driverId == null) {
      return Stream.value(const []);
    }
    return supabase
        .from('rides')
        .stream(primaryKey: ['id'])
        .eq('driver_id', driverId)
        .order('created_at', ascending: false);
  }

  Future<Map<String, dynamic>?> _latestMessage(String rideId) async {
    try {
      final rows = await supabase
          .from('messages')
          .select()
          .eq('ride_id', rideId)
          .order('created_at', ascending: false)
          .limit(1);
      if (rows.isEmpty) return null;
      return Map<String, dynamic>.from(rows.first);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final driverId = supabase.auth.currentUser?.id;
    if (driverId == null) {
      return const Scaffold(
        appBar: _InboxAppBar(),
        body: _EmptyHint(text: 'Sign in as a driver to open messages.'),
      );
    }
    return Scaffold(
      appBar: const _InboxAppBar(),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _assignedRidesStream(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _EmptyHint(text: 'Could not load inbox: ${snapshot.error}');
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snapshot.data!;
          final active = rows
              .where(
                (r) =>
                    r['status'] == 'driver_assigned' ||
                    r['status'] == 'en_route',
              )
              .toList();
          final closed = rows
              .where(
                (r) =>
                    r['status'] == 'completed' || r['status'] == 'cancelled',
              )
              .take(20)
              .toList();
          if (active.isEmpty && closed.isEmpty) {
            return const _EmptyHint(
              text:
                  'Once you accept a ride, a separate private chat entry '
                  'will appear here for every accepted ride_id.\n'
                  'Shared groups expand into one entry per rider.',
            );
          }
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.marginMobile),
            children: [
              if (active.isNotEmpty) ...[
                Text('Active chats', style: AppTextStyles.labelCaps),
                const SizedBox(height: AppSpacing.xs),
                _TileList(rides: active, loadLatest: _latestMessage),
                const SizedBox(height: AppSpacing.md),
              ],
              if (closed.isNotEmpty) ...[
                Text('Recent closed chats', style: AppTextStyles.labelCaps),
                const SizedBox(height: AppSpacing.xs),
                _TileList(rides: closed, loadLatest: _latestMessage),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _InboxAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _InboxAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: const Text('Messages'),
      actions: [
        IconButton(
          tooltip: 'Inbox policy',
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const _InboxPolicyDialog(),
          ),
          icon: const Icon(Icons.info_outline),
        ),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.marginMobile),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inbox_outlined, size: 52),
          const SizedBox(height: AppSpacing.sm),
          Text(text, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class _TileList extends StatelessWidget {
  const _TileList({
    required this.rides,
    required this.loadLatest,
  });
  final List<Map<String, dynamic>> rides;
  final Future<Map<String, dynamic>?> Function(String rideId) loadLatest;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final ride in rides)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: _RideInboxTile(ride: ride, loadLatest: loadLatest),
          ),
      ],
    );
  }
}

class _RideInboxTile extends StatefulWidget {
  const _RideInboxTile({
    required this.ride,
    required this.loadLatest,
  });
  final Map<String, dynamic> ride;
  final Future<Map<String, dynamic>?> Function(String rideId) loadLatest;

  @override
  State<_RideInboxTile> createState() => _RideInboxTileState();
}

class _RideInboxTileState extends State<_RideInboxTile> {
  late final Future<Map<String, dynamic>?> _latest;

  @override
  void initState() {
    super.initState();
    _latest = widget.loadLatest(widget.ride['id'].toString());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = widget.ride['status']?.toString() ?? 'unknown';
    final isLive =
        status == 'driver_assigned' || status == 'en_route';
    final rideId = widget.ride['id'].toString();
    final shortId = rideId.length > 8
        ? rideId.substring(0, 8)
        : rideId;
    return Material(
      color: isLive
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
          : theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatWithDriverScreen(
              rideId: rideId,
              title: 'Rider chat · $shortId',
              isDriverView: true,
              quickReplies: const [
                'I’m on my way.',
                'I have arrived at the pickup point.',
                'Please meet me at the pickup point.',
                'Traffic delay — I may be about 5 minutes late.',
                'Please confirm the pickup landmark shown in your app.',
              ],
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: isLive
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
                foregroundColor: isLive
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurfaceVariant,
                child: const Icon(Icons.chat_bubble_outline),
              ),
              const SizedBox(width: AppSpacing.gutter),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Ride $shortId',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const Spacer(),
                        _StatusPill(status: status),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '${widget.ride['pickup'] ?? 'Pickup'} → '
                      '${widget.ride['destination'] ?? 'Destination'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    FutureBuilder<Map<String, dynamic>?>(
                      future: _latest,
                      builder: (context, snapshot) {
                        final data = snapshot.data;
                        final msg = data?['message_text']?.toString();
                        final fromDriver =
                            (data?['sender_id']?.toString() ?? '') ==
                                supabase.auth.currentUser?.id;
                        if (msg == null) {
                          return Text(
                            'No messages yet — quick-start from the driver screen.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          );
                        }
                        return Text(
                          '${fromDriver ? 'You: ' : ''}$msg',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});
  final String status;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = switch (status) {
      'driver_assigned' => (
          'Driver assigned',
          theme.colorScheme.primaryContainer,
        ),
      'en_route' => (
          'En route',
          theme.colorScheme.secondaryContainer,
        ),
      'completed' => (
          'Completed',
          theme.colorScheme.tertiaryContainer,
        ),
      'cancelled' => (
          'Cancelled',
          theme.colorScheme.errorContainer,
        ),
      _ => (status, theme.colorScheme.surfaceContainerHighest),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall,
      ),
    );
  }
}

class _InboxPolicyDialog extends StatelessWidget {
  const _InboxPolicyDialog();
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Driver inbox policy'),
    content: const Text(
      '• Every accepted ride_id gets its own, separate private chat entry.\n'
      '• Shared carpool groups expand into one inbox tile per rider — '
      'group riders cannot see each other.\n'
      '• Direct writes are only allowed while the ride is in progress '
      '(driver_assigned or en_route).\n'
      '• After completion/cancellation the chat becomes read-only and '
      'moves to "Recent closed chats".',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Got it'),
      ),
    ],
  );
}

import 'package:flutter/material.dart';

import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/kueh/chat_lifecycle_policy.dart';
import 'package:infra_go/kueh/chat_message.dart';
import 'package:infra_go/kueh/trip_planner_state.dart';
import 'package:infra_go/shared/ride.dart';
import 'package:infra_go/shared/supabase_config.dart';

class ChatWithDriverScreen extends StatefulWidget {
  const ChatWithDriverScreen({
    super.key,
    this.rideId,
    this.title = 'Chat with Driver',
    this.quickReplies = const <String>[],
    this.isDriverView = false,
  });

  final String? rideId;
  final String title;

  /// Optional one-tap messages rendered above the composer (used by the
  /// driver inbox; riders keep the plain composer).
  final List<String> quickReplies;

  /// This page is only opened for a particular assigned ride.  The driver
  /// view changes the contact wording and enables driver status shortcuts.
  final bool isDriverView;

  @override
  State<ChatWithDriverScreen> createState() => _ChatWithDriverScreenState();
}

class _ChatWithDriverScreenState extends State<ChatWithDriverScreen> {
  static const _lifecyclePolicy = ChatLifecyclePolicy();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Ride? _activeRide;
  Map<String, dynamic>? _driverProfile;
  String? _loadError;
  bool _isLoading = true;
  bool _isSending = false;
  Stream<List<Map<String, dynamic>>>? _messagesStream;
  String? _messagesStreamRideId;
  int? _lastRenderedMessageId;

  @override
  void initState() {
    super.initState();
    _loadActiveRide();
  }

  Future<void> _loadActiveRide() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      Ride? ride;
      if (widget.rideId != null) {
        final data = await supabase
            .from('rides')
            .select()
            .eq('id', widget.rideId!)
            .single();
        ride = Ride.fromJson(data);
      } else {
        final userId = supabase.auth.currentUser!.id;
        final data = await supabase
            .from('rides')
            .select()
            .or('rider_id.eq.$userId,driver_id.eq.$userId')
            .inFilter('status', ['driver_assigned', 'en_route'])
            .order('created_at', ascending: false)
            .limit(1);
        if (data.isNotEmpty) {
          ride = Ride.fromJson(data.first);
        }
      }

      Map<String, dynamic>? driverProfile;
      if (ride?.driverId != null) {
        try {
          driverProfile = await supabase
              .from('driver_public_profiles')
              .select(
                'name, vehicle_make, vehicle_model, vehicle_color, '
                'body_type, plate_number, passenger_capacity',
              )
              .eq('driver_id', ride!.driverId!)
              .maybeSingle();
        } catch (_) {
          // Chat remains available even when the optional public header fails.
        }
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _activeRide = ride;
        _driverProfile = driverProfile;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadError = 'Unable to load this chat: $error';
        _isLoading = false;
      });
    }
  }

  Future<void> _sendMessage() async {
    final body = _messageController.text.trim();
    final ride = _activeRide;
    if (body.isEmpty ||
        ride == null ||
        ride.driverId == null ||
        !_lifecyclePolicy.isWritable(phase: _phaseFor(ride)) ||
        _isSending) {
      return;
    }

    setState(() {
      _isSending = true;
    });
    try {
      await supabase.from('messages').insert({
        'ride_id': ride.id,
        'sender_id': supabase.auth.currentUser!.id,
        'body': body,
      });
      _messageController.clear();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Message could not be sent: $error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  Future<void> _sendQuickReply(String text) async {
    if (text.trim().isEmpty || _isSending) return;
    _messageController.text = text;
    await _sendMessage();
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ride = _activeRide;
    final phase = ride == null ? null : _phaseFor(ride);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? _ChatUnavailable(
              icon: Icons.cloud_off,
              message: _loadError!,
              buttonLabel: 'Retry',
              onPressed: _loadActiveRide,
            )
          : ride == null || ride.driverId == null
          ? _ChatUnavailable(
              icon: Icons.forum_outlined,
              message:
                  'Chat becomes available after a driver accepts your ride.',
              buttonLabel: 'Check again',
              onPressed: _loadActiveRide,
            )
          : Column(
              children: [
                _RideContactHeader(
                  ride: ride,
                  isDriverView: widget.isDriverView,
                  driverProfile: _driverProfile,
                ),
                Expanded(child: _buildMessageList(ride)),
                if (phase != null &&
                    _lifecyclePolicy.showQuickMessageBar(phase: phase) &&
                    _quickRepliesFor(phase).isNotEmpty)
                  _QuickReplyBar(
                    replies: _quickRepliesFor(phase),
                    isSending: _isSending,
                    onSend: (text) => _sendQuickReply(text),
                  ),
                if (phase != null && _lifecyclePolicy.isWritable(phase: phase))
                  _MessageComposer(
                    controller: _messageController,
                    isSending: _isSending,
                    onSend: _sendMessage,
                    hintText: widget.isDriverView
                        ? 'Message passenger'
                        : 'Message driver',
                  )
                else
                  const SafeArea(
                    top: false,
                    child: Padding(
                      padding: EdgeInsets.all(AppSpacing.gutter),
                      child: Text(
                        'This conversation is read-only because the ride has ended.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  TripPlannerPhase _phaseFor(Ride ride) =>
      _lifecyclePolicy.phaseForRideStatus(ride.status);

  List<String> _quickRepliesFor(TripPlannerPhase phase) {
    if (widget.quickReplies.isNotEmpty) return widget.quickReplies;
    return _lifecyclePolicy.quickMessagesFor(
      phase: phase,
      role: widget.isDriverView
          ? ChatParticipantRole.driver
          : ChatParticipantRole.rider,
    );
  }

  Stream<List<Map<String, dynamic>>> _messagesStreamFor(String rideId) {
    if (_messagesStream == null || _messagesStreamRideId != rideId) {
      _messagesStreamRideId = rideId;
      _messagesStream = supabase
          .from('messages')
          .stream(primaryKey: ['id'])
          .eq('ride_id', rideId)
          .order('created_at', ascending: true);
    }
    return _messagesStream!;
  }

  Widget _buildMessageList(Ride ride) {
    final currentUserId = supabase.auth.currentUser!.id;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _messagesStreamFor(ride.id),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.marginMobile),
              child: Text('Unable to receive messages: ${snapshot.error}'),
            ),
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final messages = sortChatMessagesOldestFirst(
          (snapshot.data ?? []).map(ChatMessage.fromJson),
        );
        if (messages.isEmpty) {
          return _ChatUnavailable(
            icon: Icons.waving_hand_outlined,
            message: widget.isDriverView
                ? 'No messages yet. Send the passenger a trip update.'
                : 'No messages yet. Send your driver a quick update.',
          );
        }

        final newestId = messages.last.id;
        if (_lastRenderedMessageId != newestId) {
          _lastRenderedMessageId = newestId;
          _scrollToLatest();
        }
        return ListView.separated(
          controller: _scrollController,
          reverse: false,
          padding: const EdgeInsets.all(AppSpacing.marginMobile),
          itemCount: messages.length,
          separatorBuilder: (context, index) =>
              const SizedBox(height: AppSpacing.base),
          itemBuilder: (context, index) {
            final message = messages[index];
            return _MessageBubble(
              message: message,
              isMine: message.senderId == currentUserId,
              peerLabel: widget.isDriverView ? 'Passenger' : 'Driver',
            );
          },
        );
      },
    );
  }
}

class _RideContactHeader extends StatelessWidget {
  const _RideContactHeader({
    required this.ride,
    required this.isDriverView,
    required this.driverProfile,
  });

  final Ride ride;
  final bool isDriverView;
  final Map<String, dynamic>? driverProfile;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final driverName = driverProfile?['name']?.toString();
    final peer = isDriverView ? 'Passenger' : driverName ?? 'Assigned driver';
    final vehicle =
        [
              driverProfile?['vehicle_color'],
              driverProfile?['vehicle_make'],
              driverProfile?['vehicle_model'],
            ]
            .where(
              (value) => value != null && value.toString().trim().isNotEmpty,
            )
            .join(' ');
    final plate = driverProfile?['plate_number']?.toString();
    final status = switch (ride.status) {
      'driver_assigned' => 'Driver assigned',
      'en_route' => 'Trip in progress',
      _ => ride.status.replaceAll('_', ' '),
    };

    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.marginMobile,
        AppSpacing.base,
        AppSpacing.marginMobile,
        0,
      ),
      padding: const EdgeInsets.all(AppSpacing.gutter),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: colorScheme.primaryContainer,
            foregroundColor: colorScheme.onPrimaryContainer,
            child: Icon(isDriverView ? Icons.person_outline : Icons.local_taxi),
          ),
          const SizedBox(width: AppSpacing.gutter),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(peer, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${ride.pickup} → ${ride.destination}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (!isDriverView && (vehicle.isNotEmpty || plate != null)) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    [
                      vehicle,
                      ?plate,
                    ].where((value) => value.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(AppRadius.xl),
            ),
            child: Text(
              status,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.isMine,
    required this.peerLabel,
  });

  final ChatMessage message;
  final bool isMine;
  final String peerLabel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final createdAt = message.createdAt;
    final time = createdAt == null
        ? null
        : TimeOfDay.fromDateTime(createdAt.toLocal()).format(context);
    final bodyColor = isMine ? colorScheme.onPrimary : colorScheme.onSurface;
    final mutedColor = isMine
        ? colorScheme.onPrimary.withValues(alpha: 0.8)
        : colorScheme.onSurfaceVariant;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.75,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isMine
                ? colorScheme.primaryContainer
                : colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(AppRadius.lg),
              topRight: const Radius.circular(AppRadius.lg),
              bottomLeft: Radius.circular(isMine ? AppRadius.lg : AppRadius.sm),
              bottomRight: Radius.circular(
                isMine ? AppRadius.sm : AppRadius.lg,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.gutter,
              vertical: AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isMine ? 'You' : peerLabel,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: mutedColor),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(message.body, style: TextStyle(color: bodyColor)),
                if (time != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    time,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: mutedColor),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickReplyBar extends StatelessWidget {
  const _QuickReplyBar({
    required this.replies,
    required this.isSending,
    required this.onSend,
  });

  final List<String> replies;
  final bool isSending;
  final ValueChanged<String> onSend;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        scrollDirection: Axis.horizontal,
        itemCount: replies.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, index) => ActionChip(
          label: Text(
            replies[index],
            style: Theme.of(context).textTheme.bodySmall,
          ),
          onPressed: isSending ? null : () => onSend(replies[index]),
        ),
      ),
    );
  }
}

class _MessageComposer extends StatelessWidget {
  const _MessageComposer({
    required this.controller,
    required this.isSending,
    required this.onSend,
    required this.hintText,
  });

  final TextEditingController controller;
  final bool isSending;
  final VoidCallback onSend;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  decoration: InputDecoration(hintText: hintText),
                ),
              ),
              const SizedBox(width: AppSpacing.base),
              IconButton.filled(
                onPressed: isSending ? null : onSend,
                tooltip: 'Send message',
                icon: isSending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatUnavailable extends StatelessWidget {
  const _ChatUnavailable({
    required this.icon,
    required this.message,
    this.buttonLabel,
    this.onPressed,
  });

  final IconData icon;
  final String message;
  final String? buttonLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.marginMobile),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.gutter),
            Text(message, textAlign: TextAlign.center),
            if (buttonLabel != null && onPressed != null) ...[
              const SizedBox(height: AppSpacing.gutter),
              OutlinedButton(onPressed: onPressed, child: Text(buttonLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

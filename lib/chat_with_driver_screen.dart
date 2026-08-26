import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_message.dart';
import 'ride.dart';
import 'supabase_config.dart';

class ChatWithDriverScreen extends StatefulWidget {
  const ChatWithDriverScreen({
    super.key,
    this.rideId,
    this.title = 'Chat with Driver',
  });

  final String? rideId;
  final String title;

  @override
  State<ChatWithDriverScreen> createState() => _ChatWithDriverScreenState();
}

class _ChatWithDriverScreenState extends State<ChatWithDriverScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Ride? _activeRide;
  String? _loadError;
  bool _isLoading = true;
  bool _isSending = false;

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
            .inFilter('status', ['matched', 'en_route'])
            .order('created_at', ascending: false)
            .limit(1);
        if (data.isNotEmpty) {
          ride = Ride.fromJson(data.first);
        }
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _activeRide = ride;
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
    if (body.isEmpty || ride == null || _isSending) {
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
          : ride == null
          ? _ChatUnavailable(
              icon: Icons.forum_outlined,
              message:
                  'Chat becomes available after a driver accepts your ride.',
              buttonLabel: 'Check again',
              onPressed: _loadActiveRide,
            )
          : Column(
              children: [
                _RideHeader(ride: ride),
                Expanded(child: _buildMessageList(ride)),
                _MessageComposer(
                  controller: _messageController,
                  isSending: _isSending,
                  onSend: _sendMessage,
                ),
              ],
            ),
    );
  }

  Widget _buildMessageList(Ride ride) {
    final currentUserId = supabase.auth.currentUser!.id;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: supabase
          .from('messages')
          .stream(primaryKey: ['id'])
          .eq('ride_id', ride.id)
          .order('created_at'),
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

        final messages = (snapshot.data ?? [])
            .map(ChatMessage.fromJson)
            .toList();
        if (messages.isEmpty) {
          return const _ChatUnavailable(
            icon: Icons.waving_hand_outlined,
            message: 'No messages yet. Say hello to your driver.',
          );
        }

        _scrollToLatest();
        return ListView.separated(
          controller: _scrollController,
          padding: const EdgeInsets.all(AppSpacing.marginMobile),
          itemCount: messages.length,
          separatorBuilder: (context, index) =>
              const SizedBox(height: AppSpacing.base),
          itemBuilder: (context, index) {
            final message = messages[index];
            return _MessageBubble(
              message: message,
              isMine: message.senderId == currentUserId,
            );
          },
        );
      },
    );
  }
}

class _RideHeader extends StatelessWidget {
  const _RideHeader({required this.ride});

  final Ride ride;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.marginMobile,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            const Icon(Icons.route),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${ride.pickup} → ${ride.destination}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    ride.status.replaceAll('_', ' '),
                    style: AppTextStyles.labelCaps,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.isMine});

  final ChatMessage message;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final createdAt = message.createdAt;
    final time = createdAt == null
        ? null
        : TimeOfDay.fromDateTime(createdAt.toLocal()).format(context);

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
                Text(message.body),
                if (time != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    time,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
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

class _MessageComposer extends StatelessWidget {
  const _MessageComposer({
    required this.controller,
    required this.isSending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool isSending;
  final VoidCallback onSend;

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
                  decoration: const InputDecoration(
                    hintText: 'Message your driver',
                  ),
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

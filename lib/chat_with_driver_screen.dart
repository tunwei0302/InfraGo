import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_message.dart';
import 'ride.dart';
import 'supabase_config.dart';

class ChatWithDriverScreen extends StatefulWidget {
  const ChatWithDriverScreen({super.key});

  @override
  State<ChatWithDriverScreen> createState() => _ChatWithDriverScreenState();
}

class _ChatWithDriverScreenState extends State<ChatWithDriverScreen> {
  final TextEditingController _messageController = TextEditingController();
  Ride? _activeRide;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadActiveRide();
  }

  Future<void> _loadActiveRide() async {
    final userId = supabase.auth.currentUser!.id;
    final data = await supabase
        .from('rides')
        .select()
        .or('rider_id.eq.$userId,driver_id.eq.$userId')
        .inFilter('status', ['matched', 'en_route']);
    setState(() {
      _activeRide = data.isNotEmpty ? Ride.fromJson(data.first) : null;
      _isLoading = false;
    });
  }

  Future<void> _sendMessage() async {
    if (_messageController.text.trim().isEmpty || _activeRide == null) {
      return;
    }
    await supabase.from('messages').insert({
      'ride_id': _activeRide!.id,
      'sender_id': supabase.auth.currentUser!.id,
      'body': _messageController.text.trim(),
    });
    _messageController.clear();
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chat with Driver')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _activeRide == null
              ? const Center(child: Text('No active ride'))
              : Column(
                  children: [
                    Expanded(
                      child: StreamBuilder<List<Map<String, dynamic>>>(
                        stream: supabase
                            .from('messages')
                            .stream(primaryKey: ['id'])
                            .eq('ride_id', _activeRide!.id)
                            .order('created_at'),
                        builder: (context, snapshot) {
                          final messages =
                              (snapshot.data ?? []).map(ChatMessage.fromJson).toList();
                          if (messages.isEmpty) {
                            return const Center(child: Text('No messages yet'));
                          }
                          return ListView.builder(
                            padding: const EdgeInsets.all(AppSpacing.marginMobile),
                            itemCount: messages.length,
                            itemBuilder: (context, index) => ListTile(
                              title: Text(messages[index].body),
                            ),
                          );
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.gutter),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _messageController,
                              decoration: const InputDecoration(hintText: 'Type a message'),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.send),
                            onPressed: _sendMessage,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}

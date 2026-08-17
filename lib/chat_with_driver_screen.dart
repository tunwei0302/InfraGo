import 'package:flutter/material.dart';

import 'app_theme.dart';

class ChatWithDriverScreen extends StatefulWidget {
  const ChatWithDriverScreen({super.key});

  @override
  State<ChatWithDriverScreen> createState() => _ChatWithDriverScreenState();
}

class _ChatWithDriverScreenState extends State<ChatWithDriverScreen> {
  final List<String> _messages = [];
  final TextEditingController _messageController = TextEditingController();

  void _sendMessage() {
    if (_messageController.text.trim().isEmpty) {
      return;
    }
    setState(() {
      _messages.add(_messageController.text.trim());
      _messageController.clear();
    });
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
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(child: Text('No messages yet'))
                : ListView.builder(
                    padding: const EdgeInsets.all(AppSpacing.marginMobile),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) => ListTile(
                      title: Text(_messages[index]),
                    ),
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

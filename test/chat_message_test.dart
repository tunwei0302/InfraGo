import 'package:flutter_test/flutter_test.dart';

import 'package:infra_go/kueh/chat_message.dart';

void main() {
  test('creates a chat message from Supabase data', () {
    final message = ChatMessage.fromJson({
      'id': 12,
      'ride_id': 'ride-1',
      'sender_id': 'user-1',
      'body': 'I am at the pickup point.',
      'created_at': '2026-08-26T08:30:00Z',
    });

    expect(message.id, 12);
    expect(message.rideId, 'ride-1');
    expect(message.senderId, 'user-1');
    expect(message.body, 'I am at the pickup point.');
    expect(message.createdAt, DateTime.utc(2026, 8, 26, 8, 30));
  });

  test('sorts chat messages oldest first and newest at the bottom', () {
    ChatMessage message(int id, String createdAt) => ChatMessage.fromJson({
      'id': id,
      'ride_id': 'ride-1',
      'sender_id': 'user-1',
      'body': 'Message $id',
      'created_at': createdAt,
    });

    final sorted = sortChatMessagesOldestFirst([
      message(3, '2026-08-26T08:32:00Z'),
      message(1, '2026-08-26T08:30:00Z'),
      message(2, '2026-08-26T08:31:00Z'),
    ]);

    expect(sorted.map((item) => item.id), [1, 2, 3]);
    expect(sorted.last.body, 'Message 3');
  });
}

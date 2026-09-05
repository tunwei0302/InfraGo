class ChatMessage {
  final int id;
  final String rideId;
  final String senderId;
  final String body;
  final DateTime? createdAt;
  final String? imagePath;

  ChatMessage({
    required this.id,
    required this.rideId,
    required this.senderId,
    required this.body,
    required this.createdAt,
    this.imagePath,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as int,
    rideId: json['ride_id'] as String,
    senderId: json['sender_id'] as String,
    body: json['body'] as String,
    createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
    imagePath: json['image_path'] as String?,
  );
}

List<ChatMessage> sortChatMessagesOldestFirst(Iterable<ChatMessage> messages) {
  final sorted = messages.toList(growable: false);
  sorted.sort((a, b) {
    final aTime = a.createdAt;
    final bTime = b.createdAt;
    if (aTime != null && bTime != null) {
      final byTime = aTime.compareTo(bTime);
      if (byTime != 0) return byTime;
    } else if (aTime == null && bTime != null) {
      return -1;
    } else if (aTime != null && bTime == null) {
      return 1;
    }
    return a.id.compareTo(b.id);
  });
  return sorted;
}

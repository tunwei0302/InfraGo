class ChatMessage {
  final int id;
  final String rideId;
  final String senderId;
  final String body;

  ChatMessage({
    required this.id,
    required this.rideId,
    required this.senderId,
    required this.body,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as int,
        rideId: json['ride_id'] as String,
        senderId: json['sender_id'] as String,
        body: json['body'] as String,
      );
}

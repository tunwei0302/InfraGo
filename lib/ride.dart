class Ride {
  final String id;
  final String riderId;
  final String? driverId;
  final String pickup;
  final String destination;
  final String status;
  final double? fare;

  Ride({
    required this.id,
    required this.riderId,
    required this.driverId,
    required this.pickup,
    required this.destination,
    required this.status,
    required this.fare,
  });

  factory Ride.fromJson(Map<String, dynamic> json) => Ride(
        id: json['id'] as String,
        riderId: json['rider_id'] as String,
        driverId: json['driver_id'] as String?,
        pickup: json['pickup'] as String,
        destination: json['destination'] as String,
        status: json['status'] as String,
        fare: (json['fare'] as num?)?.toDouble(),
      );
}

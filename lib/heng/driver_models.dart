enum ApprovalStatus { missing, pending, approved, rejected }

ApprovalStatus approvalStatusFrom(Object? value) {
  return ApprovalStatus.values.firstWhere(
    (status) => status.name == value,
    orElse: () => ApprovalStatus.missing,
  );
}

class DriverReadiness {
  const DriverReadiness({
    required this.verificationStatus,
    required this.vehicleStatus,
    this.rejectionReason,
    this.vehicle,
  });

  final ApprovalStatus verificationStatus;
  final ApprovalStatus vehicleStatus;
  final String? rejectionReason;
  final DriverVehicle? vehicle;

  bool get canGoOnline =>
      verificationStatus == ApprovalStatus.approved &&
      vehicleStatus == ApprovalStatus.approved &&
      vehicle != null;

  String get guidance {
    if (verificationStatus == ApprovalStatus.rejected ||
        vehicleStatus == ApprovalStatus.rejected) {
      return rejectionReason?.trim().isNotEmpty == true
          ? 'Review rejected: $rejectionReason'
          : 'Review rejected. Update your documents and resubmit.';
    }
    if (verificationStatus == ApprovalStatus.pending ||
        vehicleStatus == ApprovalStatus.pending) {
      return 'Your driver and vehicle information is awaiting manual review.';
    }
    if (verificationStatus == ApprovalStatus.missing ||
        vehicleStatus == ApprovalStatus.missing) {
      return 'Complete driver verification and registered vehicle information.';
    }
    return 'Approved to receive rides.';
  }
}

class DriverVehicle {
  const DriverVehicle({
    required this.make,
    required this.model,
    required this.color,
    required this.bodyType,
    required this.plateNumber,
    required this.passengerCapacity,
    required this.approvalStatus,
  });

  final String make;
  final String model;
  final String color;
  final String bodyType;
  final String plateNumber;
  final int passengerCapacity;
  final ApprovalStatus approvalStatus;

  factory DriverVehicle.fromJson(Map<String, dynamic> json) => DriverVehicle(
    make: json['make']?.toString() ?? '',
    model: json['model']?.toString() ?? '',
    color: json['color']?.toString() ?? '',
    bodyType: json['body_type']?.toString() ?? '',
    plateNumber: json['plate_number']?.toString() ?? '',
    passengerCapacity: (json['passenger_capacity'] as num?)?.toInt() ?? 0,
    approvalStatus: approvalStatusFrom(json['approval_status']),
  );
}

class DriverOnboardingValidator {
  static String normalisePlate(String value) =>
      value.toUpperCase().replaceAll(RegExp(r'[\s-]+'), '');

  static String? requiredText(String? value, String label) {
    if (value == null || value.trim().isEmpty) return '$label is required.';
    return null;
  }

  static String? plate(String? value) {
    final normalised = normalisePlate(value ?? '');
    if (normalised.length < 3 || normalised.length > 12) {
      return 'Plate number must contain 3–12 characters.';
    }
    if (!RegExp(r'^[A-Z0-9]+$').hasMatch(normalised)) {
      return 'Plate number may contain letters and numbers only.';
    }
    return null;
  }

  static String? capacity(int? value) {
    if (value == null || value < 1 || value > 6) {
      return 'Passenger capacity must be between 1 and 6.';
    }
    return null;
  }

  static bool isSupportedImage({required String name, required int bytes}) {
    final extension = name.toLowerCase().split('.').last;
    return const {'jpg', 'jpeg', 'png'}.contains(extension) &&
        bytes > 0 &&
        bytes <= 5 * 1024 * 1024;
  }
}

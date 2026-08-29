import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_config.dart';

class PickupLandmarkValidationException implements Exception {
  const PickupLandmarkValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PickedLandmarkPhoto {
  const PickedLandmarkPhoto({required this.bytes, required this.extension});

  final Uint8List bytes;
  final String extension;
}

typedef ImagePickerFn = Future<XFile?> Function(ImageSource source);

class PickupLandmarkService {
  PickupLandmarkService({ImagePickerFn? pickImage, SupabaseClient? client})
    : _pickImage = pickImage ?? _defaultPickImage,
      _clientOverride = client;

  final ImagePickerFn _pickImage;
  final SupabaseClient? _clientOverride;

  SupabaseClient get _client => _clientOverride ?? supabase;

  static const int maxBytes = 8 * 1024 * 1024;
  static const int maxDimension = 4000;
  static const List<String> allowedExtensions = ['jpg', 'jpeg', 'png'];

  static Future<XFile?> _defaultPickImage(ImageSource source) {
    return ImagePicker().pickImage(
      source: source,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 70,
    );
  }

  Future<PickedLandmarkPhoto?> pick(ImageSource source) async {
    XFile? file;
    try {
      file = await _pickImage(source);
    } on PlatformException {
      throw const PickupLandmarkValidationException(
        'Camera or gallery access was denied. You can still book without a photo.',
      );
    }
    if (file == null) return null;

    final bytes = await file.readAsBytes();
    final extension = _extensionOf(file.path, bytes);
    if (!allowedExtensions.contains(extension)) {
      throw const PickupLandmarkValidationException(
        'Only JPG or PNG photos are supported.',
      );
    }
    if (bytes.length > maxBytes) {
      throw const PickupLandmarkValidationException(
        'Photo is too large (max 8 MB).',
      );
    }
    await _validateDimensions(bytes);
    return PickedLandmarkPhoto(bytes: bytes, extension: extension);
  }

  Future<void> _validateDimensions(Uint8List bytes) async {
    final ui.Codec codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
    } catch (_) {
      throw const PickupLandmarkValidationException(
        'That file is not a supported photo format.',
      );
    }
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final tooLarge = image.width > maxDimension || image.height > maxDimension;
    image.dispose();
    if (tooLarge) {
      throw const PickupLandmarkValidationException(
        'Photo dimensions are too large.',
      );
    }
  }

  String _extensionOf(String path, Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) return 'jpg';
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    final dot = path.lastIndexOf('.');
    if (dot == -1) return '';
    return path.substring(dot + 1).toLowerCase();
  }

  Future<String> upload({
    required String riderId,
    required String rideId,
    required PickedLandmarkPhoto photo,
  }) async {
    final path = '$riderId/$rideId/photo.${photo.extension}';
    await _client.storage
        .from('pickup-landmarks')
        .uploadBinary(
          path,
          photo.bytes,
          fileOptions: FileOptions(
            contentType: photo.extension == 'png' ? 'image/png' : 'image/jpeg',
            upsert: true,
          ),
        );
    await _client
        .from('rides')
        .update({'pickup_landmark_path': path})
        .eq('id', rideId);
    return path;
  }
}

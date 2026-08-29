import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:infra_go/foo/pickup_landmark_service.dart';

Future<Uint8List> _pngBytes(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint(),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return byteData!.buffer.asUint8List();
}

Future<Uint8List> _tinyPngBytes() => _pngBytes(4, 4);

Future<Uint8List> _oversizedDimensionPngBytes() =>
    _pngBytes(PickupLandmarkService.maxDimension + 1, 1);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('returns null when the user cancels the picker', () async {
    final service = PickupLandmarkService(pickImage: (_) async => null);
    final result = await service.pick(ImageSource.gallery);
    expect(result, isNull);
  });

  test('denied camera/gallery access surfaces a friendly message, not a crash', () async {
    final service = PickupLandmarkService(
      pickImage: (_) => throw PlatformException(code: 'camera_access_denied'),
    );
    await expectLater(
      () => service.pick(ImageSource.camera),
      throwsA(isA<PickupLandmarkValidationException>()),
    );
  });

  test('accepts a valid small PNG and reports its extension', () async {
    final bytes = await _tinyPngBytes();
    final service = PickupLandmarkService(
      pickImage: (_) async => XFile.fromData(
        bytes,
        name: 'landmark.png',
        mimeType: 'image/png',
      ),
    );
    final result = await service.pick(ImageSource.gallery);
    expect(result, isNotNull);
    expect(result!.extension, 'png');
    expect(result.bytes, bytes);
  });

  test('rejects an unsupported format', () async {
    final junk = Uint8List.fromList(List.filled(20, 0x00));
    final service = PickupLandmarkService(
      pickImage: (_) async =>
          XFile.fromData(junk, name: 'landmark.gif', mimeType: 'image/gif'),
    );
    await expectLater(
      () => service.pick(ImageSource.gallery),
      throwsA(
        isA<PickupLandmarkValidationException>().having(
          (e) => e.message,
          'message',
          contains('JPG or PNG'),
        ),
      ),
    );
  });

  test('rejects a file larger than the maximum byte size', () async {
    final oversized = Uint8List(PickupLandmarkService.maxBytes + 1);
    oversized[0] = 0xFF;
    oversized[1] = 0xD8;
    final service = PickupLandmarkService(
      pickImage: (_) async =>
          XFile.fromData(oversized, name: 'landmark.jpg', mimeType: 'image/jpeg'),
    );
    await expectLater(
      () => service.pick(ImageSource.camera),
      throwsA(
        isA<PickupLandmarkValidationException>().having(
          (e) => e.message,
          'message',
          contains('too large'),
        ),
      ),
    );
  });

  test('rejects a photo whose dimensions exceed the maximum', () async {
    final bytes = await _oversizedDimensionPngBytes();
    final service = PickupLandmarkService(
      pickImage: (_) async =>
          XFile.fromData(bytes, name: 'landmark.png', mimeType: 'image/png'),
    );
    await expectLater(
      () => service.pick(ImageSource.gallery),
      throwsA(
        isA<PickupLandmarkValidationException>().having(
          (e) => e.message,
          'message',
          contains('dimensions'),
        ),
      ),
    );
  });
}

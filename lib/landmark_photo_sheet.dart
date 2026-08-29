import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'app_theme.dart';
import 'pickup_landmark_service.dart';

class LandmarkPhotoSheet extends StatefulWidget {
  const LandmarkPhotoSheet({super.key, required this.service});

  final PickupLandmarkService service;

  static Future<PickedLandmarkPhoto?> show(
    BuildContext context, {
    required PickupLandmarkService service,
  }) {
    return showModalBottomSheet<PickedLandmarkPhoto?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => LandmarkPhotoSheet(service: service),
    );
  }

  @override
  State<LandmarkPhotoSheet> createState() => _LandmarkPhotoSheetState();
}

class _LandmarkPhotoSheetState extends State<LandmarkPhotoSheet> {
  PickedLandmarkPhoto? _photo;
  bool _isPicking = false;
  String? _error;

  Future<void> _pick(ImageSource source) async {
    setState(() {
      _isPicking = true;
      _error = null;
    });
    try {
      final photo = await widget.service.pick(source);
      if (!mounted) return;
      setState(() => _photo = photo ?? _photo);
    } on PickupLandmarkValidationException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not use that photo. Try again.');
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.gutter,
        right: AppSpacing.gutter,
        top: AppSpacing.gutter,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.gutter,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            Text(
              'Pickup landmark photo',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Optional — helps your driver find you exactly.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            if (_photo != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.standard),
                child: Image.memory(
                  _photo!.bytes,
                  height: 160,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isPicking ? null : () => _pick(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Camera'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isPicking
                        ? null
                        : () => _pick(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Gallery'),
                  ),
                ),
              ],
            ),
            if (_photo != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _isPicking ? null : () => setState(() => _photo = null),
                  child: const Text('Remove photo'),
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(_photo),
              child: Text(_photo == null ? 'Skip' : 'Continue'),
            ),
          ],
        ),
      ),
    );
  }
}

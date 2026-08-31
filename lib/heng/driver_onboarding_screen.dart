import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:infra_go/heng/driver_models.dart';
import 'package:infra_go/heng/driver_repository.dart';
import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/shared/supabase_config.dart';

class DriverOnboardingScreen extends StatefulWidget {
  const DriverOnboardingScreen({super.key});

  @override
  State<DriverOnboardingScreen> createState() => _DriverOnboardingScreenState();
}

class _DriverOnboardingScreenState extends State<DriverOnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _displayName = TextEditingController();
  final _contact = TextEditingController();
  final _make = TextEditingController();
  final _model = TextEditingController();
  final _color = TextEditingController();
  final _plate = TextEditingController();
  final _capacity = TextEditingController(text: '4');
  final _picker = ImagePicker();
  final _repository = DriverRepository(supabase);

  XFile? _licence;
  XFile? _selfie;
  String _bodyType = 'sedan';
  bool _consent = false;
  bool _submitting = false;

  @override
  void dispose() {
    for (final controller in [
      _displayName,
      _contact,
      _make,
      _model,
      _color,
      _plate,
      _capacity,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _pickLicence() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 2000,
    );
    if (file != null && mounted) setState(() => _licence = file);
  }

  Future<void> _takeSelfie() async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.front,
      imageQuality: 85,
      maxWidth: 1600,
    );
    if (file != null && mounted) setState(() => _selfie = file);
  }

  Future<Uint8List> _validatedBytes(XFile file, String label) async {
    final bytes = await file.readAsBytes();
    if (!DriverOnboardingValidator.isSupportedImage(
      name: file.name,
      bytes: bytes.length,
    )) {
      throw FormatException('$label must be a JPG or PNG smaller than 5 MB.');
    }
    return bytes;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_licence == null || _selfie == null || !_consent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Add your licence, take a selfie and accept manual review.',
          ),
        ),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      final licenceBytes = await _validatedBytes(_licence!, 'Driving licence');
      final selfieBytes = await _validatedBytes(_selfie!, 'Selfie');
      await _repository.submitOnboarding(
        displayName: _displayName.text,
        contact: _contact.text,
        licenceBytes: licenceBytes,
        licenceName: _licence!.name,
        selfieBytes: selfieBytes,
        selfieName: _selfie!.name,
        make: _make.text,
        model: _model.text,
        color: _color.text,
        bodyType: _bodyType,
        plateNumber: _plate.text,
        passengerCapacity: int.parse(_capacity.text),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Submitted for manual review.')),
      );
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not submit: $error')));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Become a verified driver')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.marginMobile),
          children: [
            Text(
              'Identity review',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.xs),
            const Text(
              'InfraGo performs a manual review of your driving licence and current selfie. This is not government eKYC or facial recognition.',
            ),
            const SizedBox(height: AppSpacing.gutter),
            _field(_displayName, 'Display name'),
            _field(_contact, 'Phone or contact'),
            _DocumentTile(
              icon: Icons.badge_outlined,
              title: 'Driving licence',
              fileName: _licence?.name,
              buttonLabel: 'Choose photo',
              onPressed: _pickLicence,
            ),
            _DocumentTile(
              icon: Icons.face_outlined,
              title: 'Current selfie',
              fileName: _selfie?.name,
              buttonLabel: 'Open camera',
              onPressed: _takeSelfie,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Registered vehicle information',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.xs),
            const Text(
              'Passengers see these details only after a driver accepts their ride.',
            ),
            const SizedBox(height: AppSpacing.gutter),
            _field(_make, 'Vehicle make (e.g. Perodua)'),
            _field(_model, 'Vehicle model (e.g. Myvi)'),
            _field(_color, 'Vehicle colour'),
            DropdownButtonFormField<String>(
              initialValue: _bodyType,
              decoration: const InputDecoration(labelText: 'Body type'),
              items: const [
                DropdownMenuItem(value: 'sedan', child: Text('Sedan')),
                DropdownMenuItem(value: 'hatchback', child: Text('Hatchback')),
                DropdownMenuItem(value: 'mpv', child: Text('MPV')),
                DropdownMenuItem(value: 'suv', child: Text('SUV')),
              ],
              onChanged: (value) => setState(() => _bodyType = value!),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextFormField(
              controller: _plate,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Plate number'),
              validator: DriverOnboardingValidator.plate,
            ),
            const SizedBox(height: AppSpacing.sm),
            TextFormField(
              controller: _capacity,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Passenger capacity (excluding driver)',
              ),
              validator: (value) =>
                  DriverOnboardingValidator.capacity(int.tryParse(value ?? '')),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _consent,
              onChanged: (value) => setState(() => _consent = value ?? false),
              title: const Text('I consent to manual document review.'),
              subtitle: const Text(
                'Demo documents must use fictional information.',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton.icon(
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.verified_user_outlined),
              label: Text(
                _submitting ? 'Uploading securely…' : 'Submit for review',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController controller, String label) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: TextFormField(
      controller: controller,
      decoration: InputDecoration(labelText: label),
      validator: (value) =>
          DriverOnboardingValidator.requiredText(value, label),
    ),
  );
}

class _DocumentTile extends StatelessWidget {
  const _DocumentTile({
    required this.icon,
    required this.title,
    required this.fileName,
    required this.buttonLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String? fileName;
  final String buttonLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(fileName ?? 'JPG or PNG, up to 5 MB'),
      trailing: TextButton(onPressed: onPressed, child: Text(buttonLabel)),
    ),
  );
}

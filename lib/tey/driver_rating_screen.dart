import 'package:flutter/material.dart';

import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/tey/driver_rating_repository.dart';
import 'package:infra_go/shared/supabase_config.dart';

const List<String> _kRatingTags = [
  'Clean vehicle',
  'Friendly',
  'Safe driving',
  'On time',
  'Great route',
];

const List<String> _kIssueCategories = [
  'Safety',
  'Vehicle condition',
  'Route',
  'Behaviour',
  'Other',
];

class DriverRatingScreen extends StatefulWidget {
  const DriverRatingScreen({
    super.key,
    required this.rideId,
    required this.driverId,
  });

  final String rideId;
  final String driverId;

  @override
  State<DriverRatingScreen> createState() => _DriverRatingScreenState();
}

class _DriverRatingScreenState extends State<DriverRatingScreen> {
  final DriverRatingRepository _repository = DriverRatingRepository(supabase);
  final TextEditingController _commentController = TextEditingController();
  int _score = 5;
  final Set<String> _selectedTags = {};
  String? _issueCategory;
  bool _isSubmitting = false;
  String? _error;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      await _repository.submitRating(
        rideId: widget.rideId,
        driverId: widget.driverId,
        score: _score,
        tags: _selectedTags.toList(),
        comment: _commentController.text.trim(),
        issueCategory: _score <= 2 ? _issueCategory : null,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on DriverRatingException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rate your driver')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.marginMobile),
        children: [
          Text('Score', style: AppTextStyles.labelCaps),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: List.generate(5, (index) {
              final starValue = index + 1;
              return IconButton(
                onPressed: () => setState(() => _score = starValue),
                icon: Icon(
                  starValue <= _score ? Icons.star : Icons.star_border,
                  color: Theme.of(context).colorScheme.primary,
                ),
              );
            }),
          ),
          const SizedBox(height: AppSpacing.md),
          Text('What went well?', style: AppTextStyles.labelCaps),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: _kRatingTags
                .map(
                  (tag) => FilterChip(
                    label: Text(tag),
                    selected: _selectedTags.contains(tag),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        _selectedTags.add(tag);
                      } else {
                        _selectedTags.remove(tag);
                      }
                    }),
                  ),
                )
                .toList(),
          ),
          if (_score <= 2) ...[
            const SizedBox(height: AppSpacing.md),
            Text('What was the issue?', style: AppTextStyles.labelCaps),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: _kIssueCategories
                  .map(
                    (category) => ChoiceChip(
                      label: Text(category),
                      selected: _issueCategory == category,
                      onSelected: (selected) => setState(
                        () => _issueCategory = selected ? category : null,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Text('Comment (optional)', style: AppTextStyles.labelCaps),
          const SizedBox(height: AppSpacing.xs),
          TextField(
            controller: _commentController,
            maxLength: 300,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'Anything else you\'d like to share?',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          ElevatedButton(
            onPressed: _isSubmitting ? null : _submit,
            child: Text(_isSubmitting ? 'Submitting…' : 'Submit rating'),
          ),
        ],
      ),
    );
  }
}

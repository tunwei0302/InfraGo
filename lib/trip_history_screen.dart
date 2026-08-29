import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'app_theme.dart';
import 'location_search_service.dart';
import 'receipt_repository.dart';
import 'receipt_screen.dart';
import 'supabase_config.dart';
import 'trip_planner_map_screen.dart';

class TripHistoryScreen extends StatefulWidget {
  const TripHistoryScreen({super.key});

  @override
  State<TripHistoryScreen> createState() => _TripHistoryScreenState();
}

class _TripHistoryScreenState extends State<TripHistoryScreen> {
  final ReceiptRepository _repository = ReceiptRepository(supabase);
  List<Map<String, dynamic>> _rides = const [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final riderId = supabase.auth.currentUser?.id;
    if (riderId == null) {
      setState(() {
        _isLoading = false;
        _error = 'Sign in to see your trip history.';
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final rides = await _repository.loadHistory(riderId);
      if (!mounted) return;
      setState(() {
        _rides = rides;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load trip history.';
        _isLoading = false;
      });
    }
  }

  void _bookAgain(Map<String, dynamic> ride) {
    final pickupLat = (ride['pickup_latitude'] as num?)?.toDouble();
    final pickupLng = (ride['pickup_longitude'] as num?)?.toDouble();
    final destinationLat = (ride['destination_latitude'] as num?)?.toDouble();
    final destinationLng = (ride['destination_longitude'] as num?)?.toDouble();
    if (pickupLat == null ||
        pickupLng == null ||
        destinationLat == null ||
        destinationLng == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This trip is missing coordinates to book again.'),
        ),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TripPlannerMapScreen(
          initialPickup: GeoPlace(
            name: ride['pickup'] as String,
            address: '',
            point: LatLng(pickupLat, pickupLng),
          ),
          initialDestination: GeoPlace(
            name: ride['destination'] as String,
            address: '',
            point: LatLng(destinationLat, destinationLng),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trip history')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : _rides.isEmpty
          ? const Center(child: Text('No past trips yet.'))
          : ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.marginMobile),
              itemCount: _rides.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (context, index) {
                final ride = _rides[index];
                final rideId = ride['id'] as String;
                return Card(
                  child: ListTile(
                    title: Text(
                      '${ride['pickup']} → ${ride['destination']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      'Status: ${(ride['status'] as String).replaceAll('_', ' ')}',
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ReceiptScreen(rideId: rideId),
                      ),
                    ),
                    trailing: TextButton(
                      onPressed: () => _bookAgain(ride),
                      child: const Text('Book again'),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/ride.dart';
import '../services/ride_repository.dart';
import '../utils/format_utils.dart';
import 'ride_detail_screen.dart';

/// Lists every previously saved ride, newest first (as returned by
/// [RideRepository.getAllRidesSummary]). Tapping a ride opens its full detail
/// view with the recorded route and stats.
class RideHistoryScreen extends StatelessWidget {
  const RideHistoryScreen({super.key});

  static final _dateFormat = DateFormat('yyyy/MM/dd - HH:mm');

  @override
  Widget build(BuildContext context) {
    final repository = context.read<RideRepository>();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text('سجل الرحلات'),
      ),
      body: FutureBuilder<List<Ride>>(
        future: repository.getAllRidesSummary(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          final rides = snapshot.data ?? const <Ride>[];
          if (rides.isEmpty) {
            return const Center(
              child: Text(
                'لا توجد رحلات محفوظة بعد',
                style: TextStyle(color: Colors.white54, fontSize: 16),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: rides.length,
            itemBuilder: (context, index) {
              final ride = rides[index];
              return Card(
                color: Colors.white10,
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  title: Text(
                    _dateFormat.format(ride.startTime),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '${ride.totalDistanceKm.toStringAsFixed(2)} كم  •  '
                    '${formatDuration(ride.duration)}  •  '
                    '${ride.avgSpeedKmh.toStringAsFixed(1)} كم/س',
                    style: const TextStyle(color: Colors.white54),
                  ),
                  trailing: const Icon(
                    Icons.chevron_left,
                    color: Colors.white38,
                  ),
                  onTap: () {
                    final rideId = ride.id;
                    if (rideId == null) return;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => RideDetailScreen(rideId: rideId),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

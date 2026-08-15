import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/heart_rate_service.dart';
import '../services/ride_repository.dart';
import '../services/ride_tracker.dart';
import 'hazard_management_screen.dart';
import 'heart_rate_pairing_screen.dart';
import 'profile_screen.dart';
import 'ride_history_screen.dart';
import 'ride_map_view.dart';

class TrackingScreen extends StatelessWidget {
  const TrackingScreen({super.key});

  Future<void> _handleStart(BuildContext context, RideTracker tracker) async {
    final error = await tracker.startRide();
    if (error != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _handleFinish(BuildContext context, RideTracker tracker) async {
    final repository = context.read<RideRepository>();
    final ride = tracker.finishRide();
    if (ride == null) return;

    final saved = await repository.saveRide(ride);
    if (!context.mounted) return;

    final distanceKm = saved.totalDistanceKm.toStringAsFixed(2);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('تم حفظ الرحلة: $distanceKm كم')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        toolbarHeight: 44,
        title: const Text('تتبع الرحلة'),
        actions: [
          Consumer<HeartRateService>(
            builder: (context, heartRateService, child) {
              final connected =
                  heartRateService.connectionState ==
                  HeartRateConnectionState.connected;
              return IconButton(
                icon: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: connected ? null : Colors.white24,
                  ),
                  child: Icon(
                    connected ? Icons.favorite : Icons.favorite_border,
                    color: connected ? Colors.redAccent : Colors.white70,
                  ),
                ),
                tooltip: 'حزام نبض القلب',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const HeartRatePairingScreen(),
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'سجل الرحلات',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const RideHistoryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'الملف الشخصي',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.warning_amber_outlined),
            tooltip: 'نقاط الخطر',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HazardManagementScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Consumer<RideTracker>(
          builder: (context, tracker, child) {
            final ride = tracker.currentRide;
            final distanceKm = ride?.totalDistanceKm ?? 0;
            final duration = ride?.duration ?? Duration.zero;
            final avgSpeedKmh = ride?.avgSpeedKmh ?? 0;
            final elevationGain = ride?.totalElevationGainMeters ?? 0;

            final heartRateService = context.watch<HeartRateService>();
            final heartRateConnected =
                heartRateService.connectionState ==
                HeartRateConnectionState.connected;

            // The map fills nearly the whole screen (elevation/heart-rate/
            // calorie/speed/distance readouts now live in floating cards
            // over it - see RideMapView); only the ride controls keep a
            // fixed-height slot below it.
            return Column(
              children: [
                Expanded(
                  child: RideMapView(
                    points: ride?.points ?? const [],
                    isLive: tracker.state == TrackingState.tracking,
                    heartRateBpm: heartRateService.latestBpm,
                    heartRateConnected: heartRateConnected,
                    liveCalories: tracker.liveCalories,
                    instantSpeedKmh: tracker.instantSpeedKmh,
                    distanceKm: distanceKm,
                    avgSpeedKmh: avgSpeedKmh,
                    elevationGainMeters: elevationGain,
                    duration: duration,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  child: _ControlButtons(
                    tracker: tracker,
                    onStart: () => _handleStart(context, tracker),
                    onFinish: () => _handleFinish(context, tracker),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ControlButtons extends StatelessWidget {
  const _ControlButtons({
    required this.tracker,
    required this.onStart,
    required this.onFinish,
  });

  final RideTracker tracker;
  final VoidCallback onStart;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    switch (tracker.state) {
      case TrackingState.idle:
        return SizedBox(
          width: double.infinity,
          child: _BigButton(
            label: 'ابدأ الرحلة',
            color: Colors.green,
            onPressed: onStart,
          ),
        );
      case TrackingState.tracking:
        return Row(
          children: [
            Expanded(
              child: _BigButton(
                label: 'إيقاف مؤقت',
                color: Colors.orange,
                onPressed: tracker.pauseRide,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _BigButton(
                label: 'إنهاء',
                color: Colors.red,
                onPressed: onFinish,
              ),
            ),
          ],
        );
      case TrackingState.paused:
        return Row(
          children: [
            Expanded(
              child: _BigButton(
                label: 'استئناف',
                color: Colors.green,
                onPressed: tracker.resumeRide,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _BigButton(
                label: 'إنهاء',
                color: Colors.red,
                onPressed: onFinish,
              ),
            ),
          ],
        );
      case TrackingState.finished:
        return SizedBox(
          width: double.infinity,
          child: _BigButton(
            label: 'رحلة جديدة',
            color: Colors.blue,
            onPressed: tracker.reset,
          ),
        );
    }
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 20),
        textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
      ),
      child: Text(label),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/ride.dart';
import '../services/ride_repository.dart';
import '../utils/format_utils.dart';
import 'ride_detail_screen.dart';

/// Lists every previously saved ride, newest first by when it ended (as
/// returned by [RideRepository.getAllRidesSummary]). Tapping a ride opens
/// its full detail view with the recorded route and stats; swiping a ride
/// or using the app bar action deletes it (single ride or all of them)
/// after a confirmation dialog, since both are irreversible.
class RideHistoryScreen extends StatefulWidget {
  const RideHistoryScreen({super.key});

  @override
  State<RideHistoryScreen> createState() => _RideHistoryScreenState();
}

class _RideHistoryScreenState extends State<RideHistoryScreen> {
  static final _dateFormat = DateFormat('yyyy/MM/dd - HH:mm');

  late Future<List<Ride>> _ridesFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final repository = context.read<RideRepository>();
    setState(() {
      _ridesFuture = repository.getAllRidesSummary();
    });
  }

  Future<bool> _confirmDelete({
    required String title,
    required String message,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(
          message,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _deleteRide(Ride ride) async {
    final rideId = ride.id;
    if (rideId == null) return;
    final repository = context.read<RideRepository>();
    await repository.deleteRide(rideId);
    if (!mounted) return;
    _reload();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('تم حذف الرحلة')));
  }

  Future<void> _clearAllHistory() async {
    final repository = context.read<RideRepository>();
    final confirmed = await _confirmDelete(
      title: 'مسح كل السجل؟',
      message:
          'سيتم حذف جميع الرحلات المحفوظة نهائياً. لا يمكن التراجع عن '
          'هذا الإجراء.',
    );
    if (!confirmed) return;

    await repository.clearAllHistory();
    if (!mounted) return;
    _reload();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('تم حذف كل السجل')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text('سجل الرحلات'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'مسح كل السجل',
            onPressed: _clearAllHistory,
          ),
        ],
      ),
      body: FutureBuilder<List<Ride>>(
        future: _ridesFuture,
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
              return Dismissible(
                key: ValueKey(ride.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                confirmDismiss: (_) => _confirmDelete(
                  title: 'حذف هذه الرحلة؟',
                  message:
                      'سيتم حذف هذه الرحلة نهائياً. لا يمكن التراجع عن '
                      'هذا الإجراء.',
                ),
                onDismissed: (_) => _deleteRide(ride),
                child: Card(
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
                    trailing: IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        color: Colors.white38,
                      ),
                      tooltip: 'حذف الرحلة',
                      onPressed: () async {
                        final confirmed = await _confirmDelete(
                          title: 'حذف هذه الرحلة؟',
                          message:
                              'سيتم حذف هذه الرحلة نهائياً. لا يمكن '
                              'التراجع عن هذا الإجراء.',
                        );
                        if (confirmed) {
                          await _deleteRide(ride);
                        }
                      },
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
                ),
              );
            },
          );
        },
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/traffic_hazard.dart';
import '../services/hazard_repository.dart';
import '../services/location_service.dart';

/// Lets the rider maintain their own list of known dangerous locations
/// (e.g. a specific bad intersection), each spoken aloud via TTS when
/// approached during a ride. There is no seeded/bundled hazard data — see
/// traffic_hazard.dart for why.
class HazardManagementScreen extends StatefulWidget {
  const HazardManagementScreen({super.key});

  @override
  State<HazardManagementScreen> createState() => _HazardManagementScreenState();
}

class _HazardManagementScreenState extends State<HazardManagementScreen> {
  final _locationService = LocationService();
  late Future<List<TrafficHazard>> _hazardsFuture;
  bool _isAdding = false;

  @override
  void initState() {
    super.initState();
    _hazardsFuture = context.read<HazardRepository>().getAll();
  }

  void _reload() {
    setState(() {
      _hazardsFuture = context.read<HazardRepository>().getAll();
    });
  }

  Future<void> _addAtCurrentLocation() async {
    setState(() => _isAdding = true);
    try {
      final granted = await _locationService.ensurePermissionsGranted();
      if (!granted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('يجب تفعيل خدمة الموقع ومنح إذن الوصول إليه'),
          ),
        );
        return;
      }

      final position = await _locationService.getCurrentPosition();
      if (!mounted) return;

      final result = await _showHazardFormDialog();
      if (result == null) return;
      if (!mounted) return;

      await context.read<HazardRepository>().add(
        TrafficHazard(
          latitude: position.latitude,
          longitude: position.longitude,
          radiusMeters: result.radiusMeters,
          message: result.message,
        ),
      );
      _reload();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تعذر تحديد الموقع الحالي')));
    } finally {
      if (mounted) setState(() => _isAdding = false);
    }
  }

  Future<_HazardFormResult?> _showHazardFormDialog() {
    final messageController = TextEditingController();
    final radiusController = TextEditingController(text: '50');

    return showDialog<_HazardFormResult>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.grey.shade900,
          title: const Text(
            'إضافة نقطة خطر',
            style: TextStyle(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: messageController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'رسالة التحذير',
                  labelStyle: TextStyle(color: Colors.white54),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: radiusController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'نطاق التنبيه (متر)',
                  labelStyle: TextStyle(color: Colors.white54),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('إلغاء'),
            ),
            TextButton(
              onPressed: () {
                final message = messageController.text.trim();
                final radius =
                    double.tryParse(radiusController.text.trim()) ?? 50;
                if (message.isEmpty || radius <= 0) return;
                Navigator.of(dialogContext).pop(
                  _HazardFormResult(message: message, radiusMeters: radius),
                );
              },
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _delete(int id) async {
    await context.read<HazardRepository>().delete(id);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text('نقاط الخطر'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isAdding ? null : _addAtCurrentLocation,
                  icon: _isAdding
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_location_alt_outlined),
                  label: const Text('إضافة نقطة خطر في موقعي الحالي'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<TrafficHazard>>(
                future: _hazardsFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final hazards = snapshot.data ?? const <TrafficHazard>[];
                  if (hazards.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'لا توجد نقاط خطر محفوظة بعد.\n'
                          'أضف نقطة عند وصولك لموقع تعرفه كخطر حقيقي.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                    );
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: hazards.length,
                    itemBuilder: (context, index) {
                      final hazard = hazards[index];
                      return Card(
                        color: Colors.white10,
                        margin: const EdgeInsets.only(bottom: 12),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          title: Text(
                            hazard.message,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            '${hazard.latitude.toStringAsFixed(5)}, '
                            '${hazard.longitude.toStringAsFixed(5)}  •  '
                            'نطاق ${hazard.radiusMeters.toStringAsFixed(0)} م',
                            style: const TextStyle(color: Colors.white54),
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.redAccent,
                            ),
                            onPressed: hazard.id == null
                                ? null
                                : () => _delete(hazard.id!),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HazardFormResult {
  const _HazardFormResult({required this.message, required this.radiusMeters});

  final String message;
  final double radiusMeters;
}

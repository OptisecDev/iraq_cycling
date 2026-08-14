import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:provider/provider.dart';

import '../services/heart_rate_service.dart';

/// Lists BLE devices advertising the standard Heart Rate Service (0x180D)
/// found during a live scan, and lets the user connect to one. Reachable
/// from the tracking screen; entirely optional to ride tracking.
class HeartRatePairingScreen extends StatefulWidget {
  const HeartRatePairingScreen({super.key});

  @override
  State<HeartRatePairingScreen> createState() => _HeartRatePairingScreenState();
}

class _HeartRatePairingScreenState extends State<HeartRatePairingScreen> {
  @override
  void initState() {
    super.initState();
    final service = context.read<HeartRateService>();
    if (service.connectionState != HeartRateConnectionState.connected) {
      service.startScan();
    }
  }

  @override
  void dispose() {
    context.read<HeartRateService>().stopScan();
    super.dispose();
  }

  String _statusLabel(HeartRateConnectionState state) {
    switch (state) {
      case HeartRateConnectionState.scanning:
        return 'جارٍ البحث عن أجهزة...';
      case HeartRateConnectionState.connecting:
        return 'جارٍ الاتصال...';
      case HeartRateConnectionState.connected:
        return 'متصل';
      case HeartRateConnectionState.disconnected:
        return 'غير متصل';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text('اقتران حزام نبض القلب'),
      ),
      body: Consumer<HeartRateService>(
        builder: (context, service, child) {
          final state = service.connectionState;
          final isBusy =
              state == HeartRateConnectionState.scanning ||
              state == HeartRateConnectionState.connecting;

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      state == HeartRateConnectionState.connected
                          ? Icons.favorite
                          : Icons.favorite_border,
                      color: state == HeartRateConnectionState.connected
                          ? Colors.redAccent
                          : Colors.white54,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _statusLabel(state),
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    if (isBusy) ...[
                      const SizedBox(width: 12),
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: StreamBuilder<List<DiscoveredDevice>>(
                  initialData: service.discoveredDevicesSnapshot,
                  stream: service.discoveredDevices,
                  builder: (context, snapshot) {
                    final devices = snapshot.data ?? const <DiscoveredDevice>[];
                    if (devices.isEmpty) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text(
                            'لم يتم العثور على أي جهاز بعد.\n'
                            'تأكد من تفعيل بث نبض القلب على جهازك.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white54),
                          ),
                        ),
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: devices.length,
                      itemBuilder: (context, index) {
                        final device = devices[index];
                        final isConnectedDevice =
                            service.connectedDeviceId == device.id &&
                            state == HeartRateConnectionState.connected;
                        return Card(
                          color: Colors.white10,
                          margin: const EdgeInsets.only(bottom: 12),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            title: Text(
                              device.name.isEmpty ? device.id : device.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              'RSSI: ${device.rssi}',
                              style: const TextStyle(color: Colors.white54),
                            ),
                            trailing: isConnectedDevice
                                ? const Icon(
                                    Icons.check_circle,
                                    color: Colors.greenAccent,
                                  )
                                : ElevatedButton(
                                    onPressed: () => service.connect(device.id),
                                    child: const Text('اتصال'),
                                  ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

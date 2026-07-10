import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/map_tile_service.dart';

/// Lets the user pre-download Baghdad-area map tiles for offline use.
/// Entirely optional — GPS tracking (Phase 1) works without ever visiting
/// this screen; tiles are also cached opportunistically as they are viewed.
class DownloadMapScreen extends StatefulWidget {
  const DownloadMapScreen({super.key});

  @override
  State<DownloadMapScreen> createState() => _DownloadMapScreenState();
}

class _DownloadMapScreenState extends State<DownloadMapScreen> {
  double _progress = 0;
  bool _isDownloading = false;
  bool _isComplete = false;
  String? _errorMessage;

  Future<void> _startDownload() async {
    final tileService = context.read<MapTileService>();
    setState(() {
      _isDownloading = true;
      _isComplete = false;
      _errorMessage = null;
      _progress = 0;
    });

    try {
      await tileService.downloadBaghdadRegion(
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _isComplete = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _errorMessage =
            'تعذر إكمال التحميل. تحقق من اتصال الإنترنت وحاول مجدداً';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tileService = context.watch<MapTileService>();
    final estimatedTiles = tileService.estimatedTileCount;
    final estimatedMb = (estimatedTiles * 15 / 1024).round();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('تحميل الخريطة للاستخدام دون اتصال'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              const Icon(Icons.map_outlined, color: Colors.white54, size: 72),
              const SizedBox(height: 24),
              const Text(
                'لاستخدام الخريطة أثناء ركوب الدراجة بدون إنترنت، يجب تحميل '
                'بلاطات خريطة بغداد والمناطق المحيطة بها مرة واحدة فقط. '
                'بعد التحميل، ستعمل الخريطة أثناء التتبع حتى بدون اتصال '
                'بالإنترنت.',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'العدد التقريبي للبلاطات: $estimatedTiles '
                '(~$estimatedMb ميجابايت تقريباً)',
                style: const TextStyle(color: Colors.white38, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              if (_isDownloading) ...[
                LinearProgressIndicator(
                  value: _progress,
                  minHeight: 10,
                  backgroundColor: Colors.white12,
                  color: Colors.green,
                ),
                const SizedBox(height: 12),
                Text(
                  '${(_progress * 100).toStringAsFixed(0)}٪',
                  style: const TextStyle(color: Colors.white, fontSize: 20),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
              ],
              if (_isComplete)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(
                    'تم تحميل الخريطة بنجاح',
                    style: TextStyle(color: Colors.greenAccent, fontSize: 18),
                    textAlign: TextAlign.center,
                  ),
                ),
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 15,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ElevatedButton(
                onPressed: _isDownloading ? null : _startDownload,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  textStyle: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                child: Text(_isComplete ? 'إعادة التحميل' : 'تحميل الخريطة'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

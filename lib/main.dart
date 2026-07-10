import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'screens/tracking_screen.dart';
import 'services/heart_rate_service.dart';
import 'services/map_tile_service.dart';
import 'services/ride_repository.dart';
import 'services/ride_tracker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final mapTileService = MapTileService();
  await mapTileService.init();

  final heartRateService = HeartRateService();

  runApp(
    MyApp(mapTileService: mapTileService, heartRateService: heartRateService),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    required this.mapTileService,
    required this.heartRateService,
  });

  final MapTileService mapTileService;
  final HeartRateService heartRateService;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<HeartRateService>.value(value: heartRateService),
        ChangeNotifierProvider<RideTracker>(
          create: (_) => RideTracker(heartRateService: heartRateService),
        ),
        Provider<RideRepository>(create: (_) => RideRepository()),
        Provider<MapTileService>.value(value: mapTileService),
      ],
      child: MaterialApp(
        title: 'ركوب الدراجات في العراق',
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar'),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('ar')],
        theme: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.green,
            brightness: Brightness.dark,
          ),
        ),
        home: const TrackingScreen(),
      ),
    );
  }
}

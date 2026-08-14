import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'screens/tracking_screen.dart';
import 'services/app_database.dart';
import 'services/hazard_repository.dart';
import 'services/heart_rate_service.dart';
import 'services/map_tile_service.dart';
import 'services/place_search_service.dart';
import 'services/ride_repository.dart';
import 'services/ride_tracker.dart';
import 'services/route_finder.dart';
import 'services/routing_graph_seeder.dart';
import 'services/user_profile_repository.dart';
import 'services/voice_alert_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final mapTileService = MapTileService();
  await mapTileService.init();

  final appDatabase = await openAppDatabase();
  await RoutingGraphSeeder().seedIfNeeded(appDatabase);

  final heartRateService = HeartRateService();

  final userProfileRepository = UserProfileRepository();
  await userProfileRepository.load();

  final hazardRepository = HazardRepository();
  final voiceAlertService = VoiceAlertService();

  runApp(
    MyApp(
      mapTileService: mapTileService,
      heartRateService: heartRateService,
      userProfileRepository: userProfileRepository,
      hazardRepository: hazardRepository,
      voiceAlertService: voiceAlertService,
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    required this.mapTileService,
    required this.heartRateService,
    required this.userProfileRepository,
    required this.hazardRepository,
    required this.voiceAlertService,
  });

  final MapTileService mapTileService;
  final HeartRateService heartRateService;
  final UserProfileRepository userProfileRepository;
  final HazardRepository hazardRepository;
  final VoiceAlertService voiceAlertService;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<HeartRateService>.value(value: heartRateService),
        ChangeNotifierProvider<RideTracker>(
          create: (_) => RideTracker(
            heartRateService: heartRateService,
            userProfileRepository: userProfileRepository,
            hazardRepository: hazardRepository,
            voiceAlertService: voiceAlertService,
          ),
        ),
        Provider<RideRepository>(create: (_) => RideRepository()),
        ChangeNotifierProvider<MapTileService>.value(value: mapTileService),
        Provider<UserProfileRepository>.value(value: userProfileRepository),
        Provider<HazardRepository>.value(value: hazardRepository),
        Provider<RouteFinder>(create: (_) => RouteFinder()),
        Provider<PlaceSearchService>(create: (_) => PlaceSearchService()),
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

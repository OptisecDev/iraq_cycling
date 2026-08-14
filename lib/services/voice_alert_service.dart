import 'package:flutter_tts/flutter_tts.dart';

/// The subset of FlutterTts's API used by [VoiceAlertService], extracted as
/// an interface so tests can inject a no-op fake instead of constructing a
/// real `FlutterTts()` — the real class talks to a platform channel that
/// isn't available in a test VM.
abstract class TtsClient {
  Future<void> setLanguage(String language);
  Future<void> speak(String text);
}

class FlutterTtsClient implements TtsClient {
  final _tts = FlutterTts();

  @override
  Future<void> setLanguage(String language) async {
    await _tts.setLanguage(language);
  }

  @override
  Future<void> speak(String text) async {
    await _tts.speak(text);
  }
}

/// Speaks short Arabic hazard warnings aloud via the device's offline
/// text-to-speech engine. Entirely optional to the rest of the app: a ride
/// tracks and saves fine with no hazards defined and nothing spoken.
class VoiceAlertService {
  VoiceAlertService({TtsClient? ttsClient})
    : _tts = ttsClient ?? FlutterTtsClient() {
    // Fire-and-forget: language setup shouldn't block construction, and a
    // failure here (e.g. no Arabic voice installed) shouldn't crash the
    // app — speak() calls will just be silently ignored by the OS engine.
    _tts.setLanguage('ar');
  }

  final TtsClient _tts;

  Future<void> announce(String message) => _tts.speak(message);
}

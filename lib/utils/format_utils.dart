/// Formats a [Duration] as `HH:MM:SS`, shared by the live tracking screen and
/// the ride history/detail screens so ride durations are shown identically.
String formatDuration(Duration duration) {
  final hours = duration.inHours.toString().padLeft(2, '0');
  final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}

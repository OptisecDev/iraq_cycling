/// Fallback weight/age used when no rider profile has been saved yet (see
/// [UserProfileRepository]/[ProfileScreen]) — a ride calculated before that
/// silently assumes a 70kg, 30-year-old rider unless real values are
/// supplied, via [resolveWeightKg]/[resolveAgeYears] below.
const double placeholderWeightKg = 70.0;
const int placeholderAgeYears = 30;

enum Gender { male, female }

/// Resolves the weight to use for a calorie calculation: a saved profile
/// value if one exists, otherwise the documented placeholder above.
double resolveWeightKg(double? profileWeightKg) =>
    profileWeightKg ?? placeholderWeightKg;

/// Resolves the age to use for a calorie calculation: a saved profile value
/// if one exists, otherwise the documented placeholder above.
int resolveAgeYears(int? profileAgeYears) =>
    profileAgeYears ?? placeholderAgeYears;

/// Resolves the gender to use for a calorie calculation: a saved profile
/// value if one exists, otherwise the same male default the Keytel formula
/// always used before a profile had a gender field.
Gender resolveGender(Gender? profileGender) => profileGender ?? Gender.male;

/// The Keytel et al. (2005) HR-based kcal/min rate, factored out of
/// [estimateCaloriesBurned] so a live per-sample accumulator (see
/// [LiveCalorieAccumulator]) can reuse the exact same formula instead of
/// duplicating it.
///
/// Negative regression output (possible at very low HR) is floored at zero,
/// same rationale as [estimateCaloriesBurned]'s end-of-ride clamp.
double caloriesPerMinuteFromHeartRate({
  required num heartRateBpm,
  required double weightKg,
  required int ageYears,
  required Gender gender,
}) {
  final kJPerMinute = gender == Gender.male
      ? -55.0969 +
            (0.6309 * heartRateBpm) +
            (0.1988 * weightKg) +
            (0.2017 * ageYears)
      : -20.4022 +
            (0.4472 * heartRateBpm) -
            (0.1263 * weightKg) +
            (0.074 * ageYears);
  final kcalPerMinute = kJPerMinute / 4.184;
  return kcalPerMinute < 0 ? 0 : kcalPerMinute;
}

/// Estimates calories burned for a ride.
///
/// When [avgHeartRate] is available, uses the Keytel et al. (2005) HR-based
/// regression formula ("Prediction of energy expenditure from heart rate
/// monitoring during submaximal exercise", Journal of Sports Sciences,
/// 23(3), 289-297) — a standard, widely cited formula for HR-based calorie
/// estimation:
///
///   male:   ((-55.0969 + 0.6309·HR + 0.1988·W + 0.2017·A) / 4.184) · T
///   female: ((-20.4022 + 0.4472·HR - 0.1263·W + 0.074·A)  / 4.184) · T
///
/// where HR = average heart rate (bpm), W = weight (kg), A = age (years),
/// T = duration (minutes). Division by 4.184 converts kJ/min to kcal/min.
///
/// When [avgHeartRate] is null (no heart rate sensor was connected), falls
/// back to a standard MET-based estimate using average speed to pick a MET
/// value from the Compendium of Physical Activities cycling table (Ainsworth
/// et al.), then: calories = MET · weight(kg) · duration(hours).
double estimateCaloriesBurned({
  required Duration duration,
  double? avgHeartRate,
  double avgSpeedKmh = 0,
  double weightKg = placeholderWeightKg,
  int ageYears = placeholderAgeYears,
  Gender gender = Gender.male,
}) {
  final durationMinutes = duration.inSeconds / 60;
  if (durationMinutes <= 0) return 0;

  if (avgHeartRate != null) {
    final kcalPerMinute = caloriesPerMinuteFromHeartRate(
      heartRateBpm: avgHeartRate,
      weightKg: weightKg,
      ageYears: ageYears,
      gender: gender,
    );
    return kcalPerMinute * durationMinutes;
  }

  final met = _cyclingMetFromSpeed(avgSpeedKmh);
  final durationHours = durationMinutes / 60;
  return met * weightKg * durationHours;
}

/// Cycling MET values from the Compendium of Physical Activities, bucketed
/// by average speed. ~8.0 METs ("moderate effort, 19-22 km/h" bucket per
/// the compendium) is the standard middle-of-the-road value used when speed
/// is unknown or falls in the general moderate-pace range.
double _cyclingMetFromSpeed(double avgSpeedKmh) {
  if (avgSpeedKmh < 16) return 4.0;
  if (avgSpeedKmh < 19) return 8.0;
  if (avgSpeedKmh < 22) return 10.0;
  if (avgSpeedKmh < 25) return 12.0;
  return 15.8;
}

/// Accumulates a running calorie total from live BLE heart rate samples
/// during an active ride, using [caloriesPerMinuteFromHeartRate] for each
/// inter-sample gap — separate from [estimateCaloriesBurned], which computes
/// a single end-of-ride total from the ride's average HR and stays the
/// source of truth for the persisted `Ride.caloriesBurned` value.
class LiveCalorieAccumulator {
  LiveCalorieAccumulator({
    required this.weightKg,
    required this.ageYears,
    required this.gender,
  });

  final double weightKg;
  final int ageYears;
  final Gender gender;

  static const _minValidBpm = 40;
  static const _maxValidBpm = 220;
  // A gap this long between samples almost always means a BLE reconnection
  // (e.g. the GATT status=147 timeout documented in PROJECT_STATE.md), not
  // continuous exertion — charging the full gap at the last known HR would
  // inflate the total, so it's capped here instead.
  static const _maxGapBetweenSamples = Duration(minutes: 2);

  double _totalCalories = 0;
  DateTime? _lastSampleAt;

  double get totalCalories => _totalCalories;

  /// Folds one heart rate reading into the running total. Readings outside
  /// [_minValidBpm]-[_maxValidBpm] are sensor glitches and are dropped, but
  /// still move the gap anchor forward so a later valid reading isn't
  /// charged for the glitchy period too.
  void addSample(int heartRateBpm, {DateTime? timestamp}) {
    final now = timestamp ?? DateTime.now();
    final lastSampleAt = _lastSampleAt;
    _lastSampleAt = now;

    if (heartRateBpm < _minValidBpm || heartRateBpm > _maxValidBpm) return;
    if (lastSampleAt == null) return;

    var elapsed = now.difference(lastSampleAt);
    if (elapsed.isNegative) return;
    if (elapsed > _maxGapBetweenSamples) elapsed = _maxGapBetweenSamples;

    final kcalPerMinute = caloriesPerMinuteFromHeartRate(
      heartRateBpm: heartRateBpm,
      weightKg: weightKg,
      ageYears: ageYears,
      gender: gender,
    );
    _totalCalories += kcalPerMinute * (elapsed.inMilliseconds / 60000);
  }

  void reset() {
    _totalCalories = 0;
    _lastSampleAt = null;
  }
}

/// TODO(user-profile): weight/age below are hardcoded placeholders because
/// the app has no user profile/settings screen yet (a future phase). Every
/// ride calculated in this phase silently assumes a 70kg, 30-year-old rider
/// unless real values are supplied — flagged here, not hidden.
const double placeholderWeightKg = 70.0;
const int placeholderAgeYears = 30;

enum Gender { male, female }

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
    final kJPerMinute = gender == Gender.male
        ? -55.0969 +
              (0.6309 * avgHeartRate) +
              (0.1988 * weightKg) +
              (0.2017 * ageYears)
        : -20.4022 +
              (0.4472 * avgHeartRate) -
              (0.1263 * weightKg) +
              (0.074 * ageYears);
    final kcalPerMinute = kJPerMinute / 4.184;
    final totalKcal = kcalPerMinute * durationMinutes;
    // A negative regression output (possible at very low HR/short rides)
    // isn't a plausible calorie burn — floor at zero rather than reporting
    // negative calories.
    return totalKcal < 0 ? 0 : totalKcal;
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

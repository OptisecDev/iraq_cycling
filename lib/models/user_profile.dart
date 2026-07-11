import '../utils/calorie_calculator.dart' show Gender;

enum PreferredUnit { km, miles }

/// Rider profile used to personalize calorie estimates and unit display.
///
/// Defaults (70kg, 30yo, male) intentionally match the placeholder constants
/// in `calorie_calculator.dart` — before a profile is ever saved,
/// calculations behave exactly as they did before this model existed.
class UserProfile {
  const UserProfile({
    this.name = '',
    this.weightKg = 70,
    this.age = 30,
    this.gender = Gender.male,
    this.preferredUnit = PreferredUnit.km,
  });

  final String name;
  final double weightKg;
  final int age;
  final Gender gender;
  final PreferredUnit preferredUnit;

  Map<String, dynamic> toMap() {
    return {
      'id': 1,
      'name': name,
      'weight_kg': weightKg,
      'age_years': age,
      'gender': gender.name,
      'preferred_unit': preferredUnit.name,
    };
  }

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    return UserProfile(
      name: map['name'] as String? ?? '',
      weightKg: (map['weight_kg'] as num?)?.toDouble() ?? 70,
      age: map['age_years'] as int? ?? 30,
      gender: Gender.values.firstWhere(
        (g) => g.name == map['gender'],
        orElse: () => Gender.male,
      ),
      preferredUnit: PreferredUnit.values.firstWhere(
        (unit) => unit.name == map['preferred_unit'],
        orElse: () => PreferredUnit.km,
      ),
    );
  }

  UserProfile copyWith({
    String? name,
    double? weightKg,
    int? age,
    Gender? gender,
    PreferredUnit? preferredUnit,
  }) {
    return UserProfile(
      name: name ?? this.name,
      weightKg: weightKg ?? this.weightKg,
      age: age ?? this.age,
      gender: gender ?? this.gender,
      preferredUnit: preferredUnit ?? this.preferredUnit,
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/ride.dart';
import '../models/user_profile.dart';
import '../services/heart_rate_service.dart';
import '../services/ride_repository.dart';
import '../services/user_profile_repository.dart';
import '../utils/calorie_calculator.dart' show Gender;
import '../widgets/stat_column.dart';

/// Editable rider profile (name/weight/age/preferred unit), plus read-only
/// lifetime stats and BLE connection status. Weight/age feed
/// calorie_calculator.dart via RideTracker; nothing else in the app is
/// wired to preferredUnit yet (still km-only display — see PROJECT_STATE.md).
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _weightController;
  late final TextEditingController _ageController;
  late Gender _gender;
  late PreferredUnit _preferredUnit;

  @override
  void initState() {
    super.initState();
    // Populated synchronously: main.dart already awaits
    // UserProfileRepository.load() before the app is shown, so `current`
    // reflects the saved profile (or its defaults) from the first frame.
    final profile = context.read<UserProfileRepository>().current;
    _nameController = TextEditingController(text: profile.name);
    _weightController = TextEditingController(
      text: profile.weightKg.toStringAsFixed(0),
    );
    _ageController = TextEditingController(text: profile.age.toString());
    _gender = profile.gender;
    _preferredUnit = profile.preferredUnit;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _weightController.dispose();
    _ageController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final weightKg = double.tryParse(_weightController.text.trim());
    final age = int.tryParse(_ageController.text.trim());

    if (weightKg == null || weightKg <= 0 || age == null || age <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرجاء إدخال وزن وعمر صحيحين')),
      );
      return;
    }

    final repository = context.read<UserProfileRepository>();
    await repository.save(
      UserProfile(
        name: _nameController.text.trim(),
        weightKg: weightKg,
        age: age,
        gender: _gender,
        preferredUnit: _preferredUnit,
      ),
    );

    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('تم حفظ الملف الشخصي')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text('الملف الشخصي'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildBleStatus(context),
              const SizedBox(height: 24),
              const Text(
                'البيانات الشخصية',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              _buildTextField(
                controller: _nameController,
                label: 'الاسم',
                keyboardType: TextInputType.text,
              ),
              const SizedBox(height: 16),
              _buildTextField(
                controller: _weightController,
                label: 'الوزن (كغم)',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
                ],
              ),
              const SizedBox(height: 16),
              _buildTextField(
                controller: _ageController,
                label: 'العمر',
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              const SizedBox(height: 16),
              const Text(
                'الجنس',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
              const SizedBox(height: 8),
              SegmentedButton<Gender>(
                segments: const [
                  ButtonSegment(value: Gender.male, label: Text('ذكر')),
                  ButtonSegment(value: Gender.female, label: Text('أنثى')),
                ],
                selected: {_gender},
                onSelectionChanged: (selection) =>
                    setState(() => _gender = selection.first),
              ),
              const SizedBox(height: 16),
              const Text(
                'وحدة القياس المفضّلة',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
              const SizedBox(height: 8),
              SegmentedButton<PreferredUnit>(
                segments: const [
                  ButtonSegment(value: PreferredUnit.km, label: Text('كم')),
                  ButtonSegment(value: PreferredUnit.miles, label: Text('ميل')),
                ],
                selected: {_preferredUnit},
                onSelectionChanged: (selection) =>
                    setState(() => _preferredUnit = selection.first),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  textStyle: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                child: const Text('حفظ'),
              ),
              const SizedBox(height: 32),
              const Text(
                'إحصائيات عامة',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              _buildLifetimeStats(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBleStatus(BuildContext context) {
    return Consumer<HeartRateService>(
      builder: (context, heartRateService, child) {
        final connected =
            heartRateService.connectionState ==
            HeartRateConnectionState.connected;
        return Row(
          children: [
            Icon(
              connected ? Icons.favorite : Icons.favorite_border,
              color: connected ? Colors.redAccent : Colors.white54,
            ),
            const SizedBox(width: 8),
            Text(
              connected ? 'حزام نبض القلب متصل' : 'حزام نبض القلب غير متصل',
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required TextInputType keyboardType,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white54),
        enabledBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: Colors.white24),
        ),
        focusedBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: Colors.green),
        ),
      ),
    );
  }

  Widget _buildLifetimeStats(BuildContext context) {
    final repository = context.read<RideRepository>();
    return FutureBuilder<List<Ride>>(
      future: repository.getAllRidesSummary(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }

        final rides = snapshot.data ?? const <Ride>[];
        final totalDistanceKm = rides.fold<double>(
          0,
          (sum, ride) => sum + ride.totalDistanceKm,
        );
        final ridesWithMaxHeartRate = rides
            .where((ride) => ride.maxHeartRate != null)
            .toList();
        final highestMaxHeartRate = ridesWithMaxHeartRate.isEmpty
            ? null
            : ridesWithMaxHeartRate
                  .map((ride) => ride.maxHeartRate!)
                  .reduce((a, b) => a > b ? a : b);

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            StatColumn(
              label: 'إجمالي المسافة (كم)',
              value: totalDistanceKm.toStringAsFixed(1),
            ),
            StatColumn(label: 'عدد الرحلات', value: rides.length.toString()),
            StatColumn(
              label: 'أعلى نبض قلب مسجل',
              value: highestMaxHeartRate?.toStringAsFixed(0) ?? '--',
            ),
          ],
        );
      },
    );
  }
}

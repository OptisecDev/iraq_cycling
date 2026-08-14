import 'package:flutter/material.dart';

/// A labelled stat value (e.g. distance, duration), shared across the live
/// tracking screen (including its floating map HUD), the past-ride detail
/// screen, and the profile screen's lifetime stats, so they all present
/// stats identically.
class StatColumn extends StatelessWidget {
  const StatColumn({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 14, color: Colors.white54),
        ),
      ],
    );
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:iraq_cycling/utils/arabic_text.dart';

void main() {
  group('normalizeArabic', () {
    test('strips tashkeel/diacritics', () {
      expect(normalizeArabic('شَارِعُ الرَّشِيدِ'), 'شارع الرشيد');
    });

    test('folds alef variants (أ إ آ) to bare alef', () {
      expect(normalizeArabic('أحمد'), normalizeArabic('احمد'));
      expect(normalizeArabic('إحمد'), normalizeArabic('احمد'));
      expect(normalizeArabic('آحمد'), normalizeArabic('احمد'));
    });

    test('folds taa marbuta (ة) to haa (ه)', () {
      expect(normalizeArabic('قرية'), 'قريه');
    });

    test('folds alef maksura (ى) to yeh (ي)', () {
      expect(normalizeArabic('مصطفى'), 'مصطفي');
    });

    test('collapses repeated whitespace and trims', () {
      expect(normalizeArabic('  اسم  فيه   مسافات  '), 'اسم فيه مسافات');
    });

    test('lowercases mixed Latin text (e.g. street refs)', () {
      expect(normalizeArabic('Highway M5'), 'highway m5');
    });

    test('empty string stays empty', () {
      expect(normalizeArabic(''), '');
    });

    test('a query and its indexed target normalize to the same string', () {
      // Matches the exact scenario this exists for: build_routing_graph.py
      // indexes "شارع الرَّشيد" (with tashkeel, as OSM sometimes tags it),
      // a user searches "الرشيد" without any diacritics at all.
      final indexed = normalizeArabic('شارع الرَّشيد');
      final query = normalizeArabic('الرشيد');
      expect(indexed.contains(query), isTrue);
    });
  });
}

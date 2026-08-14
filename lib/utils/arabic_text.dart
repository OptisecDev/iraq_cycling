/// Normalizes Arabic text for loose search matching: strips diacritics and
/// tatweel, and folds alef/alef-maksura/taa-marbuta variants down to one
/// form each, since Baghdad street names are tagged inconsistently across
/// these forms in OSM.
///
/// Mirrors `normalize_arabic_name()` in
/// `tool/routing_import/build_routing_graph.py` exactly - that function
/// normalizes `place_names.name_normalized` at index-build time, this one
/// normalizes the user's query at search time, so the two must stay in
/// sync or matches will silently miss.
library;

// Tashkeel/diacritics (U+064B-U+065F, U+0670) + tatweel/kashida (U+0640).
final RegExp _arabicDiacritics = RegExp(r'[\u064B-\u065F\u0670\u0640]');

// Alef variants (\u0623 \u0625 \u0622 \u0671) -> bare alef (\u0627),
// alef maksura (\u0649) -> yeh (\u064A), taa marbuta (\u0629) -> haa (\u0647).
const Map<String, String> _arabicCharMap = {
  '\u0623': '\u0627',
  '\u0625': '\u0627',
  '\u0622': '\u0627',
  '\u0671': '\u0627',
  '\u0649': '\u064A',
  '\u0629': '\u0647',
};

String normalizeArabic(String text) {
  final stripped = text.replaceAll(_arabicDiacritics, '');
  final buffer = StringBuffer();
  for (final rune in stripped.runes) {
    final char = String.fromCharCode(rune);
    buffer.write(_arabicCharMap[char] ?? char);
  }
  return buffer
      .toString()
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ')
      .toLowerCase();
}

/// Search support for the app catalog.
///
/// A keystroke never re-normalizes every name: the catalog is reduced once to
/// [SearchKeys] — flattened name, word list, acronym — and queries are scored
/// against those keys. Matching is deliberately fuzzy: exact, prefix of the
/// name, start of any word, acronym ("vsc" → Visual Studio Code), substring,
/// words in any order, and finally a gapped subsequence ("vscode" and
/// "phtshp" → Photoshop).
library;

/// A query reduced to its searchable form.
class SearchQuery {
  SearchQuery._(this.words, this.flat);

  factory SearchQuery(String raw) {
    final words = _splitWords(raw);
    return SearchQuery._(words, words.join());
  }

  /// Lower-cased words with separators and punctuation stripped.
  final List<String> words;

  /// All words glued together — what prefix/substring/acronym tests use.
  final String flat;

  bool get isEmpty => flat.isEmpty;
}

/// Precomputed search keys for one app name.
class SearchKeys {
  SearchKeys._(this.flat, this.words, this.acronym);

  factory SearchKeys.of(String name) {
    final words = _splitWords(name);
    final acronym = StringBuffer();
    for (final word in words) {
      if (word.isNotEmpty) acronym.writeCharCode(word.runes.first);
    }
    return SearchKeys._(words.join(), words, acronym.toString());
  }

  final String flat;
  final List<String> words;
  final String acronym;

  static const _exact = 1000;
  static const _prefix = 860;
  static const _wordStart = 800;
  static const _acronymExact = 770;
  static const _acronymPrefix = 730;
  static const _substring = 700;
  static const _allWords = 560;
  static const _subsequence = 500;
  static const _subsequenceFloor = 220;
  static const _gapPenalty = 8;

  /// How well this name matches [query], or null when it does not. Higher
  /// scores are better; the tiers are ordered so a real substring always beats
  /// an acronym hit, which always beats a scattered subsequence.
  int? score(SearchQuery query) {
    final q = query.flat;
    if (q.isEmpty) return null;
    if (flat == q) return _exact;
    if (flat.startsWith(q)) return _prefix - _extra(flat, q, 60);
    for (final word in words) {
      if (word.startsWith(q)) return _wordStart - _extra(flat, q, 40);
    }
    if (acronym == q) return _acronymExact;
    if (acronym.startsWith(q)) return _acronymPrefix;
    final at = flat.indexOf(q);
    if (at >= 0) return _substring - at;
    if (query.words.length > 1 && query.words.every(flat.contains)) {
      return _allWords;
    }
    if (q.length >= 2) {
      final gaps = _gaps(flat, q);
      if (gaps != null) {
        final score = _subsequence - gaps * _gapPenalty;
        if (score >= _subsequenceFloor) return score;
      }
    }
    return null;
  }

  /// Longer names rank below shorter ones for the same kind of hit.
  static int _extra(String name, String query, int cap) {
    final extra = name.length - query.length;
    return extra > cap ? cap : extra;
  }
}

/// The searchable catalog: one [SearchKeys] per app, in app order.
class AppSearchIndex {
  AppSearchIndex(this._keys);

  AppSearchIndex.empty() : _keys = const [];

  final List<SearchKeys> _keys;

  int get length => _keys.length;

  /// Matching app indices as (index, score), best score first.
  List<(int, int)> search(SearchQuery query) {
    final hits = score(query);
    hits.sort((a, b) => b.$2.compareTo(a.$2));
    return hits;
  }

  /// The same matches, in catalog order — no ranking sort. Callers that rank
  /// the hits themselves (usage first, then name) do not need it, and the
  /// catalog-order pass is the only thing a keystroke really has to pay for.
  List<(int, int)> score(SearchQuery query) {
    final hits = <(int, int)>[];
    if (query.isEmpty) return hits;
    for (var i = 0; i < _keys.length; i++) {
      final score = _keys[i].score(query);
      if (score != null) hits.add((i, score));
    }
    return hits;
  }
}

/// Incremental builder: the provider feeds names in time slices so a huge
/// catalog never blocks a frame and can report progress as it goes.
class AppSearchIndexBuilder {
  final List<SearchKeys> _keys = [];

  int get length => _keys.length;

  void add(String name) => _keys.add(SearchKeys.of(name));

  AppSearchIndex build() => AppSearchIndex(List.unmodifiable(_keys));
}

/// Whole-catalog convenience for tests and small lists.
AppSearchIndex buildSearchIndex(Iterable<String> names) {
  final builder = AppSearchIndexBuilder();
  for (final name in names) {
    builder.add(name);
  }
  return builder.build();
}

/// Splits on separators and punctuation, lower-cases, and folds full-width
/// forms to ASCII so "７－Ｚｉｐ" and "7-Zip" produce the same keys.
List<String> _splitWords(String text) {
  final words = <String>[];
  final buffer = StringBuffer();
  void flush() {
    if (buffer.isNotEmpty) {
      words.add(buffer.toString());
      buffer.clear();
    }
  }

  for (var rune in text.toLowerCase().runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) rune -= 0xFEE0; // 全角 → 半角
    if (_isWordRune(rune)) {
      buffer.writeCharCode(rune);
    } else {
      flush();
    }
  }
  flush();
  return words;
}

bool _isWordRune(int rune) {
  if (rune >= 0x30 && rune <= 0x39) return true; // 0-9
  if (rune >= 0x61 && rune <= 0x7A) return true; // a-z
  if (rune < 0x80) return false; // remaining ASCII: space and punctuation
  return !_isPunctuation(rune);
}

bool _isPunctuation(int rune) =>
    (rune >= 0x3000 && rune <= 0x303F) || // CJK 符号和标点
    (rune >= 0xFE30 && rune <= 0xFE4F) || // CJK 兼容形式
    (rune >= 0xFF5F && rune <= 0xFF65) || // 全角括号等（其余全角已折算）
    const {0x00B7, 0x2013, 0x2014, 0x2015, 0x2018, 0x2019, 0x201C, 0x201D,
      0x2026}.contains(rune);

/// Characters skipped when matching [needle] as a subsequence of [haystack],
/// or null when it is not a subsequence at all.
int? _gaps(String haystack, String needle) {
  var cursor = 0;
  var gaps = 0;
  var previous = -1;
  for (var i = 0; i < needle.length; i++) {
    final target = needle.codeUnitAt(i);
    var found = -1;
    while (cursor < haystack.length) {
      if (haystack.codeUnitAt(cursor) == target) {
        found = cursor;
        cursor++;
        break;
      }
      cursor++;
    }
    if (found < 0) return null;
    if (previous >= 0) gaps += found - previous - 1;
    previous = found;
  }
  return gaps;
}

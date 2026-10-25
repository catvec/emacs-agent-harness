/// The lines a person searched with the quick search, newest first, for the
/// life of the app (`harness-quick-search-history` in the harness's Emacs).
/// A searching person brings one back to refine it; nothing is written to
/// disk.
class QuickSearchHistory {
  /// How many lines are kept.
  static const capacity = 30;

  final List<String> _lines = <String>[];

  /// The lines searched, the latest first.
  List<String> get lines => List.unmodifiable(_lines);

  bool get isEmpty => _lines.isEmpty;

  /// Remember [line] as the latest.  A line searched before moves to the
  /// front instead of standing twice.
  void add(String line) {
    final text = line.trim();
    if (text.isEmpty) return;
    _lines.remove(text);
    _lines.insert(0, text);
    if (_lines.length > capacity) _lines.removeRange(capacity, _lines.length);
  }

  void clear() => _lines.clear();
}

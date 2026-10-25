import 'package:flutter/widgets.dart';

/// The way into the quick search, handed down to the pages that offer it.  A
/// `HarnessPage` puts a search button at the end of its header when there is
/// one above it, so that every page of the app, whatever it is about, has the
/// same button in the same place, and the home shell, which knows what is
/// open and how to go anywhere, is the only one that opens the search.
class QuickSearchEntry extends InheritedWidget {
  const QuickSearchEntry({super.key, required this.open, required super.child});

  /// What the button of the header is called, to a screen reader and in a
  /// test.
  static const buttonLabel = 'Quick search';

  /// The key of that button.
  static const buttonKey = Key('quick-search-button');

  /// Open the quick search, from the page that offers it.
  final VoidCallback open;

  static QuickSearchEntry? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<QuickSearchEntry>();

  @override
  bool updateShouldNotify(QuickSearchEntry oldWidget) => oldWidget.open != open;
}

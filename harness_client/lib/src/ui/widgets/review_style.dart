import 'package:flutter/material.dart';

import '../../models/review.dart';
import '../theme/harness_theme.dart';

/// The colours of a review, beyond the palette: an addition reads as a
/// change whether it is tinted or not (its `+` and its line number say so),
/// and a deletion as a deletion.  Everything is derived from the theme, so
/// the light and the dark theme both read.
class ReviewStyle {
  const ReviewStyle._();

  static bool _dark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color additionTint(BuildContext context) =>
      HarnessColors.moss.withValues(alpha: _dark(context) ? 0.16 : 0.14);

  static Color deletionTint(BuildContext context) =>
      Theme.of(context).colorScheme.error
          .withValues(alpha: _dark(context) ? 0.14 : 0.11);

  static Color additionInk(BuildContext context) =>
      _dark(context) ? const Color(0xFF7FE0B6) : const Color(0xFF1D6B4C);

  static Color deletionInk(BuildContext context) =>
      _dark(context) ? const Color(0xFFFF9E95) : const Color(0xFFA5322A);

  static Color hunkTint(BuildContext context) =>
      Theme.of(context).colorScheme.surfaceContainerHigh
          .withValues(alpha: 0.55);

  static Color gutterInk(BuildContext context) =>
      Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7);

  static Color gutterBackground(BuildContext context) =>
      Theme.of(context).colorScheme.surfaceContainerHigh
          .withValues(alpha: _dark(context) ? 0.45 : 0.35);

  static Color selectionTint(BuildContext context) =>
      Theme.of(context).colorScheme.primary.withValues(alpha: 0.16);

  /// The colour a thread's state is written in: open is the accent, closed
  /// is quiet, and "to review" is the caution the harness uses for work
  /// waiting on the person.
  static Color threadColor(BuildContext context, ReviewThread thread) {
    final theme = Theme.of(context);
    if (thread.isOpen) return theme.colorScheme.primary;
    if (thread.toReview) return HarnessColors.amber;
    return theme.colorScheme.onSurfaceVariant;
  }

  static String threadLabel(ReviewThread thread) {
    if (thread.isDraftsOnly) return 'Draft';
    if (thread.isOpen) return 'Open';
    if (thread.toReview) return 'To review';
    return 'Closed';
  }

  /// The status letter of a file, in the colour that says what happened to
  /// it.  The letter itself is the readable mark: colour is never alone.
  static Color fileColor(BuildContext context, ChangedFile file) =>
      switch (file.status) {
        'A' => HarnessColors.moss,
        'D' => Theme.of(context).colorScheme.error,
        'R' || 'C' => HarnessColors.oxide,
        'T' => HarnessColors.amber,
        _ => Theme.of(context).colorScheme.onSurfaceVariant,
      };

  static Color fileTint(BuildContext context, ChangedFile file) =>
      fileColor(context, file).withValues(alpha: _dark(context) ? 0.16 : 0.12);
}

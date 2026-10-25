import 'package:flutter/material.dart';

import '../../models/transcript.dart';
import '../adaptive/adaptive_widgets.dart';
import '../theme/harness_theme.dart';

/// A compaction's note, with the button that takes the compaction back under
/// it.
///
/// Nothing a compaction replaced is deleted, so the latest one can be taken
/// back and made again, like undo and redo: "Revert" gives the model the
/// conversation before the compaction again, in place of its summary, and
/// then "Go post-compaction" gives it the summary again, as often as the
/// person likes.  The harness does it (`compaction/revert`,
/// `compaction/restore`), marks the compaction's node and announces it again,
/// so what is drawn here follows the node ([TranscriptItem.isRevertedCompaction]):
/// the button changes by itself once the harness has done it, and a refusal
/// (while a turn or a compaction runs) shows as an error where the person is
/// looking.
///
/// The note is the transcript's own ([note], however it is drawn): this only
/// stands what belongs to the toggle around it.  A compaction that is
/// reverted -- the latest, or an older one that was reverted when the next
/// was made -- is drawn dimmed, as what the model is no longer sent, and says
/// so.  [onToggle] is null for a compaction that has no button: an older one,
/// one made to hand the conversation over to another model, a harness that
/// cannot.
class CompactionToggle extends StatelessWidget {
  const CompactionToggle({
    super.key,
    required this.item,
    required this.note,
    this.onToggle,
  });

  /// The compaction.
  final TranscriptItem item;

  /// The note of the compaction, as the transcript draws it.
  final Widget note;

  /// What the button does; null when the note has none.
  final VoidCallback? onToggle;

  /// How much of the note shows while its compaction is not in force.
  static const dimmed = 0.55;

  @override
  Widget build(BuildContext context) {
    final reverted = item.isRevertedCompaction;
    final toggle = onToggle;
    // The note keeps its place in the tree whatever the state, so that a
    // summary the person opened stays open when the compaction is taken back.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Opacity(opacity: reverted ? dimmed : 1, child: note),
        if (reverted)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Reverted',
              textAlign: TextAlign.center,
              style: HarnessText.meta(context).copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (toggle != null)
          Center(
            child: HarnessTextButton(
              label: reverted ? 'Go post-compaction' : 'Revert',
              icon: reverted ? Icons.redo_rounded : Icons.undo_rounded,
              dense: true,
              onPressed: toggle,
            ),
          ),
      ],
    );
  }
}

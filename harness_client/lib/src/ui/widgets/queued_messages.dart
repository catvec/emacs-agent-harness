import 'package:flutter/material.dart';

import '../../models/session.dart';
import '../../models/transcript.dart';
import '../adaptive/adaptive_widgets.dart';
import '../theme/harness_theme.dart';

/// The messages queued for a conversation's next turn, above its box: what
/// the harness holds (`session/queue`), each with what can be done about it.
///
/// A message queued while the agent works waits here until the turn ends,
/// which sends the queue as a turn of its own; [onSendNow] sends it sooner,
/// into the running turn or as a turn of its own, and [onSendAll] sends the
/// rest with it.  [onEdit] takes a message's words back into the box, and
/// [onRemove] drops it.  A null callback is not offered: the harness may not
/// take that call, and a message the app did not queue may carry pictures of
/// the harness's machine, which only words can come back from.
class QueuedMessages extends StatelessWidget {
  const QueuedMessages({
    super.key,
    required this.items,
    this.onSendNow,
    this.onSendAll,
    this.onEdit,
    this.onRemove,
  });

  final List<QueueItem> items;
  final void Function(String id)? onSendNow;
  final VoidCallback? onSendAll;
  final void Function(String id)? onEdit;
  final void Function(String id)? onRemove;

  /// The most room the rows take before they scroll: on a phone the
  /// conversation keeps the rest, and a queue of many is still all there.
  static const double _rowsLimit = 150;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (items.isEmpty) return const SizedBox.shrink();
    final color = theme.colorScheme.primary;
    final rows = <Widget>[
      for (var index = 0; index < items.length; index++) ...[
        if (index > 0)
          Divider(
            height: 1,
            thickness: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        _QueuedRow(
          item: items[index],
          onSendNow: onSendNow,
          onEdit: onEdit,
          onRemove: onRemove,
        ),
      ],
    ];
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Queued messages, ${items.length}',
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.04),
          border: Border(
            top: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HarnessSpace.gutter,
                6,
                HarnessSpace.sm,
                0,
              ),
              child: Row(
                children: [
                  Icon(Icons.playlist_add_rounded, size: 16, color: color),
                  const SizedBox(width: 8),
                  Text(
                    'Queue',
                    style: HarnessText.meta(context)
                        .copyWith(fontWeight: FontWeight.w700, color: color),
                  ),
                  const SizedBox(width: 6),
                  Text('${items.length}', style: HarnessText.meta(context)),
                  const Spacer(),
                  if (onSendAll != null && items.length > 1)
                    HarnessTextButton(
                      key: const Key('queue-send-all'),
                      label: 'Send all',
                      dense: true,
                      onPressed: onSendAll,
                    )
                  else
                    const SizedBox(height: 6),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _rowsLimit),
              child: ListView(
                key: const Key('queue-rows'),
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: rows,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueuedRow extends StatelessWidget {
  const _QueuedRow({
    required this.item,
    this.onSendNow,
    this.onEdit,
    this.onRemove,
  });

  final QueueItem item;
  final void Function(String id)? onSendNow;
  final void Function(String id)? onEdit;
  final void Function(String id)? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sender = formatSender(item.from);
    final mute = theme.colorScheme.onSurfaceVariant;
    return Padding(
      key: ValueKey('queue-item-${item.id}'),
      padding: const EdgeInsets.fromLTRB(HarnessSpace.gutter, 6, 4, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(Icons.circle, size: 7, color: mute),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        sender == null ? 'Queued' : '$sender · Queued',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HarnessText.caption(context)
                            .copyWith(color: mute, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  item.displayText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.subtitle(context),
                ),
              ],
            ),
          ),
          if (onSendNow != null)
            _QueuedAction(
              key: ValueKey('queue-send-${item.id}'),
              icon: Icons.send_rounded,
              label: 'Send now',
              onTap: () => onSendNow!(item.id),
            ),
          if (onEdit != null && !item.hasAttachments)
            _QueuedAction(
              key: ValueKey('queue-edit-${item.id}'),
              icon: Icons.edit_outlined,
              label: 'Edit',
              onTap: () => onEdit!(item.id),
            ),
          if (onRemove != null)
            _QueuedAction(
              key: ValueKey('queue-remove-${item.id}'),
              icon: Icons.delete_outline_rounded,
              label: 'Delete',
              onTap: () => onRemove!(item.id),
            ),
        ],
      ),
    );
  }
}

class _QueuedAction extends StatelessWidget {
  const _QueuedAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: InkResponse(
          onTap: onTap,
          radius: 20,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(
              icon,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

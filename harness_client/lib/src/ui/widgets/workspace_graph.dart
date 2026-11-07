import 'package:flutter/material.dart';

import '../../state/workspace_controller.dart';
import '../theme/harness_theme.dart';

/// The prototype's graph periphery.
///
/// The chat stays the page.  A few concepts the current workspace's threads
/// share sit at the edge as tags: enough to say *this conversation is near
/// these others* without turning the page into a canvas of every page and
/// bullet.  Tapping a concept narrows the thread rail to the threads that
/// carry it.
///
/// Whether this helps is the hypothesis, not a settled design.  The nodes
/// are concepts (tags), not pages; the dreaming process is where a coherent
/// taxonomy will be maintained.
class ConceptRail extends StatelessWidget {
  const ConceptRail({
    super.key,
    required this.concepts,
    required this.selected,
    required this.onSelect,
    this.width = 146,
  });

  final List<ConceptTag> concepts;
  final String? selected;
  final ValueChanged<String?> onSelect;
  final double width;

  @override
  Widget build(BuildContext context) {
    if (concepts.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      width: width,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 20, 8, 20),
        children: [
          Text('Concepts', style: HarnessText.label(context)),
          const SizedBox(height: HarnessSpace.sm),
          for (final concept in concepts)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _ConceptTag(
                key: ValueKey('concept-${concept.name}'),
                concept: concept,
                selected:
                    selected?.toLowerCase() == concept.name.toLowerCase(),
                onTap: () => onSelect(concept.name),
                expanded: true,
              ),
            ),
          const SizedBox(height: HarnessSpace.sm),
          Text(
            selected == null
                ? 'Shared tags'
                : 'Threads · ${_selectedCount(concepts, selected!)}',
            style: HarnessText.caption(context),
          ),
        ],
      ),
    );
  }
}

/// The compact form: a thin row of tag chips over the composer.
class ConceptStrip extends StatelessWidget {
  const ConceptStrip({
    super.key,
    required this.concepts,
    required this.selected,
    required this.onSelect,
  });

  final List<ConceptTag> concepts;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    if (concepts.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 60,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: HarnessSpace.gutter,
          vertical: 8,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(child: Text('Near', style: HarnessText.label(context))),
          ),
          for (final concept in concepts)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Center(
                child: _ConceptTag(
                key: ValueKey('concept-${concept.name}'),
                concept: concept,
                selected:
                    selected?.toLowerCase() == concept.name.toLowerCase(),
                onTap: () => onSelect(concept.name),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

int _selectedCount(List<ConceptTag> concepts, String selected) {
  for (final concept in concepts) {
    if (concept.name.toLowerCase() == selected.toLowerCase()) {
      return concept.threads.length;
    }
  }
  return 0;
}

class _ConceptTag extends StatelessWidget {
  const _ConceptTag({
    super.key,
    required this.concept,
    required this.selected,
    required this.onTap,
    this.expanded = false,
  });

  final ConceptTag concept;
  final bool selected;
  final VoidCallback onTap;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = selected
        ? theme.colorScheme.primary
        : concept.shared
        ? HarnessColors.moss
        : theme.colorScheme.outline;
    return Tooltip(
      message: concept.name,
      child: Semantics(
      button: true,
      selected: selected,
      label: 'Concept ${concept.name}, ${concept.threads.length} threads',
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: expanded ? 40 : 44),
        child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(2),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
            decoration: BoxDecoration(
              color: selected
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.45)
                  : theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(2),
              border: Border.all(
                color: selected
                    ? accent.withValues(alpha: 0.55)
                    : theme.colorScheme.outlineVariant,
              ),
            ),
            child: Row(
              mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
              children: [
                Text(
                  '#',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: accent.withValues(alpha: selected ? 1 : 0.8),
                  ),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    concept.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (concept.threads.length > 1) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(
                      '${concept.threads.length}',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      ),
      ),
    );
  }
}

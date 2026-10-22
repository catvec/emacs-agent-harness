import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/harness_theme.dart';
import 'adaptive_widgets.dart';

// How information is laid out.  A short vocabulary, used the same way on
// every page:
//
//  * a fact about a thing is text, joined to its neighbours with a middle
//    dot ([HarnessMetaLine]), not a pill;
//  * a state is a dot and a word ([HarnessStatusLabel]);
//  * a way to look at a list is a tab ([HarnessTabStrip]);
//  * what a page is about is said once, in its scope bar
//    ([HarnessScopeBar]);
//  * a message to the person is a notice in the flow of the page, under the
//    header and never over it ([HarnessNotice]);
//  * pills ([HarnessPill]) are left for a choice among a few things, in a
//    sheet.

/// One fact in a [HarnessMetaLine]: its text, and how it stands out.
class HarnessMetaPart {
  const HarnessMetaPart(this.text, {this.color, this.weight});

  final String text;
  final Color? color;
  final FontWeight? weight;
}

/// Facts about a thing on one line, joined with a middle dot: the project
/// and the model, a branch and its state.  Empty facts are left out, and a
/// line that is too long ends in an ellipsis rather than wrapping.
///
/// With [dropWhatDoesNotFit] it is the last facts that go, whole, until the
/// line fits: a line of two facts reads better than one of three with the
/// third cut in the middle.  (The first fact always stays.)
class HarnessMetaLine extends StatelessWidget {
  const HarnessMetaLine({
    super.key,
    required this.parts,
    this.style,
    this.maxLines = 1,
    this.textAlign,
    this.dropWhatDoesNotFit = false,
  });

  /// Strings or [HarnessMetaPart]s.  Null and empty ones are left out.
  final List<Object?> parts;
  final TextStyle? style;
  final int maxLines;
  final TextAlign? textAlign;
  final bool dropWhatDoesNotFit;

  static const separator = ' · ';

  @override
  Widget build(BuildContext context) {
    final base = style ?? HarnessText.subtitle(context);
    final facts = <HarnessMetaPart>[
      for (final part in parts)
        if (part is String && part.isNotEmpty)
          HarnessMetaPart(part)
        else if (part is HarnessMetaPart && part.text.isNotEmpty)
          part,
    ];
    if (facts.isEmpty) return const SizedBox.shrink();
    if (!dropWhatDoesNotFit) return _line(context, base, facts);
    return LayoutBuilder(
      builder: (context, constraints) {
        var shown = facts.length;
        if (constraints.maxWidth.isFinite) {
          final direction = Directionality.of(context);
          final scale = MediaQuery.textScalerOf(context);
          while (shown > 1) {
            final painter = TextPainter(
              text: _span(base, facts.sublist(0, shown)),
              textDirection: direction,
              textScaler: scale,
              maxLines: 1,
            )..layout();
            final fits = painter.width <= constraints.maxWidth;
            painter.dispose();
            if (fits) break;
            shown--;
          }
        }
        return _line(context, base, facts.sublist(0, shown));
      },
    );
  }

  Widget _line(
    BuildContext context,
    TextStyle base,
    List<HarnessMetaPart> facts,
  ) {
    // Plain text is a plain `Text`: simple to find, simple to read aloud.
    if (facts.every((fact) => fact.color == null && fact.weight == null)) {
      return Text(
        facts.map((fact) => fact.text).join(separator),
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        textAlign: textAlign,
        style: base,
      );
    }
    return Text.rich(
      _span(base, facts),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      textAlign: textAlign,
    );
  }

  TextSpan _span(TextStyle base, List<HarnessMetaPart> facts) {
    final dim = base.color?.withValues(alpha: 0.55);
    return TextSpan(
      style: base,
      children: [
        for (var index = 0; index < facts.length; index++) ...[
          if (index > 0)
            TextSpan(
              text: separator,
              style: TextStyle(color: dim),
            ),
          TextSpan(
            text: facts[index].text,
            style: facts[index].color == null && facts[index].weight == null
                ? null
                : TextStyle(
                    color: facts[index].color,
                    fontWeight: facts[index].weight,
                  ),
          ),
        ],
      ],
    );
  }
}

/// A small filled circle: the mark of a state.
class HarnessDot extends StatelessWidget {
  const HarnessDot({super.key, required this.color, this.size = 7});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// A state as a dot and a word ("● Running"), in the color of the state.
/// Quieter than a pill, and it lines up with the text around it.
class HarnessStatusLabel extends StatelessWidget {
  const HarnessStatusLabel({
    super.key,
    required this.label,
    required this.color,
    this.style,
    this.icon,
  });

  final String label;
  final Color color;
  final TextStyle? style;

  /// Instead of the dot.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final base = style ?? HarnessText.meta(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null)
          Icon(icon, size: 14, color: color)
        else
          HarnessDot(color: color, size: 6),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: base.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// One tab of a [HarnessTabStrip].
class HarnessTab<T> {
  const HarnessTab({
    required this.value,
    required this.label,
    this.count,
    this.color,
  });

  final T value;
  final String label;

  /// How many things are behind the tab, when that is worth saying.
  final int? count;

  /// The color of the tab when it is the one shown.
  final Color? color;
}

/// The ways to look at a list, side by side in one row that scrolls when it
/// has to: the label, how many are behind it, and a rule under the one that
/// is shown.  It starts at the page gutter, like everything else.
class HarnessTabStrip<T> extends StatelessWidget {
  const HarnessTabStrip({
    super.key,
    required this.tabs,
    required this.value,
    required this.onChanged,
  });

  final List<HarnessTab<T>> tabs;
  final T value;
  final ValueChanged<T> onChanged;

  static const _height = 44.0;
  static const _pad = 12.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SizedBox(
        // Room for the label, at whatever size the person reads: never less
        // than a thumb needs.
        height: math.max(
          _height,
          MediaQuery.textScalerOf(context).scale(14) * 1.3 + 2.5 + 22,
        ),
        child: ListView(
          scrollDirection: Axis.horizontal,
          // The first label, not the first tab, sits on the gutter.
          padding: const EdgeInsets.symmetric(
            horizontal: HarnessSpace.gutter - _pad,
          ),
          children: [
            for (final tab in tabs)
              _TabItem<T>(
                tab: tab,
                selected: tab.value == value,
                onTap: () => onChanged(tab.value),
              ),
          ],
        ),
      ),
    );
  }
}

class _TabItem<T> extends StatelessWidget {
  const _TabItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final HarnessTab<T> tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = tab.color ?? theme.colorScheme.primary;
    final muted = theme.colorScheme.onSurfaceVariant;
    // The tab that is shown is in full ink, so that it reads as chosen
    // whatever its color; its color is in the rule and in the count.
    final text = selected ? theme.colorScheme.onSurface : muted;
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: HarnessTabStrip._pad),
          // As wide as the label, so that the rule under it is too.
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Expanded(
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          tab.label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: text,
                          ),
                        ),
                        if (tab.count != null) ...[
                          const SizedBox(width: 5),
                          Text(
                            '${tab.count}',
                            style: HarnessText.meta(context).copyWith(
                              color: selected
                                  ? accent
                                  : muted.withValues(alpha: 0.75),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  height: 2.5,
                  decoration: BoxDecoration(
                    color: selected ? accent : Colors.transparent,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What a page is about, said once under its header: the project (a choice,
/// when [onTap] is given) and, at the other end, a short fact about it.
class HarnessScopeBar extends StatelessWidget {
  const HarnessScopeBar({
    super.key,
    required this.label,
    this.onTap,
    this.trailing,
    this.icon = Icons.folder_outlined,
  });

  final String label;
  final VoidCallback? onTap;

  /// A short text at the far edge ("Updated just now").
  final Widget? trailing;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final scope = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 17, color: muted),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HarnessText.rowTitle(context).copyWith(fontSize: 14),
          ),
        ),
        if (onTap != null) ...[
          const SizedBox(width: 2),
          Icon(Icons.expand_more_rounded, size: 18, color: muted),
        ],
      ],
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: HarnessSpace.gutter),
        child: Row(
          children: [
            // The scope is as wide as its label, at the start; what is
            // after it is at the other end.
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: onTap == null
                    ? scope
                    : Semantics(
                        button: true,
                        label: label,
                        child: HarnessTap(
                          onTap: onTap,
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: scope,
                          ),
                        ),
                      ),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ],
        ),
      ),
    );
  }
}

/// A message to the person, in the flow of the page: a line, what it is
/// about, and what to do (tap it, or an action at its end).  It is under
/// the header of the page, so the header never moves and is never covered.
class HarnessNotice extends StatelessWidget {
  const HarnessNotice({
    super.key,
    this.icon,
    this.leading,
    required this.message,
    this.detail,
    this.color,
    this.onTap,
    this.actionLabel,
    this.onAction,
    this.actionKey,
    this.detailLines = 2,
    this.margin = const EdgeInsets.fromLTRB(
      HarnessSpace.gutter,
      HarnessSpace.sm,
      HarnessSpace.gutter,
      0,
    ),
  });

  final IconData? icon;

  /// Instead of [icon]: a spinner, say.
  final Widget? leading;
  final String message;
  final String? detail;

  /// How many lines [detail] may take before it is cut short.  A notice that
  /// only hints at something keeps to two; one whose detail is the point
  /// (what went wrong, and why) says it in full.
  final int detailLines;
  final Color? color;

  /// Makes the whole notice a button.
  final VoidCallback? onTap;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Key? actionKey;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final tint = color ?? HarnessColors.amber;
    final action = actionLabel != null && onAction != null;
    return Padding(
      padding: margin,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tint.withValues(alpha: dark ? 0.16 : 0.11),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: tint.withValues(alpha: 0.32)),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.fromLTRB(14, 10, action ? 6 : 14, 10),
              child: Row(
                children: [
                  leading ?? Icon(icon, size: 19, color: tint),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          message,
                          style: HarnessText.body(
                            context,
                          ).copyWith(fontWeight: FontWeight.w600, height: 1.3),
                        ),
                        if (detail != null && detail!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            detail!,
                            maxLines: detailLines,
                            overflow: TextOverflow.ellipsis,
                            style: HarnessText.caption(context),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (action)
                    HarnessTextButton(
                      key: actionKey,
                      label: actionLabel!,
                      onPressed: onAction,
                    )
                  else if (onTap != null) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.arrow_forward_rounded, size: 17, color: tint),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The surface that groups things: one fill, one border, one radius.
class HarnessCard extends StatelessWidget {
  const HarnessCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(HarnessSpace.lg),
    this.margin,
    this.radius = 16,
    this.color,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: borderColor ?? theme.colorScheme.outlineVariant,
        ),
      ),
      child: child,
    );
  }
}

/// A card of rows, with a hairline between them.  The rows bring their own
/// padding, so a tap can fill the width of the card.
class HarnessCardList extends StatelessWidget {
  const HarnessCardList({
    super.key,
    required this.children,
    this.dividerIndent = HarnessSpace.lg,
  });

  final List<Widget> children;
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < children.length; index++) ...[
            if (index > 0)
              Divider(
                height: 1,
                indent: dividerIndent,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
              ),
            children[index],
          ],
        ],
      ),
    );
  }
}

/// A few numbers side by side, each over its label: the same cells wherever
/// numbers are summed up.
class HarnessStatRow extends StatelessWidget {
  const HarnessStatRow({super.key, required this.stats});

  /// `(value, label)` pairs.
  final List<(String, String)> stats;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final stat in stats)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stat.$1,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HarnessText.rowTitle(context).copyWith(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 2),
                Text(stat.$2, style: HarnessText.caption(context)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Text that opens a choice: "claude-fable-5-1 ⌄".  Quiet where a pill
/// would shout, and a full-height target all the same.
class HarnessPicker extends StatelessWidget {
  const HarnessPicker({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.color,
  });

  final String label;
  final IconData? icon;

  /// Null: the value is shown, and cannot be changed here.
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: tint),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HarnessText.meta(context)
                  .copyWith(color: tint, fontWeight: FontWeight.w600),
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 2),
            Icon(Icons.expand_more_rounded, size: 15, color: tint),
          ],
        ],
      ),
    );
    if (onTap == null) return content;
    return Semantics(
      button: true,
      label: label,
      child: HarnessTap(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: content,
      ),
    );
  }
}

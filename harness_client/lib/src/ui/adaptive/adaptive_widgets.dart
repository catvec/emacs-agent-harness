import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/harness_theme.dart';
import '../widgets/quick_search_entry.dart';
import 'platform_style.dart';

/// What the home shell has to say to the person (an action that failed, a
/// session that needs an answer), handed down to the pages it holds.  A
/// [HarnessPage] puts it in its own flow, under its header: it never floats
/// over a page, so a title and its buttons are never covered.
class HarnessChrome extends InheritedWidget {
  const HarnessChrome({super.key, required this.notices, required super.child});

  /// Builds the notices.  [attention] is whether the one that says a session
  /// needs an answer is wanted: the list of sessions shows that on its own.
  final Widget Function(BuildContext context, {required bool attention})
  notices;

  static HarnessChrome? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HarnessChrome>();

  @override
  bool updateShouldNotify(HarnessChrome oldWidget) => true;
}

/// A page: a header (the [title], a [subtitle] under it, and [actions] at the
/// far end), whatever the shell has to say ([HarnessChrome]), and the
/// [body].  The header is the platform's own bar.
class HarnessPage extends StatelessWidget {
  const HarnessPage({
    super.key,
    required this.title,
    required this.body,
    this.subtitle,
    this.actions = const [],
    this.leading,
    this.bottom,
    this.backgroundColor,
    this.resizeToAvoidBottomInset = true,
    this.centerTitle = false,
    this.attentionNotice = true,
    this.maxContentWidth,
    this.quickSearch = true,
  });

  final String title;

  /// One line under the title: where a conversation is, what it is doing.
  final Widget? subtitle;
  final Widget body;
  final List<Widget> actions;
  final Widget? leading;
  final Widget? bottom;
  final Color? backgroundColor;
  final bool resizeToAvoidBottomInset;
  final bool centerTitle;

  /// Whether the notice that a session needs an answer belongs on this page.
  final bool attentionNotice;

  /// How wide the content may be.  A page of text and cards is not made
  /// wider than a line can be read: on a wide screen it keeps this width, at
  /// the start, so that the title, the notices and the content share a left
  /// edge.  Null: as wide as the screen (a board of columns).
  final double? maxContentWidth;

  /// Whether the header has the button that opens the quick search, when the
  /// app offers it here (see [QuickSearchEntry]): at its far end, where it is
  /// on every page.
  final bool quickSearch;

  @override
  Widget build(BuildContext context) {
    final cupertino = HarnessStyle.isCupertino(context);
    final chrome = HarnessChrome.maybeOf(context);
    final search = quickSearch ? QuickSearchEntry.maybeOf(context) : null;
    final headerActions = [
      ...actions,
      if (search != null)
        HarnessIconButton(
          key: QuickSearchEntry.buttonKey,
          icon: adaptiveIcon(
            context,
            Icons.search_rounded,
            CupertinoIcons.search,
          ),
          label: QuickSearchEntry.buttonLabel,
          onPressed: search.open,
        ),
    ];
    // Always a column of the same shape, so that the body keeps its state
    // (a scroll position, what was typed) as notices come and go.
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        chrome?.notices(context, attention: attentionNotice) ??
            const SizedBox.shrink(),
        Expanded(child: body),
      ],
    );
    final content = maxContentWidth == null
        ? column
        : Align(
            alignment: AlignmentDirectional.topStart,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxContentWidth!),
              child: column,
            ),
          );
    final line = subtitle == null
        ? null
        : DefaultTextStyle(
            style: HarnessText.subtitle(context),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: subtitle!,
          );
    if (cupertino) {
      return CupertinoPageScaffold(
        backgroundColor: backgroundColor,
        navigationBar: CupertinoNavigationBar(
          middle: Semantics(
            header: true,
            child: line == null
                ? Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 1),
                      line,
                    ],
                  ),
          ),
          leading: leading,
          trailing: headerActions.isEmpty
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: _spread(headerActions),
                ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: SafeArea(child: content),
        ),
      );
    }
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: line == null
            ? Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 19),
                  ),
                  const SizedBox(height: 2),
                  line,
                ],
              ),
        // Two lines of text, which grow with the text size the person set.
        toolbarHeight: line == null
            ? null
            : math.max(
                64,
                MediaQuery.textScalerOf(context).scale(19) * 1.25 +
                    MediaQuery.textScalerOf(context).scale(13) * 1.3 +
                    18,
              ),
        leading: leading,
        actions: headerActions,
        centerTitle: centerTitle,
      ),
      body: SafeArea(top: false, child: content),
      bottomNavigationBar: bottom,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
    );
  }

  List<Widget> _spread(List<Widget> children) {
    final out = <Widget>[];
    for (final child in children) {
      if (out.isNotEmpty) out.add(const SizedBox(width: 2));
      out.add(child);
    }
    return out;
  }
}

class HarnessIconButton extends StatelessWidget {
  const HarnessIconButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.color,
    this.size = 22,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final effective = onPressed == null
        ? (color ?? Theme.of(context).colorScheme.onSurface).withValues(
            alpha: 0.3,
          )
        : (color ?? Theme.of(context).colorScheme.onSurface);
    if (HarnessStyle.isCupertino(context)) {
      return Semantics(
        button: true,
        label: label,
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: const Size(40, 40),
          onPressed: onPressed,
          child: Icon(icon, size: size, color: effective),
        ),
      );
    }
    return IconButton(
      tooltip: label,
      onPressed: onPressed,
      icon: Icon(icon, size: size, color: effective),
    );
  }
}

class HarnessPrimaryButton extends StatelessWidget {
  const HarnessPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    this.busy = false,
    this.destructive = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;
  final bool busy;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (busy)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: SizedBox(
              width: 16,
              height: 16,
              child: HarnessStyle.isCupertino(context)
                  ? const CupertinoActivityIndicator(radius: 8)
                  : const CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (icon != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Icon(icon, size: 18),
          ),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
    if (HarnessStyle.isCupertino(context)) {
      return SizedBox(
        width: expand ? double.infinity : null,
        child: CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          borderRadius: BorderRadius.circular(14),
          color: destructive
              ? CupertinoColors.systemRed.resolveFrom(context)
              : CupertinoTheme.of(context).primaryColor,
          onPressed: busy ? null : onPressed,
          child: DefaultTextStyle(
            style: const TextStyle(
              color: CupertinoColors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
            child: child,
          ),
        ),
      );
    }
    return SizedBox(
      width: expand ? double.infinity : null,
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: destructive
            ? FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              )
            : null,
        child: child,
      ),
    );
  }
}

class HarnessSecondaryButton extends StatelessWidget {
  const HarnessSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    this.destructive = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final text = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Icon(icon, size: 18),
          ),
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
      ],
    );
    if (HarnessStyle.isCupertino(context)) {
      final color = destructive
          ? CupertinoColors.systemRed.resolveFrom(context)
          : CupertinoTheme.of(context).primaryColor;
      return SizedBox(
        width: expand ? double.infinity : null,
        child: CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          borderRadius: BorderRadius.circular(14),
          color: color.withValues(alpha: 0.11),
          onPressed: onPressed,
          child: DefaultTextStyle(
            style: TextStyle(
              color: color,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
            child: text,
          ),
        ),
      );
    }
    return SizedBox(
      width: expand ? double.infinity : null,
      child: OutlinedButton(
        onPressed: onPressed,
        style: destructive
            ? OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
                side: BorderSide(
                  color: Theme.of(context).colorScheme.error
                      .withValues(alpha: 0.4),
                ),
              )
            : null,
        child: text,
      ),
    );
  }
}

class HarnessTextButton extends StatelessWidget {
  const HarnessTextButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.destructive = false,
    this.dense = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool destructive;

  /// Less padding around the label, for a button that sits in a card
  /// under text it should line up with: the icon, not the padding, is on
  /// the text's edge.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = destructive
        ? (HarnessStyle.isCupertino(context)
              ? CupertinoColors.systemRed.resolveFrom(context)
              : Theme.of(context).colorScheme.error)
        : (HarnessStyle.isCupertino(context)
              ? CupertinoTheme.of(context).primaryColor
              : Theme.of(context).colorScheme.primary);
    if (HarnessStyle.isCupertino(context)) {
      return CupertinoButton(
        padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 10, vertical: 8),
        minimumSize: const Size(0, 36),
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 17, color: color),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }
    return TextButton.icon(
      onPressed: onPressed,
      icon: icon == null ? null : Icon(icon, size: 18),
      label: Text(label),
      style: destructive || dense
          ? TextButton.styleFrom(
              foregroundColor: destructive ? color : null,
              padding: dense ? const EdgeInsets.symmetric(horizontal: 8) : null,
              minimumSize: dense ? const Size(0, 36) : null,
            )
          : null,
    );
  }
}

class HarnessTextField extends StatelessWidget {
  const HarnessTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.hint,
    this.obscure = false,
    this.maxLines = 1,
    this.minLines,
    this.keyboardType,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.enabled = true,
    this.prefix,
    this.suffix,
    this.autofocus = false,
    this.style,
    this.contentPadding,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hint;
  final bool obscure;
  final int maxLines;
  final int? minLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;
  final Widget? prefix;
  final Widget? suffix;
  final bool autofocus;
  final TextStyle? style;
  final EdgeInsets? contentPadding;

  @override
  Widget build(BuildContext context) {
    if (HarnessStyle.isCupertino(context)) {
      return CupertinoTextField(
        controller: controller,
        focusNode: focusNode,
        placeholder: hint,
        obscureText: obscure,
        maxLines: maxLines,
        minLines: minLines,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        enabled: enabled,
        autofocus: autofocus,
        style: style ?? CupertinoTheme.of(context).textTheme.textStyle,
        padding:
            contentPadding ??
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        prefix: prefix == null
            ? null
            : Padding(padding: const EdgeInsets.only(left: 12), child: prefix),
        suffix: suffix == null
            ? null
            : Padding(padding: const EdgeInsets.only(right: 8), child: suffix),
        decoration: BoxDecoration(
          color: CupertinoColors.secondarySystemBackground.resolveFrom(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: CupertinoColors.separator.resolveFrom(context),
          ),
        ),
      );
    }
    return TextField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscure,
      maxLines: maxLines,
      minLines: minLines,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      enabled: enabled,
      autofocus: autofocus,
      style: style,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: prefix,
        suffixIcon: suffix,
        contentPadding: contentPadding,
      ),
    );
  }
}

class HarnessSwitch extends StatelessWidget {
  const HarnessSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    if (HarnessStyle.isCupertino(context)) {
      return CupertinoSwitch(
        value: value,
        onChanged: onChanged,
        activeTrackColor:
            activeColor ?? CupertinoTheme.of(context).primaryColor,
      );
    }
    return Switch(
      value: value,
      onChanged: onChanged,
      activeThumbColor: activeColor,
    );
  }
}

class HarnessSegmented<T extends Object> extends StatelessWidget {
  const HarnessSegmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    if (HarnessStyle.isCupertino(context)) {
      return CupertinoSlidingSegmentedControl<T>(
        groupValue: value,
        onValueChanged: (next) {
          if (next != null) {
            HapticFeedback.selectionClick();
            onChanged(next);
          }
        },
        thumbColor: CupertinoTheme.of(context).barBackgroundColor,
        backgroundColor: CupertinoColors.secondarySystemBackground.resolveFrom(
          context,
        ),
        children: {
          for (final option in options)
            option.$1: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Text(
                option.$2,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        },
      );
    }
    return SegmentedButton<T>(
      segments: [
        for (final option in options)
          ButtonSegment<T>(value: option.$1, label: Text(option.$2)),
      ],
      selected: {value},
      showSelectedIcon: false,
      onSelectionChanged: (selection) {
        if (selection.isNotEmpty) onChanged(selection.first);
      },
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class HarnessPill extends StatelessWidget {
  const HarnessPill({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.icon,
    this.count,
    this.color,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;
  final int? count;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = color ?? theme.colorScheme.primary;
    final background = selected
        ? accent.withValues(alpha: dark ? 0.24 : 0.12)
        : (dark ? const Color(0xFF1D1D21) : HarnessColors.paperRaised);
    final border = selected
        ? accent.withValues(alpha: 0.5)
        : theme.colorScheme.outlineVariant;
    return Semantics(
      button: onTap != null,
      selected: onTap == null ? null : selected,
      label: label,
      child: GestureDetector(
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 15,
                  color: selected ? accent : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? accent : theme.colorScheme.onSurface,
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? accent
                        : theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: selected
                          ? Colors.white
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class HarnessTap extends StatefulWidget {
  const HarnessTap({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius,
    this.selected = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius? borderRadius;
  final bool selected;

  @override
  State<HarnessTap> createState() => _HarnessTapState();
}

class _HarnessTapState extends State<HarnessTap> {
  bool _down = false;

  void _setDown(bool value) {
    if (!mounted) return;
    setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    if (HarnessStyle.isCupertino(context)) {
      final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                widget.onTap!();
              },
        onTapDown: widget.onTap == null ? null : (_) => _setDown(true),
        onTapUp: widget.onTap == null ? null : (_) => _setDown(false),
        onTapCancel: widget.onTap == null ? null : () => _setDown(false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          color: _down
              ? (dark ? const Color(0x14FFFFFF) : const Color(0x0A000000))
              : Colors.transparent,
          child: widget.child,
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      borderRadius: widget.borderRadius,
      child: InkWell(
        borderRadius: widget.borderRadius,
        onTap: widget.onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                widget.onTap!();
              },
        child: widget.child,
      ),
    );
  }
}

class HarnessActivity extends StatelessWidget {
  const HarnessActivity({super.key, this.radius = 9, this.color});
  final double radius;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (HarnessStyle.isCupertino(context)) {
      return CupertinoActivityIndicator(radius: radius, color: color);
    }
    return SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: CircularProgressIndicator(
        strokeWidth: 2.2,
        color: color ?? Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

class HarnessSectionHeader extends StatelessWidget {
  const HarnessSectionHeader({
    super.key,
    required this.label,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      HarnessSpace.xs,
      HarnessSpace.xl,
      HarnessSpace.xs,
      HarnessSpace.sm,
    ),
  });

  final String label;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(label.toUpperCase(), style: HarnessText.label(context)),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class HarnessStatusPill extends StatelessWidget {
  const HarnessStatusPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.compact = true,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 4),
          ] else ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: compact ? 10.5 : 12,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class HarnessErrorBanner extends StatelessWidget {
  const HarnessErrorBanner({
    super.key,
    required this.message,
    this.onDismiss,
    this.actionLabel,
    this.onAction,
    this.margin = const EdgeInsets.fromLTRB(
      HarnessSpace.gutter,
      HarnessSpace.sm,
      HarnessSpace.gutter,
      0,
    ),
  });

  final String message;
  final VoidCallback? onDismiss;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.error;
    return Padding(
      padding: margin,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: color, size: 19),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  vertical: onDismiss == null && actionLabel == null ? 4 : 0,
                ),
                child: Text(
                  message,
                  style: HarnessText.body(context).copyWith(height: 1.35),
                ),
              ),
            ),
            if (actionLabel != null)
              HarnessTextButton(label: actionLabel!, onPressed: onAction),
            if (onDismiss != null)
              HarnessIconButton(
                icon: Icons.close_rounded,
                label: 'Dismiss',
                size: 18,
                onPressed: onDismiss,
              ),
          ],
        ),
      ),
    );
  }
}

class HarnessEmptyState extends StatelessWidget {
  const HarnessEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.09),
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.16),
                ),
              ),
              child: Icon(icon, size: 30, color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
            ),
            if (action != null) ...[const SizedBox(height: 22), action!],
          ],
        ),
      ),
    );
  }
}

class HarnessBadge extends StatelessWidget {
  const HarnessBadge({super.key, required this.count, this.color});
  final int count;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.error;
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }
}

class HarnessSheetHandle extends StatelessWidget {
  const HarnessSheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 38,
        height: 4,
        margin: const EdgeInsets.only(top: 10, bottom: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.onSurface
              .withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class HarnessInfoRow extends StatelessWidget {
  const HarnessInfoRow({
    super.key,
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  /// The width of the label column, shared by every row of every card.
  static const labelWidth = 104.0;

  @override
  Widget build(BuildContext context) {
    final text = HarnessText.body(context).copyWith(height: 1.35);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(label, style: HarnessText.subtitle(context)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: monospace
                  ? text.copyWith(fontFamily: 'monospace', fontSize: 13)
                  : text,
            ),
          ),
        ],
      ),
    );
  }
}

/// A bottom sheet styled like the platform's own.
Future<T?> showHarnessSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  if (HarnessStyle.isCupertino(context)) {
    return showCupertinoModalPopup<T>(
      context: context,
      builder: (sheetContext) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.88,
        ),
        decoration: BoxDecoration(
          color: CupertinoTheme.of(sheetContext).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const HarnessSheetHandle(),
                Flexible(child: builder(sheetContext)),
              ],
            ),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: builder,
  );
}

Future<T?> showHarnessDialog<T>({
  required BuildContext context,
  required String title,
  String? message,
  Widget? content,
  String? confirmLabel,
  String? cancelLabel,
  bool destructive = false,
}) {
  final cupertino = HarnessStyle.isCupertino(context);
  if (cupertino) {
    return showCupertinoDialog<T>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(title),
        content:
            content ??
            (message == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(message),
                  )),
        actions: [
          if (cancelLabel != null)
            CupertinoDialogAction(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(cancelLabel),
            ),
          if (confirmLabel != null)
            CupertinoDialogAction(
              isDestructiveAction: destructive,
              isDefaultAction: !destructive,
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(confirmLabel),
            ),
        ],
      ),
    );
  }
  return showDialog<T>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: content ?? (message == null ? null : Text(message)),
      actions: [
        if (cancelLabel != null)
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(cancelLabel),
          ),
        if (confirmLabel != null)
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: destructive
                ? TextButton.styleFrom(
                    foregroundColor: Theme.of(dialogContext).colorScheme.error,
                  )
                : null,
            child: Text(confirmLabel),
          ),
      ],
    ),
  );
}

class HarnessMenuItem<T> {
  const HarnessMenuItem({
    required this.value,
    required this.label,
    this.icon,
    this.destructive = false,
  });
  final T value;
  final String label;
  final IconData? icon;
  final bool destructive;
}

Future<T?> showHarnessMenu<T>({
  required BuildContext context,
  required List<HarnessMenuItem<T>> items,
  String? title,
}) async {
  if (items.isEmpty) return null;
  if (HarnessStyle.isCupertino(context)) {
    return showCupertinoModalPopup<T>(
      context: context,
      builder: (popupContext) => CupertinoActionSheet(
        title: title == null ? null : Text(title),
        actions: [
          for (final item in items)
            CupertinoActionSheetAction(
              isDestructiveAction: item.destructive,
              onPressed: () => Navigator.of(popupContext).pop(item.value),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (item.icon != null) ...[
                    Icon(item.icon, size: 18),
                    const SizedBox(width: 8),
                  ],
                  Text(item.label),
                ],
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(popupContext).pop(),
          child: const Text('Cancel'),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                title,
                style: Theme.of(sheetContext).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          // A bottom sheet holds a part of the screen, and a long list (every
          // project, every model) does not fit it: it scrolls inside it,
          // where what did not fit was cut off, and out of reach.
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final item in items)
                  ListTile(
                    leading: item.icon == null ? null : Icon(item.icon),
                    title: Text(
                      item.label,
                      style: item.destructive
                          ? TextStyle(
                              color: Theme.of(sheetContext).colorScheme.error,
                            )
                          : null,
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(item.value),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

Future<String?> showHarnessTextPrompt({
  required BuildContext context,
  required String title,
  String? message,
  String? hint,
  String initial = '',
  String confirmLabel = 'Save',
  bool multiline = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _TextPromptDialog(
      title: title,
      message: message,
      hint: hint,
      initial: initial,
      confirmLabel: confirmLabel,
      multiline: multiline,
    ),
  );
}

/// The dialog of [showHarnessTextPrompt].  It owns the field's controller, so
/// that the controller outlives the dialog's way out: the dialog fades away
/// for a moment after it is closed, with its field still drawn.
class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.message,
    required this.hint,
    required this.initial,
    required this.confirmLabel,
    required this.multiline,
  });

  final String title;
  final String? message;
  final String? hint;
  final String initial;
  final String confirmLabel;
  final bool multiline;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final field = HarnessTextField(
      controller: _controller,
      hint: widget.hint,
      autofocus: true,
      maxLines: widget.multiline ? 5 : 1,
      minLines: widget.multiline ? 3 : null,
      textInputAction: widget.multiline
          ? TextInputAction.newline
          : TextInputAction.done,
      onSubmitted: widget.multiline
          ? null
          : (value) => Navigator.of(context).pop(value),
    );
    if (HarnessStyle.isCupertino(context)) {
      return CupertinoAlertDialog(
        title: Text(widget.title),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message != null) ...[
                Text(message),
                const SizedBox(height: 12),
              ],
              field,
            ],
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: Text(widget.confirmLabel),
          ),
        ],
      );
    }
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message != null) ...[Text(message), const SizedBox(height: 12)],
          field,
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

IconData adaptiveIcon(
  BuildContext context,
  IconData material,
  IconData cupertino,
) => HarnessStyle.isCupertino(context) ? cupertino : material;

Widget adaptiveChevron(BuildContext context, {Color? color}) {
  if (HarnessStyle.isCupertino(context)) {
    return Icon(
      CupertinoIcons.chevron_forward,
      size: 16,
      color: color ?? CupertinoColors.tertiaryLabel.resolveFrom(context),
    );
  }
  return Icon(
    Icons.chevron_right_rounded,
    size: 20,
    color:
        color ??
        Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
  );
}

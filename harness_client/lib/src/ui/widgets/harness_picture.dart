import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../acp/acp_client.dart';
import '../../models/picture.dart';
import '../../models/tool_display.dart';
import '../../state/pictures.dart';
import '../adaptive/adaptive_widgets.dart';
import '../app_scope.dart';
import '../navigation.dart';
import '../theme/harness_theme.dart';

// The pictures of the harness's machine -- the screenshots a task hands in,
// the image a `read_file` call read -- drawn where the transcript and the task
// sheet name them.  A phone cannot open the path they are named by, so the
// harness gives the bytes (`session/image`); the widgets here ask a
// [PictureSource] for them, draw what comes, say so when it cannot, and show
// a picture larger, to look into, when it is tapped.

/// Where the pictures below this are got from.  The app's own source is the
/// connected harness's ([AppController.pictures]); a scope puts another in its
/// place, which is how a picture is drawn without a harness.
class PictureScope extends InheritedWidget {
  const PictureScope({super.key, required this.source, required super.child});

  final PictureSource source;

  /// The source of the pictures here: that of the nearest scope, else the
  /// connected harness's, else none (a widget on its own).
  static PictureSource? maybeOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<PictureScope>();
    if (scope != null) return scope.source;
    return context.getInheritedWidgetOfExactType<HarnessScope>()?.app.pictures;
  }

  @override
  bool updateShouldNotify(PictureScope oldWidget) => oldWidget.source != source;
}

/// Whether a picture of session [sessionId] can be drawn here: the session is
/// known, and so is a source that is able to give pictures.  When not, what
/// names the picture says so (it has its name and no more), as it did before
/// pictures were drawn, and a harness that does not give them is no error.
bool canDrawPictures(BuildContext context, String? sessionId) {
  if (sessionId == null || sessionId.isEmpty) return false;
  return PictureScope.maybeOf(context)?.available ?? false;
}

/// The path of the picture that [item], a piece of the evidence a task handed
/// in, is, to draw under its line; null when it is none, when the app cannot
/// draw its type (a TIFF is a file to it), or when no harness is able to give
/// it ([canDrawPictures]): the evidence is then named and no more.
String? evidencePicturePath(
  BuildContext context,
  EvidenceItem item,
  String? sessionId,
) {
  final path = item.path;
  if (item.kind != 'image' || path == null || path.isEmpty) return null;
  if (!isDrawablePicture(null, path)) return null;
  return canDrawPictures(context, sessionId) ? path : null;
}

/// The words for a person that say why a picture is not there.
String pictureFailure(Object error) => switch (error) {
  AcpException(:final message) => message,
  FormatException(:final message) => message,
  _ => '$error',
};

/// A picture of the harness's machine: while it comes a placeholder, then the
/// picture, as large as the room lets it be (never more than [maxHeight]
/// tall), and when it is tapped, larger still ([PictureViewerScreen]).  When
/// it cannot be had it says why, and can be asked for again.
class HarnessPicture extends StatefulWidget {
  const HarnessPicture({
    super.key,
    required this.sessionId,
    required this.path,
    this.name,
    this.maxHeight = 320,
  });

  /// The session whose transcript shows the file.
  final String sessionId;

  /// The file, on the harness's machine.
  final String path;

  /// What to call it, for a screen reader and the viewer's title; the file's
  /// name by default.
  final String? name;
  final double maxHeight;

  @override
  State<HarnessPicture> createState() => _HarnessPictureState();
}

class _HarnessPictureState extends State<HarnessPicture> {
  PictureSource? _source;
  Future<Picture>? _picture;

  /// The picture, when the source had it already: it is drawn at once, not
  /// a frame after a placeholder.
  Picture? _ready;

  String get _name {
    final given = widget.name?.trim();
    if (given != null && given.isNotEmpty) return given;
    final parts = widget.path.split('/').where((part) => part.isNotEmpty);
    return parts.isEmpty ? 'picture' : parts.last;
  }

  /// Ask for the picture, when there is a source that can give it.
  void _ask() {
    final source = _source;
    final asked = source != null && source.available;
    _picture = asked ? source.load(widget.sessionId, widget.path) : null;
    _ready = asked ? source.peek(widget.sessionId, widget.path) : null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final source = PictureScope.maybeOf(context);
    if (!identical(source, _source) || _picture == null) {
      _source = source;
      _ask();
    }
  }

  @override
  void didUpdateWidget(HarnessPicture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.path != widget.path) {
      _ask();
    }
  }

  void _open(Picture picture) {
    Navigator.of(context).push(
      harnessRoute(
        context,
        (_) => PictureViewerScreen(picture: picture, title: _name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final future = _picture;
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<Picture>(
      future: future,
      initialData: _ready,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _PictureFailure(
            title: 'The picture could not be loaded',
            reason: pictureFailure(snapshot.error!),
            onRetry: () => setState(_ask),
          );
        }
        final picture = snapshot.data;
        if (picture == null) return _PicturePlaceholder(name: _name);
        return Semantics(
          container: true,
          image: true,
          button: true,
          label: _name,
          hint: 'Shows it larger',
          onTap: () => _open(picture),
          child: ExcludeSemantics(
            child: _DrawnPicture(
              picture: picture,
              maxHeight: widget.maxHeight,
              onTap: () => _open(picture),
            ),
          ),
        );
      },
    );
  }
}

/// What stands where a picture will be while it comes.
class _PicturePlaceholder extends StatelessWidget {
  const _PicturePlaceholder({this.name});

  final String? name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: name == null ? 'Loading the picture' : 'Loading $name',
      child: Container(
        key: const ValueKey('picture-loading'),
        height: 120,
        width: double.infinity,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(9),
        ),
        child: const Center(child: HarnessActivity(radius: 10)),
      ),
    );
  }
}

/// A picture that has come, drawn no larger than it is and no taller than
/// [maxHeight], and no more finely than the screen shows it: a screenshot of
/// a whole display is decoded for the width it is drawn at, not at its own.
class _DrawnPicture extends StatelessWidget {
  const _DrawnPicture({
    required this.picture,
    required this.maxHeight,
    required this.onTap,
  });

  final Picture picture;
  final double maxHeight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final Widget drawing;
        if (picture.isSvg) {
          drawing = Container(
            key: const ValueKey('picture-drawn'),
            width: constraints.maxWidth.isFinite ? constraints.maxWidth : null,
            height: maxHeight.clamp(80, 260).toDouble(),
            padding: const EdgeInsets.all(8),
            color: Colors.white,
            child: SvgPicture.memory(
              picture.bytes,
              fit: BoxFit.contain,
              errorBuilder: (context, _, _) => const _PictureNotDrawn(),
            ),
          );
        } else {
          final width = constraints.maxWidth.isFinite
              ? (constraints.maxWidth * scale).ceil()
              : 1080;
          drawing = Image(
            key: const ValueKey('picture-drawn'),
            image: ResizeImage(
              MemoryImage(picture.bytes),
              width: width,
              height: (maxHeight * scale).ceil(),
              policy: ResizeImagePolicy.fit,
            ),
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            // Decoding takes a moment, and an image that has no frame yet
            // has no size: the placeholder stands in its place until it
            // does, so that the page does not jump.
            frameBuilder: (context, child, frame, loadedSynchronously) =>
                loadedSynchronously || frame != null
                ? child
                : const _PicturePlaceholder(),
            errorBuilder: (context, _, _) => const _PictureNotDrawn(),
          );
        }
        return Align(
          alignment: AlignmentDirectional.centerStart,
          child: HarnessTap(
            onTap: onTap,
            borderRadius: BorderRadius.circular(9),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  // An outline, so a picture as pale as the card is still one.
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: drawing,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A picture the harness gave that the app could not draw (a damaged file).
class _PictureNotDrawn extends StatelessWidget {
  const _PictureNotDrawn();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 80,
      alignment: Alignment.center,
      color: theme.colorScheme.surfaceContainerHigh,
      child: Text(
        'The picture could not be drawn.',
        style: HarnessText.caption(context),
      ),
    );
  }
}

/// Why a picture is not there, in the harness's words, and a way to ask again.
class _PictureFailure extends StatelessWidget {
  const _PictureFailure({
    required this.title,
    required this.reason,
    required this.onRetry,
  });

  final String title;
  final String reason;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('picture-failed'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              Icons.broken_image_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: HarnessText.body(context)
                      .copyWith(fontWeight: FontWeight.w600, height: 1.3),
                ),
                if (reason.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      reason,
                      style: HarnessText.caption(context),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: HarnessTextButton(
                    label: 'Try again',
                    icon: Icons.refresh_rounded,
                    dense: true,
                    onPressed: onRetry,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A picture on a page of its own, to look into: pinch to zoom, drag to move
/// about it, double-tap to zoom in on a place and again to be back.
class PictureViewerScreen extends StatefulWidget {
  const PictureViewerScreen({super.key, required this.picture, this.title});

  final Picture picture;
  final String? title;

  @override
  State<PictureViewerScreen> createState() => _PictureViewerScreenState();
}

class _PictureViewerScreenState extends State<PictureViewerScreen> {
  final _transform = TransformationController();
  Offset _doubleTapAt = Offset.zero;

  /// How far a double-tap zooms in.
  static const _zoomedIn = 3.0;

  /// The most pixels on a side a picture is decoded to on this page.
  static const _viewerSide = 4096;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    if (_transform.value.getMaxScaleOnAxis() > 1.01) {
      _transform.value = Matrix4.identity();
      return;
    }
    // Zoomed on the place that was tapped: it stays under the finger.
    final at = _doubleTapAt;
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        -at.dx * (_zoomedIn - 1),
        -at.dy * (_zoomedIn - 1),
        0,
        1,
      )
      ..scaleByDouble(_zoomedIn, _zoomedIn, _zoomedIn, 1);
  }

  @override
  Widget build(BuildContext context) {
    final picture = widget.picture;
    final title = widget.title;
    final Widget drawing = picture.isSvg
        ? Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: SvgPicture.memory(
              picture.bytes,
              fit: BoxFit.contain,
              errorBuilder: (context, _, _) => const _PictureNotDrawn(),
            ),
          )
        : Image(
            // Whole, but for one larger than a phone can hold decoded: its
            // sides are cut to what the screen can show of it zoomed.
            image: ResizeImage(
              MemoryImage(picture.bytes),
              width: _viewerSide,
              height: _viewerSide,
              policy: ResizeImagePolicy.fit,
            ),
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, _, _) => const Center(
              child: Text(
                'The picture could not be drawn.',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          );
    return Scaffold(
      key: const ValueKey('picture-viewer'),
      backgroundColor: Colors.black,
      body: Stack(
        // The picture fills the page, under the bar at its top.
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTapDown: (details) =>
                  _doubleTapAt = details.localPosition,
              onDoubleTap: _toggleZoom,
              child: InteractiveViewer(
                transformationController: _transform,
                minScale: 1,
                maxScale: 8,
                child: Semantics(
                  image: true,
                  label: title,
                  child: Center(child: drawing),
                ),
              ),
            ),
          ),
          // The bar over the top of the picture, on a shade, so that it reads
          // over a picture as pale as a page.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xA6000000), Color(0x00000000)],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 12, 10),
                  child: Row(
                    children: [
                      HarnessIconButton(
                        icon: Icons.close_rounded,
                        label: 'Close',
                        color: Colors.white,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      if (title != null && title.isNotEmpty)
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HarnessText.body(context).copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

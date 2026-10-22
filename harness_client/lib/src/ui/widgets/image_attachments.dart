import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../state/prompt_attachment.dart';

/// The most pictures one message, or one task, carries.
const maxImageAttachments = 4;

/// The largest picture a task takes, in bytes.  The harness keeps it as a file
/// and refuses a larger one, with everything sent with it.
const maxTaskImageBytes = 10 * 1024 * 1024;

/// The type of the picture [bytes] hold, read from how they start: PNG, JPEG,
/// GIF or WebP.  Null for anything else.
///
/// What a file is called, and what the picker says it is, say what it was
/// named.  The harness takes the bytes at their word, and refuses a picture
/// that is not what it claims to be.
String? sniffImageMime(Uint8List bytes) {
  bool startsWith(List<int> prefix, [int at = 0]) {
    if (bytes.length < at + prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[at + i] != prefix[i]) return false;
    }
    return true;
  }

  // 0x89 "PNG" CR LF 0x1A LF
  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  // "GIF87a" or "GIF89a"
  if (startsWith(const [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) ||
      startsWith(const [0x47, 0x49, 0x46, 0x38, 0x39, 0x61])) {
    return 'image/gif';
  }
  // "RIFF", four bytes of size, "WEBP"
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  return null;
}

/// The type a file's name says it has: for a picture [sniffImageMime] cannot
/// tell, which is sent as the JPEG a phone's camera makes unless it says
/// otherwise.
String imageMimeOfName(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
}

/// Open the photo picker and read what was chosen: at most [room] pictures,
/// none when the picker was closed with nothing.  The errors of a platform
/// that has no picker are the caller's.
Future<List<PromptAttachment>> pickImageAttachments({required int room}) async {
  if (room <= 0) return const [];
  final files = await ImagePicker().pickMultiImage(
    imageQuality: 88,
    maxWidth: 2400,
  );
  final loaded = <PromptAttachment>[];
  for (final file in files.take(room)) {
    final bytes = await file.readAsBytes();
    loaded.add(
      PromptAttachment(
        name: file.name.isEmpty ? 'image' : file.name,
        mimeType:
            sniffImageMime(bytes) ??
            file.mimeType ??
            imageMimeOfName(file.name),
        bytes: bytes,
      ),
    );
  }
  return loaded;
}

/// A picture attached to what is being written: its thumbnail, with a badge
/// in the corner that takes it away again.  The badge is inside the
/// thumbnail, so all of it can be tapped.
class ImageAttachmentThumbnail extends StatelessWidget {
  const ImageAttachmentThumbnail({
    super.key,
    required this.attachment,
    required this.onRemove,
    this.size = 58,
  });

  final PromptAttachment attachment;
  final VoidCallback onRemove;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned.fill(
            // An outline, so a picture as pale as the sheet is still a
            // thumbnail.
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  attachment.bytes,
                  fit: BoxFit.cover,
                  semanticLabel: attachment.name,
                  errorBuilder: (_, _, _) => Container(
                    color: theme.colorScheme.surfaceContainerHigh,
                    child: const Icon(Icons.broken_image_outlined, size: 20),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 3,
            top: 3,
            child: Semantics(
              button: true,
              label: 'Remove ${attachment.name}',
              child: GestureDetector(
                onTap: onRemove,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
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

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A picture attached to what is being written: a message, or a task.
class PromptAttachment {
  const PromptAttachment({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;

  /// How `session/prompt` takes it: an ACP image block.
  Map<String, Object?> toBlock() => {
    'type': 'image',
    'mimeType': mimeType,
    'data': base64Encode(bytes),
    '_harness': {'label': name},
  };

  /// How `task/submit` takes it.  A task's attachments are files of the
  /// harness's machine, which a phone cannot name, so the bytes go instead
  /// and the harness keeps them as a file of the task's own.
  Map<String, Object?> toTaskAttachment() => {
    'mime': mimeType,
    'name': name,
    'data': base64Encode(bytes),
  };
}

/// A picture that lives on the harness's machine, as the harness gives it.
/// Plain Dart, so that it is tested without a widget.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../acp/acp_message.dart';

/// The bytes of a picture and the type they are: what `session/image`
/// answers for a screenshot a task handed in, or an image a tool read, which
/// the transcript names by a path only the harness can open.
class Picture {
  const Picture({required this.bytes, required this.mime, this.name});

  /// `session/image`'s answer.  A [FormatException] says, in words for a
  /// person, that the answer holds no picture.
  factory Picture.fromWire(JsonMap wire) {
    final data = asString(wire['data']);
    if (data == null || data.isEmpty) {
      throw const FormatException('The harness sent no picture.');
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(data);
    } on FormatException {
      throw const FormatException('The picture the harness sent is damaged.');
    }
    return Picture(
      bytes: bytes,
      mime: asString(wire['mime']) ?? 'image/png',
      name: asString(wire['name']),
    );
  }

  final Uint8List bytes;

  /// `image/png`, `image/svg+xml` and the like, as the bytes say.
  final String mime;
  final String? name;

  /// A drawing in text, which is not decoded as a raster image is.
  bool get isSvg => mime.contains('svg');
}

const _drawableTypes = {
  'image/png',
  'image/jpeg',
  'image/jpg',
  'image/gif',
  'image/webp',
  'image/bmp',
  'image/x-ms-bmp',
  'image/svg+xml',
};

const _drawableExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg'};

/// Whether a file of the media type [mime], named [name], is a picture the
/// app can draw (the types the harness gives, see `session/image`): by its
/// type when it has one, else by its name's extension.  Other pictures (TIFF,
/// HEIC) are files to the app, named and not drawn.
bool isDrawablePicture(String? mime, [String? name]) {
  final type = mime?.toLowerCase().trim() ?? '';
  if (type.isNotEmpty && type != 'application/octet-stream') {
    return _drawableTypes.contains(type);
  }
  if (name == null) return false;
  final dot = name.lastIndexOf('.');
  return dot >= 0 &&
      _drawableExtensions.contains(name.substring(dot + 1).toLowerCase());
}

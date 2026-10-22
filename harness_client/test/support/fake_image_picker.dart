import 'dart:convert';
import 'dart:typed_data';

import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// A one-pixel PNG: a real picture, which the framework can draw.
final Uint8List onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// Bytes that start as a JPEG does, which is all the app reads of one.
Uint8List fakeJpeg([int length = 32]) =>
    Uint8List(length)..setAll(0, const [0xFF, 0xD8, 0xFF, 0xE0]);

/// A photo picker that gives what the test chose, the way a person would:
/// put it in place with `ImagePickerPlatform.instance = FakeImagePicker(...)`.
class FakeImagePicker extends ImagePickerPlatform
    with MockPlatformInterfaceMixin {
  FakeImagePicker(this.choose);

  /// What the person picks each time the picker opens.
  List<XFile> Function() choose;

  /// How many times the picker was opened.
  int opened = 0;

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    opened++;
    return choose();
  }
}

/// A picture as the picker hands it over.
XFile pickedImage(String name, Uint8List bytes, {String? mimeType}) =>
    // The name of a file read from memory is that of its path.
    XFile.fromData(
      bytes,
      name: name,
      path: '/photos/$name',
      mimeType: mimeType,
    );

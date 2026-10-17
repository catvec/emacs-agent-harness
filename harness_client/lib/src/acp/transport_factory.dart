/// The platform transport factory: TCP exists only where `dart:io` does.
library;

export 'transport_io.dart' if (dart.library.js_interop) 'transport_web.dart';

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'computer_file_store.dart';

/// The app's files on Android, iOS, desktop or wherever dart:io runs.
///
/// The root is `<app documents>/harness-computer`.  Only relative paths are
/// accepted; `..`, absolute paths and symbolic links are refused, and the
/// resolved path must stay under that root.  Writes go to `outbox/` and only
/// while the person has turned writing on.  Imports are copies the person
/// chose through the system picker; the agent sees the copies, not the
/// original location.
class AppComputerFileStore implements ComputerFileStore {
  AppComputerFileStore(this.root, {bool writesEnabled = false})
    : _writesEnabled = writesEnabled {
    root.createSync(recursive: true);
    Directory(p.join(root.path, 'imports')).createSync(recursive: true);
    Directory(p.join(root.path, 'outbox')).createSync(recursive: true);
  }

  static const maxFileBytes = 512 * 1024;
  static const maxWriteBytes = 256 * 1024;
  static const maxEntries = 500;

  final Directory root;
  bool _writesEnabled;

  static ComputerFileStore open({bool writesEnabled = false}) {
    // The app's own private directory, with no platform channel to wait on.
    // On a phone this is the app's cache directory: inside the sandbox, and
    // the OS may reclaim it.  Imported user files are copies here, never the
    // original path.
    final root = Directory(
      p.join(Directory.systemTemp.path, 'harness-computer'),
    );
    return AppComputerFileStore(root, writesEnabled: writesEnabled);
  }

  @override
  bool get available => true;

  @override
  bool get writesEnabled => _writesEnabled;

  @override
  Future<void> setWritesEnabled(bool enabled) async {
    _writesEnabled = enabled;
  }

  @override
  Future<Map<String, Object?>> info() async => <String, Object?>{
    'available': true,
    'root': root.path,
    'writes': _writesEnabled,
    'writable': _writesEnabled ? p.join(root.path, 'outbox') : null,
    'maxFileBytes': maxFileBytes,
    'maxWriteBytes': maxWriteBytes,
  };

  @override
  Future<ComputerFileResult> list(String path) async {
    try {
      final directory = Directory(_resolve(path));
      if (!directory.existsSync()) {
        return ComputerFileResult('No directory ${_show(path)}', isError: true);
      }
      final entries = directory.listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
      final out = <Map<String, Object?>>[];
      for (final entry in entries.take(maxEntries)) {
        final stat = entry.statSync();
        out.add(<String, Object?>{
          'name': p.basename(entry.path),
          'path': _relative(entry.path),
          'type': switch (entry) {
            Directory() => 'directory',
            Link() => 'link',
            _ => 'file',
          },
          'size': stat.size,
          'modified': stat.modified.toUtc().toIso8601String(),
        });
      }
      final text = StringBuffer('Files in ${_show(path)}');
      if (entries.length > maxEntries) {
        text.write(' (first $maxEntries of ${entries.length})');
      }
      text.write('\n');
      for (final entry in out) {
        text.write(
          '- ${entry['path']} · ${entry['type']} · ${entry['size']} B\n',
        );
      }
      if (out.isEmpty) text.write('- none');
      return ComputerFileResult(
        text.toString().trimRight(),
        structured: <String, Object?>{'path': path, 'entries': out},
      );
    } on FileSystemException catch (failure) {
      return ComputerFileResult(
        'Cannot list ${_show(path)}: ${failure.message}',
        isError: true,
      );
    }
  }

  @override
  Future<ComputerFileResult> read(
    String path, {
    int? offset,
    int? limit,
  }) async {
    try {
      final file = File(_resolve(path));
      if (!file.existsSync()) {
        return ComputerFileResult('No file ${_show(path)}', isError: true);
      }
      final stat = file.statSync();
      if (stat.size > maxFileBytes) {
        return ComputerFileResult(
          '${_show(path)} is ${stat.size} B, over the $maxFileBytes B read limit; use file_info or list a smaller file',
          isError: true,
        );
      }
      final bytes = await file.readAsBytes();
      if (_looksBinary(bytes)) {
        return ComputerFileResult(
          '${_show(path)} is binary (${stat.size} B); the mobile file tools read text only',
          isError: true,
        );
      }
      final all = utf8.decode(bytes, allowMalformed: true).split('\n');
      final first = (offset ?? 1).clamp(1, all.isEmpty ? 1 : all.length);
      final last = limit == null
          ? all.length
          : (first + limit - 1).clamp(first, all.length);
      final shown = all.sublist(first - 1, last).join('\n');
      final range = (first == 1 && last == all.length)
          ? ''
          : ' [lines $first-$last of ${all.length}]';
      return ComputerFileResult(
        '${_show(path)} (${stat.size} B)$range\n$shown',
        structured: <String, Object?>{
          'path': path,
          'size': stat.size,
          'first': first,
          'last': last,
          'lines': all.length,
        },
      );
    } on FileSystemException catch (failure) {
      return ComputerFileResult(
        'Cannot read ${_show(path)}: ${failure.message}',
        isError: true,
      );
    }
  }

  @override
  Future<ComputerFileResult> write(String path, String content) async {
    if (!_writesEnabled) {
      return const ComputerFileResult(
        'Writing is off. Ask the person to turn it on for the outbox on the Computers page.',
        isError: true,
      );
    }
    if (utf8.encode(content).length > maxWriteBytes) {
      return ComputerFileResult(
        'That content is over the $maxWriteBytes B write limit',
        isError: true,
      );
    }
    try {
      final target = _resolve(path, write: true);
      if (!p.isWithin(p.join(root.path, 'outbox'), target) &&
          target != p.join(root.path, 'outbox')) {
        return ComputerFileResult(
          'Writes go to outbox/ only; ${_show(path)} is outside it',
          isError: true,
        );
      }
      final file = File(target);
      await file.parent.create(recursive: true);
      await file.writeAsString(content, flush: true);
      return ComputerFileResult(
        'Wrote ${_show(path)} (${utf8.encode(content).length} B)',
        structured: <String, Object?>{
          'path': path,
          'bytes': utf8.encode(content).length,
        },
      );
    } on FileSystemException catch (failure) {
      return ComputerFileResult(
        'Cannot write ${_show(path)}: ${failure.message}',
        isError: true,
      );
    }
  }

  @override
  Future<ComputerFileResult> fileInfo(String path) async {
    try {
      final target = _resolve(path);
      final type = FileSystemEntity.typeSync(target, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return ComputerFileResult('No file ${_show(path)}', isError: true);
      }
      final stat = FileStat.statSync(target);
      var lines = 0;
      if (type == FileSystemEntityType.file && stat.size <= maxFileBytes) {
        final bytes = await File(target).readAsBytes();
        if (!_looksBinary(bytes)) {
          lines =
              '\n'.allMatches(utf8.decode(bytes, allowMalformed: true)).length +
              1;
        }
      }
      final kind = switch (type) {
        FileSystemEntityType.directory => 'directory',
        FileSystemEntityType.link => 'link',
        _ => 'file',
      };
      return ComputerFileResult(
        '${_show(path)} · $kind · ${stat.size} B'
        '${lines > 0 ? ' · $lines lines' : ''} · '
        '${stat.modified.toUtc().toIso8601String()}',
        structured: <String, Object?>{
          'path': path,
          'type': kind,
          'size': stat.size,
          'lines': lines,
          'modified': stat.modified.toUtc().toIso8601String(),
        },
      );
    } on FileSystemException catch (failure) {
      return ComputerFileResult(
        'Cannot read ${_show(path)}: ${failure.message}',
        isError: true,
      );
    }
  }

  @override
  Future<ComputerFileResult> importFile(
    String sourcePath, {
    String? name,
  }) async {
    try {
      final source = File(sourcePath);
      if (!source.existsSync()) {
        return ComputerFileResult('No file $sourcePath', isError: true);
      }
      if (source.lengthSync() > maxFileBytes) {
        return ComputerFileResult(
          'The selected file is ${source.lengthSync()} B, over the $maxFileBytes B import limit',
          isError: true,
        );
      }
      final safe = _safeName(name ?? p.basename(sourcePath));
      final target = _unique(p.join(root.path, 'imports', safe));
      await source.copy(target);
      return ComputerFileResult(
        'Imported ${p.basename(target)} into the app files',
        structured: <String, Object?>{
          'name': p.basename(target),
          'path': p.join('imports', p.basename(target)),
          'bytes': File(target).lengthSync(),
        },
      );
    } on FileSystemException catch (failure) {
      return ComputerFileResult(
        'Cannot import the file: ${failure.message}',
        isError: true,
      );
    }
  }

  @override
  Future<void> dispose() async {}

  String _resolve(String input, {bool write = false}) {
    final raw = input.trim().replaceAll('\\', '/');
    if (raw.contains('\u0000')) {
      throw const FileSystemException('The path holds a NUL byte');
    }
    if (raw.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(raw)) {
      throw const FileSystemException(
        'Only paths inside the app files are allowed',
      );
    }
    final normalized = p.normalize(raw);
    if (normalized == '..' || normalized.startsWith('../')) {
      throw const FileSystemException('The path leaves the app files');
    }
    final candidate = p.normalize(p.join(root.path, normalized));
    if (candidate != root.path && !p.isWithin(root.path, candidate)) {
      throw const FileSystemException('The path leaves the app files');
    }
    // A link in any part of the path is not followed: the app files are a
    // plain tree, and a link could point outside it.
    var current = root.path;
    for (final part in normalized.split('/')) {
      if (part.isEmpty || part == '.') continue;
      current = p.join(current, part);
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const FileSystemException('Symbolic links are not followed');
      }
      if (type == FileSystemEntityType.notFound) break;
    }
    if (write) {
      final parent = Directory(p.dirname(candidate));
      if (parent.existsSync()) {
        final parentType = FileSystemEntity.typeSync(
          p.dirname(candidate),
          followLinks: false,
        );
        if (parentType == FileSystemEntityType.link) {
          throw const FileSystemException('Symbolic links are not followed');
        }
      }
    }
    return candidate;
  }

  String _relative(String path) {
    final relative = p.relative(path, from: root.path);
    return relative.replaceAll('\\', '/');
  }

  String _show(String path) => path.isEmpty ? '.' : path;

  bool _looksBinary(List<int> bytes) {
    if (bytes.contains(0)) return true;
    try {
      utf8.decode(bytes);
      return false;
    } on FormatException {
      return true;
    }
  }

  String _safeName(String name) {
    final base = p.basename(name).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return base.isEmpty || base == '.' || base == '..' ? 'import' : base;
  }

  String _unique(String path) {
    if (!File(path).existsSync() && !Directory(path).existsSync()) return path;
    final extension = p.extension(path);
    final stem = p.basenameWithoutExtension(path);
    for (var index = 2; ; index++) {
      final candidate = p.join(p.dirname(path), '$stem-$index$extension');
      if (!File(candidate).existsSync() && !Directory(candidate).existsSync()) {
        return candidate;
      }
    }
  }
}

/// The platform's file store, used by the conditional factory on dart:io.
ComputerFileStore openPlatformComputerFileStore({bool writesEnabled = false}) =>
    AppComputerFileStore.open(writesEnabled: writesEnabled);

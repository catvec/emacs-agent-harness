/// A result of one scoped file operation, before it becomes an MCP tool result.
class ComputerFileResult {
  const ComputerFileResult(this.text, {this.isError = false, this.structured});

  final String text;
  final bool isError;
  final Map<String, Object?>? structured;

  Map<String, Object?> toMcpResult() => <String, Object?>{
    'content': <Object?>[
      <String, Object?>{'type': 'text', 'text': text},
    ],
    if (isError) 'isError': true,
    if (structured != null) 'structuredContent': structured,
  };
}

/// The app's files, as a computer may offer them: app documents and the
/// files a person explicitly imported into them.
///
/// Nothing here reaches outside the app sandbox.  [read] and [list] are
/// scoped to the app's computer directory; [write] is allowed only in
/// `outbox/` and only when the person turned writing on.  A user-selected
/// document is copied into `imports/` by [importFile], which the UI starts;
/// the agent never gets a file picker of its own.
abstract class ComputerFileStore {
  bool get available;
  bool get writesEnabled;
  Future<void> setWritesEnabled(bool enabled);
  Future<Map<String, Object?>> info();
  Future<ComputerFileResult> list(String path);
  Future<ComputerFileResult> read(String path, {int? offset, int? limit});
  Future<ComputerFileResult> write(String path, String content);
  Future<ComputerFileResult> fileInfo(String path);
  Future<ComputerFileResult> importFile(String sourcePath, {String? name});
  Future<void> dispose();
}

/// The store on a platform with no files (web): it says so, honestly.
class UnavailableComputerFileStore implements ComputerFileStore {
  const UnavailableComputerFileStore();

  @override
  bool get available => false;

  @override
  bool get writesEnabled => false;

  @override
  Future<void> setWritesEnabled(bool enabled) async {}

  @override
  Future<Map<String, Object?>> info() async => <String, Object?>{
    'available': false,
    'detail': 'No app files on this platform',
  };

  @override
  Future<ComputerFileResult> list(String path) async =>
      const ComputerFileResult('No app files on this platform', isError: true);

  @override
  Future<ComputerFileResult> read(
    String path, {
    int? offset,
    int? limit,
  }) async =>
      const ComputerFileResult('No app files on this platform', isError: true);

  @override
  Future<ComputerFileResult> write(String path, String content) async =>
      const ComputerFileResult('No app files on this platform', isError: true);

  @override
  Future<ComputerFileResult> fileInfo(String path) async =>
      const ComputerFileResult('No app files on this platform', isError: true);

  @override
  Future<ComputerFileResult> importFile(
    String sourcePath, {
    String? name,
  }) async =>
      const ComputerFileResult('No app files on this platform', isError: true);

  @override
  Future<void> dispose() async {}
}

import 'computer_file_store.dart';
import 'computer_file_store_no_io.dart'
    if (dart.library.io) 'app_computer_file_store.dart'
    as platform;

/// Open the app's scoped file store on a platform that has files, or the
/// honest no-file store on one that has none.
///
/// [rootPath] is the app's durable private directory, from the platform
/// channel; without one the store falls back to the process's temporary
/// directory, which is honest about being reclaimable but is not durable.
ComputerFileStore openComputerFileStore({
  bool writesEnabled = false,
  String? rootPath,
}) => platform.openPlatformComputerFileStore(
  writesEnabled: writesEnabled,
  rootPath: rootPath,
);

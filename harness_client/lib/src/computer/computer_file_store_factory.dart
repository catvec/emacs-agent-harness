import 'computer_file_store.dart';
import 'computer_file_store_no_io.dart'
    if (dart.library.io) 'app_computer_file_store.dart'
    as platform;

/// Open the app's scoped file store on a platform that has files, or the
/// honest no-file store on one that has none.
ComputerFileStore openComputerFileStore({bool writesEnabled = false}) =>
    platform.openPlatformComputerFileStore(writesEnabled: writesEnabled);

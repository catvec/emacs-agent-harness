import 'computer_file_store.dart';

/// The file store on a platform without dart:io: nothing is available.
ComputerFileStore openPlatformComputerFileStore({bool writesEnabled = false}) =>
    const UnavailableComputerFileStore();

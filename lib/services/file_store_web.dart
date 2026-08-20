import 'package:webspace/services/file_store.dart';

/// Web has no documents directory; cache-backed services run empty.
FileStore createFileStore(String directoryName) => MemoryFileStore();

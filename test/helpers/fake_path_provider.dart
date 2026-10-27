// Both packages arrive through path_provider; only tests swap the platform.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Every path_provider directory is [dir], unless [cache] or [support] names
/// its own.
class FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  FakePathProvider(this.dir, {Directory? cache, Directory? support})
      : cache = cache ?? dir,
        support = support ?? dir;

  final Directory dir;
  final Directory cache;
  final Directory support;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;

  @override
  Future<String?> getApplicationSupportPath() async => support.path;

  @override
  Future<String?> getApplicationCachePath() async => cache.path;

  @override
  Future<String?> getTemporaryPath() async => dir.path;
}

void useFakePathProvider(Directory dir, {Directory? cache, Directory? support}) =>
    PathProviderPlatform.instance =
        FakePathProvider(dir, cache: cache, support: support);

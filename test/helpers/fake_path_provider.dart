// Both packages arrive through path_provider; only tests swap the platform.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Every path_provider directory is [dir].
class FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  FakePathProvider(this.dir);

  final Directory dir;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;

  @override
  Future<String?> getApplicationSupportPath() async => dir.path;

  @override
  Future<String?> getApplicationCachePath() async => dir.path;

  @override
  Future<String?> getTemporaryPath() async => dir.path;
}

void useFakePathProvider(Directory dir) =>
    PathProviderPlatform.instance = FakePathProvider(dir);

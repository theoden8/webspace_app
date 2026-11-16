import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:webspace/controllers/archive_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/site_set_commit.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/archive_crypto.dart';
import 'package:webspace/services/archive_storage.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'isolations.dart';
import 'mock_secure_storage.dart';
import 'model_fixture.dart';

const archivePassphrase = 'correct horse';

/// Stand-in for Argon2id: a pure function of passphrase and salt, in
/// microseconds (archive_test.dart pins the real derivation).
Future<Uint8List> _derive(String passphrase, {required Uint8List? salt}) {
  final material = Uint8List(32);
  final src = salt ?? Uint8List.fromList(utf8.encode('legacy-salt'));
  for (var i = 0; i < material.length; i++) {
    material[i] = src[i % src.length];
  }
  return ArchiveCrypto.hmac(material, info: passphrase);
}

/// [ArchiveController] on the real slot pool, with the page's archive steps
/// and stores; only the platform (keychain, native containers) is faked.
class ArchiveHarness implements ArchiveHost, ArchivePrompts {
  ArchiveHarness() {
    archives = ArchiveController(
      runtime,
      host: this,
      prompts: this,
      cookieStore: cookieStore,
      proxyPasswords: proxyPasswords,
      navStates: navStates,
      archive: Archive(
          storage: ArchiveStorage(secureStorage: slots), deriveKey: _derive),
    );
  }

  /// The app tier's keychain; the slot pool has its own.
  final keychain = MockFlutterSecureStorage();
  late final cookieStore = CookieSecureStorage(secureStorage: keychain);
  late final proxyPasswords = ProxyPasswordSecureStorage(secureStorage: keychain);
  final navStates = InMemoryWebViewStateStorage();
  // Archives exist for their containers' sake: each site's opaque one is
  // deleted on close (ARCH-007).
  final runtime = SiteRuntime()..isolation = fakeContainers();
  final slots = MockFlutterSecureStorage();
  late final ArchiveController archives;
  final toasts = <String Function(AppLocalizations)>[];

  void load(List<WebViewModel> sites) => runtime.applied(SitesLoaded(sites));

  /// The site records the slot holds now, read by a second pool over the
  /// same keychain the way a relaunch would.
  Future<List<Map<String, dynamic>>> sealedSites() async {
    final fresh =
        Archive(storage: ArchiveStorage(secureStorage: slots), deriveKey: _derive);
    final handle = await fresh.tryOpen(archivePassphrase);
    final out = [
      for (final json in handle!.state.sites) Map<String, dynamic>.from(json),
    ];
    await fresh.close(handle);
    return out;
  }

  /// Adds [record] to the sealed archive as a build before ARCH-016 could:
  /// beside a site it already seals under the same id.
  Future<void> sealBeside(Map<String, dynamic> record) async {
    final raw =
        Archive(storage: ArchiveStorage(secureStorage: slots), deriveKey: _derive);
    final handle = await raw.tryOpen(archivePassphrase);
    handle!.state.sites.add(record);
    await raw.save(handle);
    await raw.close(handle);
  }

  @override
  bool get mounted => true;

  @override
  void rebuild() {}

  @override
  Future<void> endOfFrame() async {}

  @override
  void toast(
    String Function(AppLocalizations loc) message, {
    Duration? duration,
    bool floating = false,
  }) =>
      toasts.add(message);

  /// The archive steps of the page's `_commitSites`: the rows change, then a
  /// moved site's archived copy is written.
  @override
  Future<void> commitSites(SiteSetChange change) async {
    if (change is ArchiveOpened) {
      final held = _openCommit;
      _openCommit = null;
      if (held != null) {
        held._started.complete();
        await held._released.future;
      }
    }
    runtime.applied(change);
    if (change case SiteArchived(:final site, :final into)) {
      await archives.recordIn(site, into: into);
    }
  }

  @override
  SiteSetStage stageSites(SiteSetChange change) =>
      AppliedStage((commit) => runtime.apply(change, commit: commit));

  HeldRead? _openCommit;

  /// The next archive open's commit waits until released, so a test can
  /// land another change of the lists between its admission and its land.
  HeldRead holdOpenCommit() => _openCommit = HeldRead();

  HeldRead? _cookieRead;

  /// The next cookie read waits until released, so a test can land an
  /// operation inside a move.
  HeldRead holdCookies() => _cookieRead = HeldRead();

  @override
  Future<List<Cookie>> captureCookies(WebViewModel model) async {
    final held = _cookieRead;
    _cookieRead = null;
    if (held != null) {
      held._started.complete();
      await held._released.future;
    }
    return model.cookies;
  }

  @override
  Future<String?> passphrase(PassphrasePurpose purpose) async =>
      archivePassphrase;

  @override
  Future<bool> createArchive(PassphrasePurpose purpose) async => true;

  @override
  Future<bool> includeOpenArchives(int count) async => false;
}

/// A cookie read held open by [ArchiveHarness.holdCookies].
final class HeldRead {
  final _started = Completer<void>();
  final _released = Completer<void>();
  Future<void> get started => _started.future;
  void release() => _released.complete();
}

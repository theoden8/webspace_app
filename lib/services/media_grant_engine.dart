/// Per-site capture and protected-content requests, decided the same way for
/// every webview that runs as a site: decide, coalesce, persist.
///
/// Only the storage differs, which is what [GrantStore]'s two cases are:
/// [PersistedGrantStore] for the site's own webview writes through to the
/// model, and [InMemoryGrantStore] for a nested screen keeps its answers for
/// the screen's lifetime. No Flutter imports: the host passes the model and
/// its popups as interfaces, matching the engine convention in
/// `cookie_isolation.dart`.
library;

import 'package:webspace/services/site_posture.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/site_permission_state.dart';
import 'package:webspace/utils/concurrency.dart';

/// The popups and pickers that answer an unresolved request.
abstract interface class MediaPrompter {
  /// Shows the popup, or the picker for a site already set to `virtual` with
  /// no file, and returns the answer. `ask` means dismissed.
  Future<CaptureGrant> capture(
    CaptureKind kind, {
    required String origin,
    required CaptureMode current,
  });

  /// The Allow/Block popup for Widevine/EME (`PROTECTED_MEDIA_ID`).
  Future<bool> protectedContent(String origin);
}

/// The model a [PersistedGrantStore] writes through to.
abstract interface class MediaGrantRecord {
  abstract CaptureGrants captures;
  abstract bool? protectedContentAllowed;

  /// What the site runs with, the archive tier and Tracking Protection
  /// applied.
  SiteMedia get effectiveMedia;
}

/// Where one webview's media decisions are read and recorded.
sealed class GrantStore {
  GrantStore({required this.prompter, required this.isSiteActive});

  final MediaPrompter prompter;

  /// Whether the requesting site is the one on screen. A backgrounded site is
  /// denied outright (CAM-011 / MIC-011 / SHARE-011): its popup would be read
  /// as coming from the site the user is looking at, and a remembered grant
  /// would start capture with nothing on screen to attribute it to. Required
  /// so no host can wire a store without answering it. Only the grant is
  /// gated: [mode] is not, since the shims cache it per document and gating
  /// it would strand a site that enumerated while backgrounded.
  final bool Function() isSiteActive;

  /// One popup per burst: capture libraries retry `getUserMedia`. Keyed by
  /// prompt origin, so a subframe never rides the answer the user gave for
  /// the top document.
  final _inFlight = SingleFlight<(CaptureKind, String), CaptureGrant>();

  /// A subframe's answer is not persisted, but it has to outlive its popup by
  /// a moment: allowing a frame makes the shim call the real `getUserMedia`,
  /// and the platform permission request that follows arrives milliseconds
  /// later for the same origin. Keyed by prompt origin, so it only hands back
  /// the answer given for that exact frame.
  final _recentSubframe = <(CaptureKind, String), (DateTime, CaptureGrant)>{};

  static const Duration _subframeGrace = Duration(seconds: 30);

  /// A page fires several `PROTECTED_MEDIA_ID` requests while EME starts.
  final _protectedContentInFlight = SingleFlight<(), bool>();

  SiteMedia get media;

  void _recordCaptures(CaptureGrants Function(CaptureGrants stored) update);

  void _recordProtectedContent({required bool allowed});

  Future<void> _save();

  /// The site's [kind] mode, never prompting: what `enumerateDevices` reads.
  CaptureMode mode(CaptureKind kind) => kind.grantOf(media.capture).mode;

  /// Resolves a [kind] request from [origin].
  ///
  /// [isTopFrame]: a `real` grant answered a popup naming the top document,
  /// so a subframe does not inherit it and is asked under its own origin,
  /// and a subframe's answer is never written back to the site (CAM-014 /
  /// MIC-016). The device-free answers are inherited as they are.
  Future<CaptureGrant> capture(
    CaptureKind kind, {
    required String origin,
    required bool isTopFrame,
  }) async {
    if (!isSiteActive()) return (mode: kind.block, source: null);
    final current = kind.grantOf(media.capture);
    final settled = _settled(current, isTopFrame: isTopFrame);
    if (settled != null) return settled;
    final key = (kind, origin);
    if (!isTopFrame) {
      final recent = _takeRecentSubframe(key);
      if (recent != null) return recent;
    }
    return _inFlight.run(key, call: () async {
      final answer =
          await prompter.capture(kind, origin: origin, current: current.mode);
      if (isTopFrame) {
        _recordCaptures((stored) => kind.withGrant(stored, grant: (
          mode: answer.mode,
          source: answer.source ?? kind.grantOf(stored).source,
        )));
        await _save();
      } else {
        _recentSubframe[key] = (DateTime.now(), answer);
      }
      // A cancelled pick falls back to the file already on record rather
      // than serving nothing.
      return (
        mode: answer.mode,
        source: answer.source ?? kind.grantOf(media.capture).source,
      );
    });
  }

  /// The answer that needs no popup, or null when the user must be asked.
  static CaptureGrant? _settled(
    CaptureGrant grant, {
    required bool isTopFrame,
  }) => switch (grant.mode.state) {
    SitePermissionState.blocked => (mode: grant.mode, source: null),
    SitePermissionState.allowed =>
      isTopFrame ? (mode: grant.mode, source: null) : null,
    SitePermissionState.simulated => grant.source == null ? null : grant,
    SitePermissionState.ask => null,
  };

  /// Expired entries are dropped as they are found rather than on a timer.
  CaptureGrant? _takeRecentSubframe((CaptureKind, String) key) {
    final now = DateTime.now();
    _recentSubframe.removeWhere(
      (_, e) => now.difference(e.$1) > _subframeGrace,
    );
    return _recentSubframe[key]?.$2;
  }

  /// Resolves a protected-content request: the remembered answer, or one
  /// popup for the burst.
  Future<bool> protectedContent(String origin) async {
    final remembered = media.protectedContent;
    if (remembered != null) return remembered;
    return _protectedContentInFlight.run((), call: () async {
      final granted = await prompter.protectedContent(origin);
      _recordProtectedContent(allowed: granted);
      await _save();
      return granted;
    });
  }
}

/// The site's own webview: its answers are the model's, saved with it.
final class PersistedGrantStore extends GrantStore {
  PersistedGrantStore(
    this._model, {
    required super.prompter,
    required super.isSiteActive,
    required Future<void> Function() save,
  }) : _saveModel = save;

  final MediaGrantRecord _model;
  final Future<void> Function() _saveModel;

  @override
  SiteMedia get media => _model.effectiveMedia;

  @override
  void _recordCaptures(CaptureGrants Function(CaptureGrants) update) =>
      _model.captures = update(_model.captures);

  @override
  void _recordProtectedContent({required bool allowed}) =>
      _model.protectedContentAllowed = allowed;

  @override
  Future<void> _save() => _saveModel();
}

/// A nested screen: no persisted model, so its answers live as long as the
/// screen. Seeded from the opening site's nested posture, where a `real`
/// grant is already back to `ask` (CAM-005 / MIC-005, SEC-007).
final class InMemoryGrantStore extends GrantStore {
  InMemoryGrantStore(
    SiteMedia nested, {
    required super.prompter,
    required super.isSiteActive,
  }) : _media = nested;

  SiteMedia _media;

  @override
  SiteMedia get media => _media;

  @override
  void _recordCaptures(CaptureGrants Function(CaptureGrants) update) =>
      _media = (
        capture: update(_media.capture),
        protectedContent: _media.protectedContent,
      );

  @override
  void _recordProtectedContent({required bool allowed}) =>
      _media = (capture: _media.capture, protectedContent: allowed);

  @override
  Future<void> _save() async {}
}

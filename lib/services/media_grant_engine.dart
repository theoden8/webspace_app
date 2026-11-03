/// Per-site capture, protected-content, location and notification requests,
/// decided the same way for every webview that runs as a site: decide,
/// coalesce, persist.
///
/// The site's own documents follow the site's settings, whose storage is
/// what [GrantStore]'s two cases differ in: [PersistedGrantStore] for the
/// site's own webview writes through to the model, and [InMemoryGrantStore]
/// for a nested screen keeps its answers for the screen's lifetime. A
/// document of another origin is asked for itself, and its answer is kept in
/// the site's [OriginMemory], which every surface of the site shares
/// (PERM-002). No Flutter imports: the host passes the model and its popups
/// as interfaces, matching the engine convention in `cookie_isolation.dart`.
library;

import 'package:webspace/services/site_origins.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/origin_choices.dart';
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

  /// The Allow/Block popup for [permission] that a document of [origin], not
  /// one of the site's own, asks for. Null means dismissed.
  Future<bool?> originAccess(SitePermission permission, {required String origin});

  /// The words of the notification Android shows while [origin] shares the
  /// screen.
  ShareNotice shareNotice(String origin);
}

/// The notification a running screen share keeps up: its title, its text,
/// and the label of its stop button.
typedef ShareNotice = ({String title, String text, String stop});

/// The model a [PersistedGrantStore] writes through to.
abstract interface class MediaGrantRecord {
  abstract CaptureGrants captures;
  abstract bool? protectedContentAllowed;

  /// What the site runs with, the archive tier and Tracking Protection
  /// applied.
  SiteMedia get effectiveMedia;

  abstract OriginChoices originChoices;
}

/// Where a site's answers to documents of other origins are kept
/// (PERM-002): every surface that runs as the site reads and adds to the
/// same ones.
sealed class OriginMemory {
  /// [site]'s, saved with it; while no site is in hand (one deleted while
  /// its nested screen was open), the surface's own.
  static OriginMemory of(
    MediaGrantRecord? site, {
    required Future<void> Function() save,
  }) => site == null ? TransientOrigins() : SavedOrigins(site, save: save);

  OriginChoices get choices;

  Future<void> remember(
    SitePermission permission, {
    required String origin,
    required bool allowed,
  });

  /// [OriginChoices.afterModeChange], unsaved: the caller saves the mode
  /// change with it.
  void followMode(
    SitePermission permission, {
    required SitePermissionState from,
    required SitePermissionState to,
  });
}

/// The site's model, saved with it.
final class SavedOrigins extends OriginMemory {
  SavedOrigins(this._record, {required Future<void> Function() save})
    : _save = save;

  final MediaGrantRecord _record;
  final Future<void> Function() _save;

  @override
  OriginChoices get choices => _record.originChoices;

  @override
  Future<void> remember(
    SitePermission permission, {
    required String origin,
    required bool allowed,
  }) {
    _record.originChoices = _record.originChoices.remember(
      permission,
      origin: origin,
      allowed: allowed,
    );
    return _save();
  }

  @override
  void followMode(
    SitePermission permission, {
    required SitePermissionState from,
    required SitePermissionState to,
  }) => _record.originChoices = _record.originChoices.afterModeChange(
    permission,
    from: from,
    to: to,
  );
}

/// No site to keep them on (a nested screen whose site was deleted while it
/// was open): kept while the surface lives.
final class TransientOrigins extends OriginMemory {
  @override
  OriginChoices choices = OriginChoices.none;

  @override
  Future<void> remember(
    SitePermission permission, {
    required String origin,
    required bool allowed,
  }) async {
    choices = choices.remember(permission, origin: origin, allowed: allowed);
  }

  @override
  void followMode(
    SitePermission permission, {
    required SitePermissionState from,
    required SitePermissionState to,
  }) => choices = choices.afterModeChange(permission, from: from, to: to);
}

/// Where one webview's media decisions are read and recorded.
sealed class GrantStore {
  GrantStore({
    required this.prompter,
    required this.isSiteActive,
    required this.origins,
  });

  final MediaPrompter prompter;

  /// The site's answers to documents of other origins (PERM-002).
  final OriginMemory origins;

  /// Whether the requesting site is the one on screen. A backgrounded site is
  /// denied outright (CAM-011 / MIC-011 / SHARE-011): its popup would be read
  /// as coming from the site the user is looking at, and a remembered grant
  /// would start capture with nothing on screen to attribute it to. Required
  /// so no host can wire a store without answering it. Only the grant is
  /// gated: [mode] is not, since the shims cache it per document and gating
  /// it would strand a site that enumerated while backgrounded.
  final bool Function() isSiteActive;

  /// One popup per burst: capture libraries retry `getUserMedia`.
  final _inFlight = SingleFlight<CaptureKind, CaptureGrant>();

  /// A page fires several `PROTECTED_MEDIA_ID` requests while EME starts.
  final _protectedContentInFlight = SingleFlight<(), bool>();

  /// [_inFlight] for a document of another origin, by what it asks and its
  /// origin, so one origin never rides the answer another was given.
  final _originInFlight = SingleFlight<(SitePermission, String), bool>();

  SiteMedia get media;

  void _recordCaptures(CaptureGrants Function(CaptureGrants stored) update);

  void _recordProtectedContent({required bool allowed});

  Future<void> _save();

  /// The [kind] mode a document of [origin] reads, never prompting: what
  /// `enumerateDevices` reads. The site's own documents read the site's; any
  /// other reads its own remembered answer, else ask, except that a block
  /// holds for all and an embedded frame takes the site's file (PERM-002).
  CaptureMode mode(
    CaptureKind kind, {
    required String origin,
    required Standing standing,
  }) {
    final mode = kind.grantOf(media.capture).mode;
    if (standing == Standing.own || _takesSite(mode.state, standing)) {
      return mode;
    }
    return switch (origins.choices.of(
      SitePermission.ofCapture(kind),
      origin: origin,
    )) {
      true => kind.real,
      false => kind.block,
      null => kind.ask,
    };
  }

  /// Whether a document of another origin takes the site's [state] rather
  /// than an answer of its own: a block holds for every origin, and a frame
  /// the site's page embedded takes the site's file (CAM-014 / MIC-016).
  static bool _takesSite(SitePermissionState state, Standing standing) =>
      switch (state) {
        SitePermissionState.blocked => true,
        SitePermissionState.simulated => standing == Standing.embedded,
        SitePermissionState.allowed || SitePermissionState.ask => false,
      };

  /// Resolves a [kind] request from [origin], which stands toward the site
  /// as [standing] says.
  ///
  /// The site's own documents follow the site's mode: a remembered `real`
  /// serves them and their answer is saved as the site's. Any other origin
  /// takes the site's block, and an embedded frame its file; otherwise it is
  /// asked Allow or Block for itself once, and its answer is remembered for
  /// that origin, never written to the site's mode (PERM-002).
  Future<CaptureGrant> capture(
    CaptureKind kind, {
    required String origin,
    required Standing standing,
  }) async {
    if (!isSiteActive()) return (mode: kind.block, source: null);
    final current = kind.grantOf(media.capture);
    if (standing != Standing.own) {
      if (_takesSite(current.mode.state, standing)) {
        return (
          mode: current.mode,
          source: current.mode == kind.block ? null : current.source,
        );
      }
      // The site's file is the site's (PERM-002): where no real device is
      // offered, another origin has nothing to be allowed.
      if (!kind.realOffered) return (mode: kind.block, source: null);
      final allowed = await _askOrigin(
        SitePermission.ofCapture(kind),
        origin: origin,
      );
      return (mode: allowed ? kind.real : kind.block, source: null);
    }
    final settled = _settled(current);
    if (settled != null) return settled;
    return _inFlight.run(kind, call: () async {
      final answer = await prompter.capture(
        kind,
        origin: origin,
        current: current.mode,
      );
      _recordCaptures((stored) => kind.withGrant(stored, grant: (
        mode: answer.mode,
        source: answer.source ?? kind.grantOf(stored).source,
      )));
      origins.followMode(
        SitePermission.ofCapture(kind),
        from: current.mode.state,
        to: answer.mode.state,
      );
      await _save();
      // A cancelled pick falls back to the file already on record rather
      // than serving nothing.
      return (
        mode: answer.mode,
        source: answer.source ?? kind.grantOf(media.capture).source,
      );
    });
  }

  /// The answer the site's own document gets without a popup, or null when
  /// the user must be asked.
  static CaptureGrant? _settled(CaptureGrant grant) =>
      switch (grant.mode.state) {
        SitePermissionState.blocked ||
        SitePermissionState.allowed => (mode: grant.mode, source: null),
        SitePermissionState.simulated => grant.source == null ? null : grant,
        SitePermissionState.ask => null,
      };

  /// What a document of [origin], not one of the site's own, was answered
  /// for [permission], or one popup for the burst whose answer is remembered
  /// for that origin (PERM-002). A dismissed popup is denied this once and
  /// asked again next time.
  Future<bool> _askOrigin(
    SitePermission permission, {
    required String origin,
  }) async {
    final kept = origins.choices.of(permission, origin: origin);
    if (kept != null) return kept;
    if (!isSiteActive()) return false;
    return _originInFlight.run((permission, origin), call: () async {
      final answer = await prompter.originAccess(permission, origin: origin);
      if (answer == null) return false;
      await origins.remember(permission, origin: origin, allowed: answer);
      return answer;
    });
  }

  /// Resolves a protected-content request from [origin]: for the site's own
  /// documents the site's remembered answer, or one popup for the burst; any
  /// other origin takes the site's block, else is asked for itself once
  /// (PERM-002).
  Future<bool> protectedContent(
    String origin, {
    required Standing standing,
  }) async {
    final remembered = media.protectedContent;
    if (standing != Standing.own) {
      if (remembered == false) return false;
      return _askOrigin(SitePermission.protectedContent, origin: origin);
    }
    if (remembered != null) return remembered;
    return _protectedContentInFlight.run((), call: () async {
      final granted = await prompter.protectedContent(origin);
      _recordProtectedContent(allowed: granted);
      origins.followMode(
        SitePermission.protectedContent,
        from: SitePermissionState.ask,
        to: protectedContentPermissionState(allowed: granted),
      );
      await _save();
      return granted;
    });
  }

  /// Whether a document of [origin] gets the device's live location, the
  /// site serving it ([live]): its own documents do, any other origin is
  /// asked for itself once (LOC-012, PERM-002).
  Future<bool> location(
    String origin, {
    required Standing standing,
    required bool live,
  }) async {
    if (!live) return false;
    if (standing == Standing.own) return true;
    return _askOrigin(SitePermission.location, origin: origin);
  }

  /// Whether a document of [origin] may notify, the site's notifications
  /// being on ([enabled]): its own documents may, any other origin is asked
  /// for itself once (NOTIF-020, PERM-002).
  Future<bool> notifications(
    String origin, {
    required Standing standing,
    required bool enabled,
  }) async {
    if (!enabled) return false;
    if (standing == Standing.own) return true;
    return _askOrigin(SitePermission.notifications, origin: origin);
  }
}

/// The site's own webview: its answers are the model's, saved with it.
final class PersistedGrantStore extends GrantStore {
  PersistedGrantStore(
    MediaGrantRecord model, {
    required super.prompter,
    required super.isSiteActive,
    required Future<void> Function() save,
  }) : _model = model,
       _saveModel = save,
       super(origins: SavedOrigins(model, save: save));

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
    required super.origins,
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

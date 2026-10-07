/// Per-site capture: the camera, the microphone and screen sharing, written
/// once over [CaptureKind].
///
/// Each kind keeps its own mode enum, so a mode cannot be stored under the
/// wrong kind and screen sharing's missing `real` stays a compile-time fact.
/// Everything else (the stored grant, the answer handed to the page, the JSON,
/// the bridge, the nested and archive rules) is stated here once and reached
/// through the kind.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'package:webspace/settings/site_permission_state.dart';

/// A capture mode of any kind. Sealed, so a `switch` over the modes of every
/// kind is exhaustive.
sealed class CaptureMode implements Enum {
  /// The mode in the vocabulary every per-site capability shares.
  SitePermissionState get state;
}

/// Camera-only `getUserMedia`, e.g. a banking site's QR scanner.
///
/// - [ask]: the first request shows the Block / Use a file / Allow popup and
///   records the answer.
/// - [real]: the device camera is handed to the page (on Android after the
///   app-level CAMERA permission, checked at every grant so an OS denial is
///   never frozen into a per-site Block).
/// - [virtual]: the page gets a stream drawn from a picked image or looped
///   video through a canvas `captureStream()`; the camera is never opened.
/// - [block]: requests are rejected with `NotAllowedError`, as if the user had
///   denied a browser prompt.
enum CameraAccessMode implements CaptureMode {
  ask(SitePermissionState.ask),
  real(SitePermissionState.allowed),
  virtual(SitePermissionState.simulated),
  block(SitePermissionState.blocked);

  const CameraAccessMode(this.state);

  @override
  final SitePermissionState state;
}

/// Any `getUserMedia` that asks for audio.
///
/// [real] hands over the device microphone only while the site is the one on
/// screen, ends it when the site leaves the screen, and needs the app-level
/// recording permission (MIC-014, MIC-015). [virtual] loops a picked clip
/// through WebAudio; no recording permission is involved.
///
/// An older build that does not know a stored name reads it as [ask], so a
/// downgrade turns a grant into a prompt, never the reverse.
enum MicrophoneAccessMode implements CaptureMode {
  ask(SitePermissionState.ask),
  real(SitePermissionState.allowed),
  virtual(SitePermissionState.simulated),
  block(SitePermissionState.blocked);

  const MicrophoneAccessMode(this.state);

  @override
  final SitePermissionState state;
}

/// `getDisplayMedia`.
///
/// There is deliberately no mode that hands over the real screen, and adding
/// one is not a matter of platform plumbing: a display capture is
/// whole-surface by construction. On Android the only route is
/// `MediaProjection`, which mirrors the entire device, and on any platform the
/// app's own window holds the drawer, the tab strip and whichever other site
/// the user switches to. A site granted a real screen would watch every other
/// site in the webspace, which is the one thing per-site isolation exists to
/// prevent. [virtual] serves a picked image or video as the shared surface.
enum ScreenShareMode implements CaptureMode {
  ask(SitePermissionState.ask),
  virtual(SitePermissionState.simulated),
  block(SitePermissionState.blocked);

  const ScreenShareMode(this.state);

  @override
  final SitePermissionState state;
}

/// A file the user picked to serve in place of a device.
///
/// The bytes live inline as a `data:` URL: the page's origin cannot read a
/// `file://` path, and on the model they ride settings backups and the
/// archive's encrypted slice like `customIconPng`.
@immutable
sealed class VirtualSource {
  const VirtualSource({required this.dataUrl, required this.fileName});

  /// `data:<mime>;base64,...`
  final String dataUrl;

  /// Shown in settings so the user can tell which file a site uses. Never
  /// sent to the page.
  final String fileName;

  /// The decoded payload, or null when the URL carries no base64 body.
  Uint8List? get bytes {
    const marker = ';base64,';
    final at = dataUrl.indexOf(marker);
    if (at < 0) return null;
    try {
      return base64Decode(dataUrl.substring(at + marker.length));
    } on FormatException {
      return null;
    }
  }

  Map<String, Object> toJson();

  /// What the shim reads.
  Map<String, Object> toBridgeJson();
}

/// A still image drawn onto the capture canvas, or a video looped onto it.
final class VirtualVisualSource extends VirtualSource {
  const VirtualVisualSource({
    required this.kind,
    required super.dataUrl,
    required super.fileName,
  });

  /// `image` or `video`: whether the shim draws a still frame or drives a
  /// looping `<video>`.
  final String kind;

  bool get isVideo => kind == 'video';

  static VirtualVisualSource fromPick(PickedMedia picked) =>
      VirtualVisualSource(
        kind: picked.isVideo ? 'video' : 'image',
        dataUrl: picked.dataUrl,
        fileName: picked.fileName,
      );

  /// Null for anything but a stored image or video `data:` URL, so a crafted
  /// backup cannot smuggle in a fetch.
  static VirtualVisualSource? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = json['kind'];
    final dataUrl = json['dataUrl'];
    if (kind != 'image' && kind != 'video') return null;
    if (dataUrl is! String || !dataUrl.startsWith('data:')) return null;
    return VirtualVisualSource(
      kind: kind as String,
      dataUrl: dataUrl,
      fileName: json['fileName'] is String ? json['fileName'] as String : '',
    );
  }

  @override
  Map<String, Object> toJson() =>
      {'kind': kind, 'dataUrl': dataUrl, 'fileName': fileName};

  @override
  Map<String, Object> toBridgeJson() => {'kind': kind, 'dataUrl': dataUrl};

  @override
  bool operator ==(Object other) =>
      other is VirtualVisualSource &&
      other.kind == kind &&
      other.dataUrl == dataUrl &&
      other.fileName == fileName;

  @override
  int get hashCode => Object.hash(kind, dataUrl, fileName);
}

/// An audio clip, decoded once by the shim and looped forever.
final class VirtualAudioSource extends VirtualSource {
  const VirtualAudioSource({required super.dataUrl, required super.fileName});

  static VirtualAudioSource fromPick(PickedMedia picked) =>
      VirtualAudioSource(dataUrl: picked.dataUrl, fileName: picked.fileName);

  static VirtualAudioSource? fromJson(Object? json) {
    if (json is! Map) return null;
    final dataUrl = json['dataUrl'];
    if (dataUrl is! String || !dataUrl.startsWith('data:')) return null;
    return VirtualAudioSource(
      dataUrl: dataUrl,
      fileName: json['fileName'] is String ? json['fileName'] as String : '',
    );
  }

  @override
  Map<String, Object> toJson() => {'dataUrl': dataUrl, 'fileName': fileName};

  @override
  Map<String, Object> toBridgeJson() => {'dataUrl': dataUrl};

  @override
  bool operator ==(Object other) =>
      other is VirtualAudioSource &&
      other.dataUrl == dataUrl &&
      other.fileName == fileName;

  @override
  int get hashCode => Object.hash(dataUrl, fileName);
}

/// A picked file, already stripped of metadata and encoded.
typedef PickedMedia = ({String dataUrl, String fileName, bool isVideo});

/// What a kind serves in place of its device: which files the picker offers,
/// and the source a stored or picked file becomes.
enum CaptureMedium<S extends VirtualSource> {
  visual<VirtualVisualSource>(
    parse: VirtualVisualSource.fromJson,
    fromPick: VirtualVisualSource.fromPick,
  ),
  audio<VirtualAudioSource>(
    parse: VirtualAudioSource.fromJson,
    fromPick: VirtualAudioSource.fromPick,
  );

  const CaptureMedium({required this.parse, required this.fromPick});

  final S? Function(Object? json) parse;
  final S Function(PickedMedia picked) fromPick;
}

/// A site's decision for one kind: the mode, and the file a `virtual` mode
/// serves. Also the answer to one request, where `ask` means the popup was
/// dismissed: denied this once and asked again next time.
typedef CaptureGrant<M extends CaptureMode, S extends VirtualSource> = ({
  M mode,
  S? source,
});

/// A grant of any kind.
typedef AnyCaptureGrant = CaptureGrant<CaptureMode, VirtualSource>;

extension CaptureGrantBridge on AnyCaptureGrant {
  /// The `{mode, source?}` the shim reads. `ask` degrades to `block`: an
  /// unresolved decision must never read as a grant.
  Map<String, Object> toBridgeJson() => switch (mode.state) {
    SitePermissionState.ask ||
    SitePermissionState.blocked => const {'mode': 'block'},
    SitePermissionState.allowed => {'mode': mode.name},
    SitePermissionState.simulated => {
      'mode': mode.name,
      if (source case final source?) 'source': source.toBridgeJson(),
    },
  };
}

typedef _CaptureJsonKeys = ({String mode, String source});

/// A device a kind's shim publishes in `enumerateDevices`: its
/// `MediaDeviceInfo.kind`, and the non-prompting bridge handler the shim reads
/// the site's mode from before deciding to publish it.
typedef PublishedDevice = ({String deviceKind, String modeHandler});

/// The capture kinds, each carrying what is fixed about it. The type
/// arguments tie a kind to its mode enum and its source, so code handed
/// `CaptureKind.camera` reads and writes camera values without a cast.
enum CaptureKind<M extends CaptureMode, S extends VirtualSource> {
  camera<CameraAccessMode, VirtualVisualSource>(
    modes: CameraAccessMode.values,
    ask: CameraAccessMode.ask,
    virtual: CameraAccessMode.virtual,
    block: CameraAccessMode.block,
    real: CameraAccessMode.real,
    medium: CaptureMedium.visual,
    of: _camera,
    put: _withCamera,
    json: (mode: 'cameraMode', source: 'virtualCameraSource'),
    legacyAllowedKey: 'cameraAllowed',
    requestHandler: 'webCameraRequest',
    publishedDevice: (deviceKind: 'videoinput', modeHandler: 'webCameraMode'),
    shimGroup: 'camera_stream',
    reachesSubframes: true,
  ),
  microphone<MicrophoneAccessMode, VirtualAudioSource>(
    modes: MicrophoneAccessMode.values,
    ask: MicrophoneAccessMode.ask,
    virtual: MicrophoneAccessMode.virtual,
    block: MicrophoneAccessMode.block,
    real: MicrophoneAccessMode.real,
    medium: CaptureMedium.audio,
    of: _microphone,
    put: _withMicrophone,
    json: (mode: 'microphoneMode', source: 'virtualMicrophoneSource'),
    legacyAllowedKey: null,
    requestHandler: 'webMicrophoneRequest',
    publishedDevice: (
      deviceKind: 'audioinput',
      modeHandler: 'webMicrophoneMode',
    ),
    shimGroup: 'microphone_stream',
    reachesSubframes: true,
  ),

  /// Top-level document only (SHARE-005): a screen share is the grant a user
  /// is least willing to have redirected, and a third-party frame is not who
  /// they answered the popup for.
  screenShare<ScreenShareMode, VirtualVisualSource>(
    modes: ScreenShareMode.values,
    ask: ScreenShareMode.ask,
    virtual: ScreenShareMode.virtual,
    block: ScreenShareMode.block,
    real: null,
    medium: CaptureMedium.visual,
    of: _screenShare,
    put: _withScreenShare,
    json: (mode: 'screenShareMode', source: 'virtualScreenSource'),
    legacyAllowedKey: null,
    requestHandler: 'webScreenShareRequest',
    publishedDevice: null,
    shimGroup: 'screen_share',
    reachesSubframes: false,
  );

  const CaptureKind({
    required this.modes,
    required this.ask,
    required this.virtual,
    required this.block,
    required this.real,
    required this.medium,
    required CaptureGrant<M, S> Function(CaptureGrants) of,
    required CaptureGrants Function(CaptureGrants, CaptureGrant<M, S>) put,
    required _CaptureJsonKeys json,
    required this.legacyAllowedKey,
    required this.requestHandler,
    required this.publishedDevice,
    required this.shimGroup,
    required this.reachesSubframes,
  }) : _of = of,
       _put = put,
       _json = json;

  final List<M> modes;
  final M ask;
  final M virtual;
  final M block;

  /// The mode that hands over the device; null where none may exist.
  final M? real;

  final CaptureMedium<S> medium;

  /// A boolean the mode replaced, read when no mode is stored: true meant
  /// allow, false block.
  final String? legacyAllowedKey;

  /// The JS bridge handler the shim asks for a decision, and the Dart side
  /// registers. One constant for both, so they cannot drift apart.
  final String requestHandler;

  /// Null for a kind whose shim publishes no device.
  final PublishedDevice? publishedDevice;

  /// The `UserScript` group the kind's shim is injected under.
  final String shimGroup;

  /// Whether the shim and its bridge serve subframes. A cross-origin frame
  /// still never inherits a `real` grant (CAM-014 / MIC-016).
  final bool reachesSubframes;

  // Read only through `this`: from a receiver typed with the bounds, the
  // contravariant [_put] fails Dart's covariance check.
  final CaptureGrant<M, S> Function(CaptureGrants) _of;
  final CaptureGrants Function(CaptureGrants, CaptureGrant<M, S>) _put;
  final _CaptureJsonKeys _json;

  CaptureGrant<M, S> grantOf(CaptureGrants grants) => _of(grants);

  CaptureGrants withGrant(CaptureGrants grants, CaptureGrant<M, S> grant) =>
      _put(grants, grant);

  /// Calls [use] with this kind at its own type arguments, which code holding
  /// a kind from [values] cannot name.
  R open<R>(
    R Function<M2 extends CaptureMode, S2 extends VirtualSource>(
      CaptureKind<M2, S2> kind,
    ) use,
  ) => use<M, S>(this);

  CaptureGrants _map(CaptureGrants grants, M Function(M mode) f) {
    final grant = _of(grants);
    return _put(grants, (mode: f(grant.mode), source: grant.source));
  }

  CaptureGrants _blocked(CaptureGrants grants) => _map(grants, (_) => block);

  CaptureGrants _unreal(CaptureGrants grants) => _map(
    grants,
    (mode) => mode.state == SitePermissionState.allowed ? ask : mode,
  );

  CaptureGrants _read(CaptureGrants grants, Map<String, dynamic> json) {
    final legacy = legacyAllowedKey == null ? null : json[legacyAllowedKey];
    final mode = modes.asNameMap()[json[_json.mode]] ??
        switch (legacy) {
          true => real ?? block,
          false => block,
          _ => ask,
        };
    return _put(grants, (mode: mode, source: medium.parse(json[_json.source])));
  }

  /// Only what differs from an untouched site, so its JSON stays as it was.
  Map<String, Object> _write(CaptureGrants grants) {
    final grant = _of(grants);
    return {
      if (grant.mode != ask) _json.mode: grant.mode.name,
      if (grant.source case final source?) _json.source: source.toJson(),
    };
  }

  /// The keys a site's JSON carries for this kind.
  List<String> get jsonKeys => [_json.mode, _json.source];
}

CaptureGrant<CameraAccessMode, VirtualVisualSource> _camera(CaptureGrants g) =>
    g.camera;
CaptureGrant<MicrophoneAccessMode, VirtualAudioSource> _microphone(
  CaptureGrants g,
) => g.microphone;
CaptureGrant<ScreenShareMode, VirtualVisualSource> _screenShare(
  CaptureGrants g,
) => g.screenShare;
CaptureGrants _withCamera(
  CaptureGrants g,
  CaptureGrant<CameraAccessMode, VirtualVisualSource> v,
) => g.copyWith(camera: v);
CaptureGrants _withMicrophone(
  CaptureGrants g,
  CaptureGrant<MicrophoneAccessMode, VirtualAudioSource> v,
) => g.copyWith(microphone: v);
CaptureGrants _withScreenShare(
  CaptureGrants g,
  CaptureGrant<ScreenShareMode, VirtualVisualSource> v,
) => g.copyWith(screenShare: v);

/// A site's decision for every kind.
@immutable
final class CaptureGrants {
  const CaptureGrants({
    required this.camera,
    required this.microphone,
    required this.screenShare,
  });

  /// An untouched site: every kind asks.
  static const CaptureGrants none = CaptureGrants(
    camera: (mode: CameraAccessMode.ask, source: null),
    microphone: (mode: MicrophoneAccessMode.ask, source: null),
    screenShare: (mode: ScreenShareMode.ask, source: null),
  );

  final CaptureGrant<CameraAccessMode, VirtualVisualSource> camera;
  final CaptureGrant<MicrophoneAccessMode, VirtualAudioSource> microphone;
  final CaptureGrant<ScreenShareMode, VirtualVisualSource> screenShare;

  CaptureGrants copyWith({
    CaptureGrant<CameraAccessMode, VirtualVisualSource>? camera,
    CaptureGrant<MicrophoneAccessMode, VirtualAudioSource>? microphone,
    CaptureGrant<ScreenShareMode, VirtualVisualSource>? screenShare,
  }) => CaptureGrants(
    camera: camera ?? this.camera,
    microphone: microphone ?? this.microphone,
    screenShare: screenShare ?? this.screenShare,
  );

  /// Reads the keys [CaptureKind] owns; a wrong-typed or unknown value reads
  /// as absent. `cameraAllowed` is the legacy boolean the camera mode
  /// replaced.
  static CaptureGrants fromJson(Map<String, dynamic> json) =>
      CaptureKind.values.fold(none, (g, kind) => kind._read(g, json));

  Map<String, Object> toJson() => {
    for (final kind in CaptureKind.values) ...kind._write(this),
  };

  /// Every kind blocked, the stored files kept.
  CaptureGrants blocked() =>
      CaptureKind.values.fold(this, (g, kind) => kind._blocked(g));

  /// Every `real` grant back to `ask`; the device-free answers kept.
  CaptureGrants withoutRealGrants() =>
      CaptureKind.values.fold(this, (g, kind) => kind._unreal(g));

  @override
  bool operator ==(Object other) =>
      other is CaptureGrants &&
      other.camera == camera &&
      other.microphone == microphone &&
      other.screenShare == screenShare;

  @override
  int get hashCode => Object.hash(camera, microphone, screenShare);
}

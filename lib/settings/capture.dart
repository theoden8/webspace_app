/// Per-site capture: the camera, the microphone and screen sharing, written
/// once over [CaptureKind].
///
/// Each kind keeps its own mode enum, so screen sharing's missing `real` stays
/// a compile-time fact.
/// Everything else (the stored grant, the answer handed to the page, the JSON,
/// the bridge, the nested and archive rules) is stated here once and reached
/// through the kind.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'package:webspace/settings/shim_frames.dart';
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
enum CaptureMedium {
  visual(
    parse: VirtualVisualSource.fromJson,
    fromPick: VirtualVisualSource.fromPick,
  ),
  audio(
    parse: VirtualAudioSource.fromJson,
    fromPick: VirtualAudioSource.fromPick,
  );

  const CaptureMedium({required this.parse, required this.fromPick});

  final VirtualSource? Function(Object? json) parse;
  final VirtualSource Function(PickedMedia picked) fromPick;
}

/// A site's decision for one kind: the mode, and the file a `virtual` mode
/// serves. Also the answer to one request, where `ask` means the popup was
/// dismissed: denied this once and asked again next time.
typedef CaptureGrant = ({CaptureMode mode, VirtualSource? source});

extension CaptureGrantBridge on CaptureGrant {
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

/// The capture kinds, each carrying what is fixed about it.
enum CaptureKind {
  camera(
    modes: CameraAccessMode.values,
    ask: CameraAccessMode.ask,
    virtual: CameraAccessMode.virtual,
    block: CameraAccessMode.block,
    real: CameraAccessMode.real,
    medium: CaptureMedium.visual,
    json: (mode: 'cameraMode', source: 'virtualCameraSource'),
    legacyAllowedKey: 'cameraAllowed',
    requestHandler: 'webCameraRequest',
    publishedDevice: (deviceKind: 'videoinput', modeHandler: 'webCameraMode'),
    shimGroup: 'camera_stream',
    frames: ShimFrames.all,
  ),
  microphone(
    modes: MicrophoneAccessMode.values,
    ask: MicrophoneAccessMode.ask,
    virtual: MicrophoneAccessMode.virtual,
    block: MicrophoneAccessMode.block,
    real: MicrophoneAccessMode.real,
    medium: CaptureMedium.audio,
    json: (mode: 'microphoneMode', source: 'virtualMicrophoneSource'),
    legacyAllowedKey: null,
    requestHandler: 'webMicrophoneRequest',
    publishedDevice: (
      deviceKind: 'audioinput',
      modeHandler: 'webMicrophoneMode',
    ),
    shimGroup: 'microphone_stream',
    frames: ShimFrames.all,
  ),

  /// Top-level document only (SHARE-005): a screen share is the grant a user
  /// is least willing to have redirected, and a third-party frame is not who
  /// they answered the popup for.
  screenShare(
    modes: ScreenShareMode.values,
    ask: ScreenShareMode.ask,
    virtual: ScreenShareMode.virtual,
    block: ScreenShareMode.block,
    real: null,
    medium: CaptureMedium.visual,
    json: (mode: 'screenShareMode', source: 'virtualScreenSource'),
    legacyAllowedKey: null,
    requestHandler: 'webScreenShareRequest',
    publishedDevice: null,
    shimGroup: 'screen_share',
    frames: ShimFrames.top,
  );

  const CaptureKind({
    required this.modes,
    required this.ask,
    required this.virtual,
    required this.block,
    required this.real,
    required this.medium,
    required _CaptureJsonKeys json,
    required this.legacyAllowedKey,
    required this.requestHandler,
    required this.publishedDevice,
    required this.shimGroup,
    required this.frames,
  }) : _json = json;

  final List<CaptureMode> modes;
  final CaptureMode ask;
  final CaptureMode virtual;
  final CaptureMode block;

  /// The mode that hands over the device; null where none may exist.
  final CaptureMode? real;

  final CaptureMedium medium;

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

  /// The frames the shim and its bridge serve. A cross-origin frame still
  /// never inherits a `real` grant (CAM-014 / MIC-016).
  final ShimFrames frames;

  final _CaptureJsonKeys _json;

  CaptureGrant grantOf(CaptureGrants grants) => switch (this) {
    camera => grants.camera,
    microphone => grants.microphone,
    screenShare => grants.screenShare,
  };

  CaptureGrants withGrant(CaptureGrants grants, CaptureGrant grant) {
    assert(modes.contains(grant.mode), '$name cannot hold ${grant.mode}');
    return switch (this) {
      camera => grants.copyWith(camera: grant),
      microphone => grants.copyWith(microphone: grant),
      screenShare => grants.copyWith(screenShare: grant),
    };
  }

  CaptureGrant _fromJson(Map<String, dynamic> json) {
    final legacy = legacyAllowedKey == null ? null : json[legacyAllowedKey];
    final mode = modes.asNameMap()[json[_json.mode]] ??
        switch (legacy) {
          true => real ?? block,
          false => block,
          _ => ask,
        };
    return (mode: mode, source: medium.parse(json[_json.source]));
  }

  /// Only what differs from an untouched site, so its JSON stays as it was.
  Map<String, Object> _toJson(CaptureGrant grant) => {
    if (grant.mode != ask) _json.mode: grant.mode.name,
    if (grant.source case final source?) _json.source: source.toJson(),
  };

  /// The keys a site's JSON carries for this kind.
  List<String> get jsonKeys => [_json.mode, _json.source];
}

/// A site's decision for every kind. Written through
/// [CaptureKind.withGrant], which checks the mode belongs to the kind.
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

  final CaptureGrant camera;
  final CaptureGrant microphone;
  final CaptureGrant screenShare;

  CaptureGrants copyWith({
    CaptureGrant? camera,
    CaptureGrant? microphone,
    CaptureGrant? screenShare,
  }) => CaptureGrants(
    camera: camera ?? this.camera,
    microphone: microphone ?? this.microphone,
    screenShare: screenShare ?? this.screenShare,
  );

  /// Reads the keys [CaptureKind] owns; a wrong-typed or unknown value reads
  /// as absent. `cameraAllowed` is the legacy boolean the camera mode
  /// replaced.
  static CaptureGrants fromJson(Map<String, dynamic> json) => CaptureKind
      .values
      .fold(none, (g, kind) => kind.withGrant(g, kind._fromJson(json)));

  Map<String, Object> toJson() => {
    for (final kind in CaptureKind.values) ...kind._toJson(kind.grantOf(this)),
  };

  /// Every kind blocked, the stored files kept.
  CaptureGrants blocked() => _mapModes((kind, _) => kind.block);

  /// Every `real` grant back to `ask`; the device-free answers kept.
  CaptureGrants withoutRealGrants() => _mapModes(
    (kind, mode) => mode.state == SitePermissionState.allowed ? kind.ask : mode,
  );

  CaptureGrants _mapModes(
    CaptureMode Function(CaptureKind kind, CaptureMode mode) f,
  ) => CaptureKind.values.fold(this, (g, kind) {
    final grant = kind.grantOf(g);
    return kind.withGrant(g, (mode: f(kind, grant.mode), source: grant.source));
  });

  @override
  bool operator ==(Object other) =>
      other is CaptureGrants &&
      other.camera == camera &&
      other.microphone == microphone &&
      other.screenShare == screenShare;

  @override
  int get hashCode => Object.hash(camera, microphone, screenShare);
}

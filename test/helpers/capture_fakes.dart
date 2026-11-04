import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/origin_choices.dart';
import 'package:webspace/web_view_model.dart';

/// A file of [kind]'s medium.
VirtualSource pickedFor(
  CaptureKind kind, {
  String fileName = 'picked.bin',
}) => kind.medium.fromPick((
  dataUrl: 'data:application/octet-stream;base64,AAAA',
  fileName: fileName,
  isVideo: false,
));

/// [grants] with [kind] at [mode], serving [kind]'s sample file when
/// [withSource].
CaptureGrants grantsWith(
  CaptureKind kind, {
  required CaptureMode mode,
  bool withSource = false,
  CaptureGrants grants = CaptureGrants.none,
}) => kind.withGrant(grants, grant: (
  mode: mode,
  source: withSource ? pickedFor(kind) : null,
));

/// A site with [kind] at [mode].
WebViewModel siteWith(
  CaptureKind kind, {
  required CaptureMode mode,
  bool withSource = false,
  bool archived = false,
}) => WebViewModel(
  initUrl: 'https://site.example',
  captures: grantsWith(kind, mode: mode, withSource: withSource),
  isArchiveTier: archived,
);

/// What the user does with the popup or picker.
enum Answer { allow, useFile, block, dismiss, cancelPick }

/// Plays the user. [answer] decides each popup; [gate], while set, holds
/// every popup open so a test can pile requests up behind it.
final class FakePrompter implements MediaPrompter {
  FakePrompter([this.answer]);

  Answer Function(CaptureKind kind,
      {required String origin, required CaptureMode current})? answer;
  Completer<void>? gate;
  final List<(CaptureKind, String, CaptureMode)> asked = [];

  bool? drmAnswer;
  int drmAsked = 0;

  /// How another origin's document is answered (PERM-002); null fails the
  /// test if one is asked. A null result is a dismissed popup.
  bool? Function(SitePermission permission, {required String origin})?
      originAnswer;
  final List<(SitePermission, String)> originsAsked = [];

  @override
  Future<CaptureGrant> capture(
    CaptureKind kind, {
    required String origin,
    required CaptureMode current,
  }) async {
    asked.add((kind, origin, current));
    final choice = answer;
    if (choice == null) fail('$kind must not prompt for $origin');
    if (gate case final gate?) await gate.future;
    return switch (choice(kind, origin: origin, current: current)) {
      Answer.allow => (mode: kind.real, source: null),
      Answer.useFile => (mode: kind.virtual, source: pickedFor(kind)),
      Answer.block => (mode: kind.block, source: null),
      Answer.dismiss => (mode: kind.ask, source: null),
      Answer.cancelPick => (mode: current, source: null),
    };
  }

  @override
  Future<bool> protectedContent(String origin) async {
    drmAsked++;
    final answer = drmAnswer;
    if (answer == null) fail('protected content must not prompt for $origin');
    if (gate case final gate?) await gate.future;
    return answer;
  }

  @override
  Future<bool?> originAccess(
    SitePermission permission, {
    required String origin,
  }) async {
    originsAsked.add((permission, origin));
    final choice = originAnswer;
    if (choice == null) fail('$permission must not ask $origin');
    if (gate case final gate?) await gate.future;
    return choice(permission, origin: origin);
  }

  @override
  ShareNotice shareNotice(String origin) =>
      (title: 'Sharing', text: origin, stop: 'Stop');
}

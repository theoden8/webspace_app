import 'dart:typed_data';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/model_names.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/tab_leaves.dart';

/// A webview's back stack as `saveState` returned it, with the tab whose
/// history it is.
typedef CapturedNavState = ({TabId tab, Uint8List bytes});

/// One build of a site's webview, as its frame made it: its controller
/// restores what the frame took once ([WebViewTabBinding.restore]), and a
/// controller of an older build restores nothing.
final class FramedBuild {
  FramedBuild._({required this.restores});

  /// Whether the frame took a back stack for this build to restore.
  final bool restores;
}

/// Which tab's history a site's one webview shows (TAB-003): the tab it was
/// built for, the back stack its build took and no controller restored
/// yet, and the back stack queued for the next build, each tagged with the
/// tab it was read for. A build takes the bytes only when it is built for
/// that tab, so a back stack read before the active tab moved never lands
/// in another tab's webview; a capture keys its bytes by the tab the
/// webview shows rather than by whatever tab is active when it returns;
/// and a webview let go of before its controller restored what its build
/// took queues it again, so the next build shows that history.
final class WebViewTabBinding {
  TabId? _built;
  CapturedNavState? _queued;
  ({FramedBuild build, CapturedNavState stack})? _held;

  /// The tab the live webview was built for; null while there is none.
  TabId? get built => _built;

  /// The back stack queued for the next build, with the tab it was read for.
  CapturedNavState? get queued => _queued;

  /// The tab the queued back stack was read for, if one is queued.
  TabId? get queuedFor => _queued?.tab;

  /// The back stack the live build took that its controller has not
  /// restored yet, with the tab it was read for.
  CapturedNavState? get held => _held?.stack;

  /// Queues [bytes], read from [tab]'s file, for the next build: the
  /// model's `queued[s]`, written in a step's [commit].
  void queue(Uint8List bytes, {required TabId tab, required Commit commit}) {
    _queued = (tab: tab, bytes: bytes);
    commit.wrote(ModelVar.queued);
  }

  /// The webview is gone for good or for another build (an unload, a
  /// delete, a tab's rebind): `built[s]` written only where one was built,
  /// so a teardown of none writes nothing of the model. What its build held
  /// goes with it; the tab's file still holds it.
  void unbind({required Commit commit}) {
    if (_built == null) return;
    _built = null;
    commit.wrote(ModelVar.built);
    _drop(commit: commit);
  }

  /// The webview is let go of for the frame to build it again (`LetGo`):
  /// as [unbind], but a back stack its build took that no controller
  /// restored is queued again for its tab, so the next build shows it
  /// (TAB-003).
  void letGo({required Commit commit}) {
    if (_built == null) return;
    _built = null;
    commit.wrote(ModelVar.built);
    final held = _held;
    if (held == null) return;
    _queued = held.stack;
    _held = null;
    commit
      ..wrote(ModelVar.queued)
      ..wrote(ModelVar.held);
  }

  /// The frame builds a webview for [tab] and hands it the back stack queued
  /// for it, in one [commit] (`Bound`, `Shown`, `Taken` and `Handed`,
  /// TAB-003): the model's `built[s]`, its `hist[s]`, its `queued[s]`,
  /// emptied, and its `held[s]`, what the build took until its controller
  /// restores it. Bytes queued for another tab are dropped: that tab is no
  /// longer the one being built.
  FramedBuild frame(TabId tab, {required Commit commit}) {
    _built = tab;
    final queued = _queued;
    _queued = null;
    _drop(commit: commit);
    commit
      ..wrote(ModelVar.built)
      ..wrote(ModelVar.queued)
      ..wrote(ModelVar.hist);
    final takes = queued != null && _takes(queued, tab: tab);
    if (queued != null && !takes) {
      LogTag.webViewState.debug('Dropped a back stack queued for tab '
          '${queued.tab}: the webview is built for $tab');
    }
    final build = FramedBuild._(restores: takes);
    if (takes) {
      _held = (build: build, stack: queued);
      commit.wrote(ModelVar.held);
    }
    return build;
  }

  /// The back stack [build]'s frame took, for its controller to restore
  /// once, in [commit] (`Restored`): nothing for a build let go of since,
  /// or one whose controller already took it.
  Uint8List? restore(FramedBuild build, {required Commit commit}) {
    final held = _held;
    if (held == null || !identical(held.build, build)) return null;
    assert(
      held.stack.tab == _built,
      'a held back stack belongs to the live build (TAB-003)',
    );
    _held = null;
    commit.wrote(ModelVar.held);
    return held.stack.bytes;
  }

  void _drop({required Commit commit}) {
    if (_held == null) return;
    _held = null;
    commit.wrote(ModelVar.held);
  }

  /// Whether a build for [tab] takes [queued], as the model's `Takes`
  /// decides it.
  static bool _takes(CapturedNavState queued, {required TabId tab}) =>
      _takesDef.evaluate(null, args: [(t: queued.tab, h: null), tab]);
  static final _takesDef = takesOf<Object?>();
}

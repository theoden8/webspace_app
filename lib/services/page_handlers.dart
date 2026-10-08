import 'dart:async';
import 'package:webspace/platform/host_platform.dart';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/block_decision.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/page_shim.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/passkey_engine.dart';
import 'package:webspace/services/passkey_native.dart';
import 'package:webspace/services/current_location_service.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/download_engine.dart';
import 'package:webspace/services/download_manager.dart';
import 'package:webspace/services/location_spoof_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/media_session_service.dart';
import 'package:webspace/services/notification_service.dart';
import 'package:webspace/services/user_script_service.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_blocking.dart';
import 'package:webspace/services/webview_downloads.dart';
import 'package:webspace/services/webview.dart';

/// The JavaScript handlers a site page calls into: notifications, capture,
/// passkeys, media session, downloads and the rest of the page bridge.
abstract final class PageHandlers {
  /// The origin a camera / microphone prompt names.
  ///
  /// Never the shim's argument: the shims are injected
  /// `forMainFrameOnly: false`, so any frame can call the handler directly and
  /// would otherwise get to choose which site the dialog accuses. The top
  /// document's origin comes from the webview; a subframe's comes from the
  /// plugin's bridge preamble, which computes it behind the bridge secret and
  /// so is no more forgeable than `isMainFrame` (CAM-014 / MIC-016).
  static Future<String> promptOrigin(
    inapp.InAppWebViewController controller, {
    required WebViewConfig config,
    inapp.JavaScriptHandlerFunctionData? frame,
  }) async {
    if (frame != null && !frame.isMainFrame) return frame.origin.toString();
    return (await controller.getUrl())?.toString() ?? config.initialUrl;
  }

  /// Whether a native permission request came from the top document.
  ///
  /// The platform hands `onPermissionRequest` the requesting frame's origin
  /// but not its frame identity, so compare it with the document the webview
  /// is actually showing. Anything that does not match is a subframe and does
  /// not inherit a settled device grant (CAM-014 / MIC-016).
  static bool sameOrigin(String a, {required String b}) {
    final ua = Uri.tryParse(a);
    final ub = Uri.tryParse(b);
    if (ua == null || ub == null) return false;
    return ua.scheme == ub.scheme && ua.host == ub.host && ua.port == ub.port;
  }

  /// Register the Dart side of every shim [PageScripts.buildPageScripts] installs.
  /// The two go together: a shim whose handler is missing leaves the
  /// promise it hands the page unresolved.
  static void registerPageHandlers(
    inapp.InAppWebViewController controller, {
    required WebViewConfig config,
    required UserScriptService userScriptService,
    required String? Function() sourceUrl,
  }) {
    // Live geolocation: forward navigator.geolocation calls from the
    // shim into the platform's native location service. Permission is
    // requested by the native plugin only when this handler is first
    // invoked — i.e. only when the page actually calls
    // getCurrentPosition / watchPosition. The handler returns a
    // serialisable map matching CurrentLocationService's JSON shape.
    if (config.posture.location.mode == LocationMode.live) {
      // GSM-granularity sites get their fixes from the platform's
      // network-positioning provider only (Android NETWORK_PROVIDER /
      // iOS kCLLocationAccuracyKilometer). The OS never escalates to
      // the fine-location permission and never powers up the GPS
      // chip. Approximate still uses the GPS provider so a fix
      // actually arrives on devices without an NLP backend — the JS
      // shim's grid-snapping is layered on top to fuzz the result
      // before the page sees it.
      final requestAccuracy =
          config.posture.location.granularity == LocationGranularity.gsm
              ? LocationAccuracy.coarse
              : LocationAccuracy.fine;
      controller.addJavaScriptHandler(
        handlerName: 'getRealLocation',
        callback: (inapp.JavaScriptHandlerFunctionData data) async {
          // The shim reaches every frame, so a cross-origin iframe can call
          // this directly and skip the engine's Permissions-Policy check.
          // Serve it what an undelegated iframe sees in a browser (LOC-011);
          // a same-origin frame keeps the default 'self' allowlist.
          if (!data.isMainFrame) {
            final top =
                (await controller.getUrl())?.toString() ?? config.initialUrl;
            if (!sameOrigin(data.origin.toString(), b: top)) {
              return {'status': 'permission_denied', 'message': 'subframe'};
            }
          }
          final res = await CurrentLocationService.getCurrentLocation(
            accuracy: requestAccuracy,
          );
          if (res.status == CurrentLocationStatus.ok && res.fix != null) {
            // Apply the granularity grid-snap HERE, not only in the JS
            // shim: the shim is injected forMainFrameOnly:false, so a page
            // or cross-origin iframe can call this handler directly and
            // bypass snapFix. Snapping natively makes the per-site
            // granularity authoritative (the shim still snaps too, which
            // is now a no-op on the already-coarsened value).
            final (lat, lng, acc) = snapLiveFix(
              latitude: res.fix!.latitude,
              longitude: res.fix!.longitude,
              accuracy: res.fix!.accuracy,
              granularity: config.posture.location.granularity,
            );
            return {
              'status': 'ok',
              'latitude': lat,
              'longitude': lng,
              'accuracy': acc,
            };
          }
          return {
            'status': res.status.name,
            'message': res.message ?? 'unknown',
          };
        },
      );
    }
    // Capture bridges: a shim asks its kind's request handler for the site's
    // decision, and the store answers {mode, source?} (short-circuiting a
    // settled mode, coalescing a burst, prompting only when unresolved).
    // Frame-aware, so the origin and the frame identity reach Dart behind the
    // bridge secret, where page script can neither forge them nor call the
    // handler around them. A kind that does not reach subframes is denied one
    // HERE rather than only in its shim's realm (SHARE-005).
    final grants = config.grants;
    if (grants != null) {
      for (final kind in CaptureKind.values) {
        controller.addJavaScriptHandler(
          handlerName: kind.requestHandler,
          callback: (inapp.JavaScriptHandlerFunctionData data) async {
            if (kind.frames == ShimFrames.top && !data.isMainFrame) {
              return const {'mode': 'block'};
            }
            final grant = await grants.capture(
              kind,
              origin:
                  await promptOrigin(controller, config: config, frame: data),
              isTopFrame: data.isMainFrame,
            );
            return grant.toBridgeJson();
          },
        );
        if (kind.publishedDevice case final device?) {
          controller.addJavaScriptHandler(
            handlerName: device.modeHandler,
            callback: (args) => grants.mode(kind).name,
          );
        }
      }
    }
    // Passkey bridge (PASSKEY-004..009). The origin Credential Manager is
    // told is the bridge's frame origin, captured by the plugin's preamble
    // before page script ran and delivered behind the bridge secret; the
    // page's arguments carry only its WebAuthn-JSON options.
    final passkeys = config.passkeys;
    if (passkeys != null &&
        passkeys.backend == PasskeyBackend.credentialManager) {
      final webviewKey = WebViewFactory.passkeyWebviewKey(controller);
      controller.addJavaScriptHandler(
        handlerName: 'webauthnStatus',
        callback: (args) async =>
            {'available': (await PasskeyNative.status()).available},
      );
      controller.addJavaScriptHandler(
        handlerName: 'webauthnRequest',
        callback: (inapp.JavaScriptHandlerFunctionData data) async {
          final request = data.args.isNotEmpty && data.args.first is Map
              ? data.args.first as Map
              : const {};
          final label = '$webviewKey#${++WebViewFactory.passkeyRequests}';
          final status = await PasskeyNative.status();
          if (!status.available) {
            LogTag.passkey.debug(
                '$label refused: Credential Manager unavailable (${status.describe})');
            return PasskeyError.unsupported.toBridgeJson();
          }
          final plan = PasskeyEngine.plan(
            op: request['op'],
            options: request['options'],
            frameOrigin: data.origin.toString(),
            isMainFrame: data.isMainFrame,
            topUrl: (await controller.getUrl())?.toString(),
            onScreen: passkeys.isOnScreen(),
          );
          final ceremony = plan.ceremony;
          if (ceremony == null) {
            LogTag.passkey.debug(
                '$label refused before the provider: ${plan.error}');
            return plan.error!.toBridgeJson();
          }
          final key = '$webviewKey:${ceremony.origin}:${request['requestId']}';
          return PasskeyEngine.runCeremony(
            gate: WebViewFactory.passkeyGate,
            key: key,
            label: label,
            ceremony: ceremony,
            send: () => PasskeyNative.run(key, ceremony: ceremony),
            cancel: () => PasskeyNative.cancel(key),
            log: (message) => LogTag.passkey.debug(message),
          );
        },
      );
      // Keyed by the frame's origin as well as its request id, so a frame of
      // another origin in the same page cannot abort a ceremony it did not
      // start by guessing the id.
      controller.addJavaScriptHandler(
        handlerName: 'webauthnCancel',
        callback: (inapp.JavaScriptHandlerFunctionData data) {
          final origin = PasskeyEngine.serializeOrigin(data.origin.toString());
          final id = data.args.isNotEmpty ? data.args.first : '';
          final key = '$webviewKey:$origin:$id';
          if (WebViewFactory.passkeyGate.active == key) unawaited(PasskeyNative.cancel(key));
          return null;
        },
      );
    }
    if (config.posture.blocking.clearUrls) {
      controller.addJavaScriptHandler(handlerName: 'clearUrl', callback: (args) {
        if (args.isNotEmpty && args[0] is String) {
          final original = args[0] as String;
          final cleaned = ClearUrlService.instance.cleanUrl(original);
          if (cleaned != original) {
            BlockStatsService.instance.record(
              config.posture.siteId,
              category: BlockCategory.trackingParam,
              label: ClearUrlService.strippedParamLabel(original,
                  cleaned: cleaned),
            );
          }
          return cleaned;
        }
        return args.isNotEmpty ? args[0] : '';
      });
    }
    // Registered whether or not a list is loaded, so allowed requests are
    // tallied too. One verdict per host the page loaded from.
    controller.addJavaScriptHandler(handlerName: 'blockResourceLoadedBatch', callback: (args) {
      if (args.isEmpty || args[0] is! List) return null;
      for (final h in args[0] as List) {
        if (h is! String || h.isEmpty) continue;
        judgeAndRecord(config, query: HostQuery(h));
      }
      return null;
    });
    if (!hostIsAndroid) {
      // The WebKit interceptor's question about a Bloom hit. [sourceUrl] is
      // the hosting page, so `$domain=` rules apply.
      controller.addJavaScriptHandler(handlerName: 'blockCheck', callback: (args) {
        if (args.isEmpty || args[0] is! String) return false;
        final verdict = judgeAndRecord(
          config,
          query: UrlQuery(args[0] as String,
              sourceUrl: sourceUrl() ?? '', requestType: 'other'),
        );
        return switch (verdict) {
          Allowed() => false,
          Blocked() => true,
          Redirect(:final url) => url,
        };
      });
      // One-shot merged Bloom filter delivery to JS. Bloom bits only: the
      // handler is reachable from any page, so nothing host-identifying
      // (in particular the app-wide domain-decision cache, which records
      // every host every site requests) may travel in this response.
      controller.addJavaScriptHandler(handlerName: 'getBlockBloom', callback: (args) {
        final map = Map<String, dynamic>.from(
            DnsBlockService.instance.getMergedBlockBloom().toMap());
        // Second bloom for hostless ABP network rules (path rules
        // the host bloom can't prefilter). Only when the site has
        // content blocking on — these are ABP-only.
        final cb = ContentBlockerService.instance;
        final tokenBloom =
            config.posture.blocking.contentBlock ? cb.genericNetworkTokenBloom : null;
        final fallback =
            config.posture.blocking.contentBlock && cb.hasUntokenizableNetworkRules;
        if (tokenBloom != null) {
          final tm = tokenBloom.toMap();
          map['tokenBits'] = tm['bits'];
          map['tokenBitCount'] = tm['bitCount'];
          map['tokenK'] = tm['k'];
        }
        map['genericFallback'] = fallback;
        map['hasGeneric'] = tokenBloom != null || fallback;
        return map;
      });
    }
    // The generic cosmetic scan's selectors for the page's classes and ids;
    // empty, and the shim inert, without the engine.
    controller.addJavaScriptHandler(
      handlerName: 'genericCosmeticScan',
      callback: (args) {
        if (!config.posture.blocking.contentBlock) return const <String>[];
        if (args.isEmpty || args[0] is! Map) return const <String>[];
        final payload = Map<String, dynamic>.from(args[0] as Map);
        final classes = (payload['classes'] as List? ?? const [])
            .cast<String>()
            .toSet();
        final ids = (payload['ids'] as List? ?? const [])
            .cast<String>()
            .toSet();
        final selectors =
            ContentBlockerService.instance.genericCosmeticSelectorsFor(
          pageUrl: config.initialUrl,
          classes: classes,
          ids: ids,
        );
        if (selectors.isNotEmpty) {
          final preview = selectors.take(8).join(', ');
          LogTag.webView.debug('genericCosmeticScan ${config.initialUrl}: '
              '${classes.length} class / ${ids.length} id → '
              '${selectors.length} hide(s): [$preview${selectors.length > 8 ? ", …" : ""}]',
              sensitive: true);
        }
        return selectors;
      },
    );
    // ABP rule probe diagnostics. Lets the probe page tell
    // "no cosmetic list loaded" apart from "rules present but not
    // firing", and read the engine's ABP network verdict for a
    // host directly — independent of the DNS-bloom prefilter that
    // gates the iOS sub-resource interceptor, so the probe can
    // show ABP IS deciding even when that prefilter suppresses it.
    // Registered regardless of contentBlockEnabled so it can
    // report the per-site toggle being off.
    controller.addJavaScriptHandler(
      handlerName: 'getAbpProbeStatus',
      callback: (args) async {
        final svc = ContentBlockerService.instance;
        final payload = (args.isNotEmpty && args[0] is Map)
            ? Map<String, dynamic>.from(args[0] as Map)
            : const <String, dynamic>{};
        final canaries = (payload['canaryClasses'] as List? ?? const [])
            .cast<String>()
            .toSet();
        final hosts = (payload['netHosts'] as List? ?? const [])
            .cast<String>();
        final liveUrl =
            (await controller.getUrl())?.toString() ?? config.initialUrl;
        final status =
            svc.cosmeticDiagnostics(liveUrl, canaryClasses: canaries);
        final netVerdicts = <String, bool>{
          for (final h in hosts) h: svc.isHostBlocked(h),
        };
        return {
          ...status,
          'contentBlockEnabled': config.posture.blocking.contentBlock,
          'netVerdicts': netVerdicts,
        };
      },
    );
    if (config.posture.page.notifications) {
      controller.addJavaScriptHandler(
        handlerName: 'webNotification',
        // The polyfill is in every frame. A cross-origin iframe posting
        // under the site's identity is dropped here, on the frame identity
        // the plugin supplies, not on anything the page says (NOTIF-010).
        callback: (inapp.JavaScriptHandlerFunctionData call) async {
          final args = call.args;
          if (args.isEmpty || args[0] is! Map) return null;
          if (!call.isMainFrame) {
            final top =
                (await controller.getUrl())?.toString() ?? config.initialUrl;
            if (!sameOrigin(call.origin.toString(), b: top)) return null;
          }
          final data = Map<String, dynamic>.from(args[0] as Map);
          final title = data['title'] as String? ?? '';
          final body = data['body'] as String? ?? '';
          final tag = data['tag'] as String?;
          // Ignore any page-supplied siteId: a hostile script could
          // otherwise attribute a notification (and its tap-target site
          // switch) to another site the user never granted permission to.
          final siteId = config.posture.siteId;
          await NotificationService.instance.show(
            siteId: siteId,
            title: title,
            body: body,
            tag: tag,
            siteUrl: config.initialUrl,
          );
          return null;
        },
      );
    }
    if (config.backgroundAudioEnabled &&
        MediaSessionService.instance.isSupported) {
      controller.addJavaScriptHandler(
        handlerName: 'wsMediaSession',
        // Frame-aware: the shim runs in every frame of the site and they all
        // share this handler, so whether the report came from the top document
        // has to be decided here rather than taken from the page (BGAUDIO-008).
        callback: (inapp.JavaScriptHandlerFunctionData call) async {
          final args = call.args;
          if (args.isEmpty || args[0] is! Map) return null;
          final data = Map<String, dynamic>.from(args[0] as Map);
          final control = data['control'] as String?;
          if (control != null) {
            await MediaSessionService.instance.reportControlFailure(
              action: control,
              error: data['error'] as String? ?? 'unknown',
            );
            return null;
          }
          await MediaSessionService.instance.report(
            config.posture.siteId,
            page: MediaSessionReport.fromPage(data,
                isMainFrame: call.isMainFrame),
            runJs: (js) => controller.evaluateJavascript(source: js),
            proxy: config.posture.container.proxy,
          );
          return null;
        },
      );
    }
    controller.addJavaScriptHandler(
      handlerName: 'webNotificationRequestPermission',
      callback: (args) {
        final result = config.posture.page.notifications ? 'granted' : 'denied';
        LogTag.notification.debug(
            'requestPermission handler called, returning: $result');
        return result;
      },
    );
    userScriptService.registerHandlers(controller);
    // Blob download: JS reads the blob via FileReader and hands the
    // base64 payload back through these handlers.
    controller.addJavaScriptHandler(
      handlerName: '_webspaceBlobDownload',
      callback: (args) async {
        if (args.length < 4) return null;
        final filename = args[0] is String ? args[0] as String : '';
        final base64Data = args[1] is String ? args[1] as String : '';
        final mimeType = args[2] is String ? args[2] as String : '';
        final taskId = args[3] is String ? args[3] as String : '';
        if (base64Data.isEmpty) {
          if (taskId.isNotEmpty) {
            DownloadsService.instance.fail(taskId, message: 'empty payload');
          }
          return null;
        }
        try {
          final result = DownloadEngine.fromBase64(
            base64Data: base64Data,
            suggestedFilename: filename.isEmpty ? null : filename,
            mimeType: mimeType.isEmpty ? null : mimeType,
          );
          if (taskId.isNotEmpty) {
            DownloadsService.instance.updateProgress(taskId,
                bytesDone: result.bytes.length,
                bytesTotal: result.bytes.length);
          }
          final saved = await WebViewDownloads.saveViaPicker(result);
          if (taskId.isNotEmpty) {
            if (saved == null) {
              DownloadsService.instance.cancel(taskId);
            } else {
              DownloadsService.instance
                  .complete(taskId, savedPath: saved);
            }
          }
        } on DownloadException catch (e) {
          if (taskId.isNotEmpty) {
            DownloadsService.instance.fail(taskId, message: e.message);
          }
        } catch (e, stack) {
          LogTag.webView.error(
              'Blob download error: $e\n$stack', sensitive: true);
          if (taskId.isNotEmpty) {
            DownloadsService.instance.fail(taskId, message: e.toString());
          }
        }
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: '_webspaceBlobDownloadError',
      callback: (args) {
        final msg = args.isNotEmpty ? args[0].toString() : 'unknown';
        final taskId = args.length >= 2 && args[1] is String
            ? args[1] as String
            : '';
        if (taskId.isNotEmpty) {
          DownloadsService.instance.fail(taskId, message: msg);
        }
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: '_webspaceBlobProgress',
      callback: (args) {
        if (args.length < 3) return null;
        final taskId = args[0] is String ? args[0] as String : '';
        final done = WebViewDownloads.asInt(args[1]);
        final total = WebViewDownloads.asInt(args[2]);
        if (taskId.isEmpty) return null;
        DownloadsService.instance.updateProgress(
          taskId,
          bytesDone: done,
          bytesTotal: total,
        );
        return null;
      },
    );
    // Android-only path: `<a download href="blob:">` clicks reach
    // Dart via the click-intercept shim, since Android's
    // DownloadListener does not fire for blob: URLs.
    // [_handleBlobDownload] is the same entry point the
    // onDownloadStartRequest path uses on iOS/macOS — keeping a
    // single funnel preserves the captured-Blob fast path and the
    // task lifecycle in DownloadsService.
    controller.addJavaScriptHandler(
      handlerName: '_webspaceBlobDownloadStart',
      callback: (args) async {
        if (args.isEmpty) return null;
        final blobUrl = args[0] is String ? args[0] as String : '';
        final filename = args.length >= 2 && args[1] is String
            ? args[1] as String
            : '';
        if (blobUrl.isEmpty || !blobUrl.startsWith('blob:')) {
          return null;
        }
        await WebViewDownloads.handleBlobDownload(
          controller,
          blobUrl: blobUrl,
          suggestedFilename: filename.isEmpty ? null : filename,
        );
        return null;
      },
    );
  }
}

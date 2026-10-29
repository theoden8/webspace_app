import 'dart:async';
import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/blob_url_capture.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/download_engine.dart';
import 'package:webspace/services/download_manager.dart';
import 'package:webspace/services/file_dialog.dart';
import 'package:webspace/services/outbound_http_types.dart' show OutboundProxy;
import 'package:webspace/services/log_service.dart';

/// Downloads a site webview starts: http(s) through the site's proxy, data:
/// and blob: URLs from the page, each saved where the user picks.
abstract final class WebViewDownloads {
  static Future<void> handleDownloadRequest(
    inapp.InAppWebViewController controller, {
    required inapp.DownloadStartRequest req,
    String? referer,
    required OutboundProxy proxy,
  }) async {
    final urlStr = req.url.toString();
    final scheme = req.url.scheme.toLowerCase();

    switch (scheme) {
      case 'http':
      case 'https':
        await _handleHttpDownload(controller, req: req,
            referer: referer, proxy: proxy);
        return;
      case 'data':
        _handleDataDownload(req);
        return;
      case 'blob':
        await handleBlobDownload(controller,
            blobUrl: urlStr, suggestedFilename: req.suggestedFilename);
        return;
      default:
        refused(scheme: scheme, url: urlStr,
            suggestedFilename: req.suggestedFilename);
    }
  }

  /// A download whose scheme no path above takes, listed as failed where
  /// every other failed download is (DL-006).
  static DownloadTask refused({
    required String scheme,
    required String url,
    required String? suggestedFilename,
  }) {
    final downloads = DownloadsService.instance;
    final task = downloads.start(
      filename: suggestedFilename?.isNotEmpty == true
          ? suggestedFilename!
          : 'download',
      url: url,
    );
    downloads.fail(task.id, message: 'Can\'t download $scheme: URLs.');
    return task;
  }

  static Future<void> _handleHttpDownload(
    inapp.InAppWebViewController controller, {
    required inapp.DownloadStartRequest req,
    String? referer,
    required OutboundProxy proxy,
  }) async {
    final initialFilename = DownloadEngine.deriveFilename(
      suggested: req.suggestedFilename,
      url: req.url.toString(),
      mimeType: req.mimeType,
    );
    final task = DownloadsService.instance.start(
      filename: initialFilename,
      url: req.url.toString(),
      bytesTotal: req.contentLength > 0 ? req.contentLength : null,
    );
    try {
      // Scope the read to the WebView that started the download. Under the
      // container engine the site's session lives in its own jar; an
      // unscoped read resolves against the default jar, which is empty, so
      // the GET goes out logged-out and an authenticated download comes
      // back 401/403 (DL-003, CONT-006).
      final cookies = await cookieChannel((plugin) => plugin.getCookies(
            url: req.url,
            webViewController: controller,
          ));
      final cookieHeader = DownloadEngine.buildCookieHeader(
        cookies.map((c) => MapEntry(c.name, c.value.toString())),
      );
      LogTag.download.debug(
          'HTTP download: url=${req.url} cookies=${cookies.length} '
          'ua=${req.userAgent != null} referer=${referer != null}',
          sensitive: true);
      final engine = DownloadEngine(proxy: proxy);
      final result = await engine.fetch(
        url: req.url.toString(),
        cookieHeader: cookieHeader,
        cookieHeaderFor: (uri) async {
          final hop = await cookieChannel((plugin) => plugin.getCookies(
                url: inapp.WebUri(uri.toString()),
                webViewController: controller,
              ));
          return DownloadEngine.buildCookieHeader(
            hop.map((c) => MapEntry(c.name, c.value.toString())),
          );
        },
        userAgent: req.userAgent,
        referer: referer,
        suggestedFilename: req.suggestedFilename,
        mimeTypeHint: req.mimeType,
        onProgress: (done, {required bytesTotal}) => DownloadsService.instance
            .updateProgress(task.id, bytesDone: done, bytesTotal: bytesTotal),
      );
      task.filename = result.filename;
      final savedPath = await saveViaPicker(result);
      if (savedPath == null) {
        DownloadsService.instance.cancel(task.id);
      } else {
        DownloadsService.instance.complete(task.id, savedPath: savedPath);
      }
    } on DownloadException catch (e) {
      DownloadsService.instance.fail(task.id, message: e.message);
    } on CookieJarFailure catch (e, stack) {
      // Sent without the site's cookies the request would go out signed out
      // (DL-003), so the download fails instead.
      _failed(task.id, what: 'Download cookie read', error: e, stack: stack);
    } on FileDialogFailure catch (e, stack) {
      _failed(task.id, what: 'Download error', error: e, stack: stack);
    } on IOException catch (e, stack) {
      _failed(task.id, what: 'Download error', error: e, stack: stack);
    }
  }

  static void _handleDataDownload(inapp.DownloadStartRequest req) async {
    final task = DownloadsService.instance.start(
      filename: req.suggestedFilename?.isNotEmpty == true
          ? req.suggestedFilename!
          : 'download',
      url: req.url.toString(),
    );
    try {
      final result = DownloadEngine.decodeDataUri(
        url: req.url.toString(),
        suggestedFilename: req.suggestedFilename,
      );
      task.filename = result.filename;
      DownloadsService.instance.updateProgress(task.id,
          bytesDone: result.bytes.length, bytesTotal: result.bytes.length);
      final savedPath = await saveViaPicker(result);
      if (savedPath == null) {
        DownloadsService.instance.cancel(task.id);
      } else {
        DownloadsService.instance.complete(task.id, savedPath: savedPath);
      }
    } on DownloadException catch (e) {
      DownloadsService.instance.fail(task.id, message: e.message);
    } on FormatException catch (e, stack) {
      _failed(task.id, what: 'Data-URI download error', error: e, stack: stack);
    } on FileDialogFailure catch (e, stack) {
      _failed(task.id, what: 'Data-URI download error', error: e, stack: stack);
    } on IOException catch (e, stack) {
      _failed(task.id, what: 'Data-URI download error', error: e, stack: stack);
    }
  }

  static Future<void> handleBlobDownload(
    inapp.InAppWebViewController controller, {
    required String blobUrl,
    required String? suggestedFilename,
  }) async {
    final task = DownloadsService.instance.start(
      filename: suggestedFilename?.isNotEmpty == true
          ? suggestedFilename!
          : 'download',
      url: blobUrl,
    );
    final script = buildBlobDownloadIife(
      blobUrl: blobUrl,
      taskId: task.id,
      suggestedFilename: suggestedFilename,
    );
    try {
      await controller.evaluateJavascript(source: script);
    } on PlatformException catch (e, stack) {
      _failed(task.id, what: 'Blob download eval error', error: e, stack: stack);
    } on MissingPluginException catch (e, stack) {
      _failed(task.id, what: 'Blob download eval error', error: e, stack: stack);
    }
  }

  static void _failed(DownloadTaskId taskId,
      {required String what,
      required Exception error,
      required StackTrace stack}) {
    LogTag.download.error('$what: $error\n$stack', sensitive: true);
    DownloadsService.instance.fail(taskId, message: error.toString());
  }

  static Future<String?> saveViaPicker(DownloadResult result) async {
    final isMobile = !kIsWeb && (hostIsIOS || hostIsAndroid);
    final outputPath = await FileDialog.saveFile(
      dialogTitle: 'Save download',
      fileName: result.filename,
      bytes: isMobile ? result.bytes : null,
    );
    if (outputPath == null) return null;
    if (!isMobile) {
      await hostWriteBytes(outputPath, bytes: result.bytes);
    }
    return outputPath;
  }

  /// Coerce a JS handler arg to an int. Small integers come back as int
  /// but large ones can arrive as double (JSON number serialization), so
  /// normalize both.
  static int? asInt(Object? v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}

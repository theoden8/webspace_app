import 'dart:async';
import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/services/webview.dart';

/// How a site webview answers a certificate the OS rejected: the user's
/// trust prompt, the pinned exceptions, and the reload after a refused load.
abstract final class WebViewTls {
  /// Cert objects observed via [handleServerTrust], keyed by host:port.
  /// On iOS/macOS the post-failure prompt fires from `onReceivedError`,
  /// which doesn't carry the cert; we stash whatever the trust callback
  /// saw so the prompt can show subject/issuer/dates.
  static final Map<String, inapp.SslCertificate> _sslCertificateCache = {};

  /// Routes a TLS server-trust challenge.
  ///
  /// Platform contract:
  ///   * iOS/macOS — the upstream plugin fires this for **every** HTTPS
  ///     handshake, not just rejected ones. Returning `null` makes the
  ///     plugin's `nullSuccess` path run, which falls through to
  ///     `URLSession.AuthChallengeDisposition.performDefaultHandling`
  ///     and delegates the verdict to Apple Keychain (system + any CAs
  ///     the user installed). NOTE: `ServerTrustAuthResponse()` looks
  ///     like a no-action response but its Dart constructor defaults
  ///     `action` to `CANCEL`, which silently kills the handshake —
  ///     null is the only way to defer. A genuine failure surfaces via
  ///     `onReceivedError` with a `SERVER_CERTIFICATE_*` error type,
  ///     where the prompt fires and an approved cert is pinned for the
  ///     next attempt.
  ///   * Android & Linux — the underlying signal is already
  ///     post-failure (`WebViewClient.onReceivedSslError` /
  ///     `load-failed-with-tls-errors`), so the callback only runs when
  ///     the OS has rejected the cert. Prompt the user inline.
  static Future<inapp.ServerTrustAuthResponse?> handleServerTrust(
    WebViewController? view, {
    required inapp.ServerTrustChallenge challenge,
    required Future<bool> Function(String host,
            {required int port, required inapp.SslCertificate? certificate})?
        prompt,
  }) async {
    final space = challenge.protectionSpace;
    final host = space.host;
    // `space.port` is `int?` but on Android the upstream plugin
    // surfaces `-1` (NSURLProtectionSpace sentinel) rather than null,
    // which slips past the `??`. Coalesce any non-positive value to
    // the protocol default. Otherwise pins land as
    // `(host, -1, sha256)` and the dart:io `badCertificateCallback`
    // (which always sees the real socket port, e.g. 443) never
    // matches → favicon stays on the public-CA fallback.
    final rawPort = space.port;
    final port = (rawPort != null && rawPort > 0)
        ? rawPort
        : (space.protocol?.toLowerCase() == 'https' ? 443 : 80);
    final cert = space.sslCertificate;
    final fingerprint = TrustedHostsService.fingerprintFromInappCertificate(cert);
    if (cert != null) {
      _sslCertificateCache[_certCacheKey(host, port: port)] = cert;
    }
    // Apple: defer to OS unconditionally. The pin store doesn't help
    // here — modern macOS/iOS reject self-signed at the BoringSSL layer
    // before our PROCEED can take effect, and valid public-CA certs
    // are accepted by the OS without consulting the pin store. Pins
    // remain useful for Android post-failure and for dart:io
    // `HttpClient.badCertificateCallback` (favicon fetch, etc.), but
    // querying them in this code path on Apple was log noise at best.
    if (hostIsIOS || hostIsMacOS) {
      return null;
    }
    if (TrustedHostsService.instance.isTrusted(
      host: host,
      port: port,
      fingerprint: fingerprint,
    )) {
      LogTag.tls.debug(
          'pinned cert accepted for $host:$port (sha256=$fingerprint)',
          sensitive: true);
      return inapp.ServerTrustAuthResponse(
          action: inapp.ServerTrustAuthResponseAction.PROCEED);
    }
    // Loopback sinkhole: a device-level DNS/ad blocker (VPN-based
    // blocker, hosts-file sinkhole, Private DNS, etc.) may resolve a
    // tracker host to 127.0.0.1 where a local responder answers with a
    // self-signed `CN=localhost` cert. The OS rejects it (hostname
    // mismatch + untrusted self-signed) and the trust callback fires
    // per sub-resource, which used to stack a separate "Untrusted
    // certificate" prompt for every blocked ad domain on the page. No
    // user would trust `localhost` for a remote host, so cancel
    // silently — never prompt, never pin. The genuine local-dev case
    // (browsing to `https://localhost`) is preserved because the
    // requested host then matches the cert identity.
    if (_isLoopbackSinkholeCert(host, cert: cert)) {
      LogTag.tls.debug(
          'localhost sinkhole cert for $host:$port — cancelling silently '
          '(no prompt; likely a device-level DNS/ad blocker)', sensitive: true);
      return inapp.ServerTrustAuthResponse(
          action: inapp.ServerTrustAuthResponseAction.CANCEL);
    }
    // An upgrade of ours (HTTPS-007). The user asked for http; we substituted
    // https on their behalf, and its certificate did not validate. Prompting
    // here would ask them to judge a connection they never made, about a URL
    // they never typed, and TLS-002's approval PINS the certificate for good.
    // Fall back to the http they actually asked for instead: same shape as the
    // loopback-sinkhole carve-out above, never prompt, never pin.
    final upgradeCert =
        WebViewFactory.httpsUpgrade.onCertificateRejected(host);
    if (upgradeCert.load != null) {
      LogTag.tls.debug(
          'untrusted cert on an https upgrade for $host:$port — cancelling '
          'silently and falling back to ${upgradeCert.load} (no prompt, '
          'no pin)', sensitive: true);
      view?.loadUrl(upgradeCert.load!);
    }
    if (upgradeCert.cancel) {
      return inapp.ServerTrustAuthResponse(
          action: inapp.ServerTrustAuthResponseAction.CANCEL);
    }
    // Post-failure platforms (Android, Linux): the OS already rejected
    // the chain. Prompt the user now.
    if (prompt == null) {
      LogTag.tls.debug(
          'untrusted cert for $host:$port and no host UI — cancelling load',
          sensitive: true);
      return inapp.ServerTrustAuthResponse(
          action: inapp.ServerTrustAuthResponseAction.CANCEL);
    }
    final approved = await prompt(host, port: port, certificate: cert);
    if (!approved) {
      LogTag.tls.debug(
          'user rejected untrusted cert for $host:$port', sensitive: true);
      return inapp.ServerTrustAuthResponse(
          action: inapp.ServerTrustAuthResponseAction.CANCEL);
    }
    if (fingerprint != null) {
      await TrustedHostsService.instance.trust(
        host: host,
        port: port,
        fingerprint: fingerprint,
      );
      LogTag.tls.debug(
          'user trusted cert for $host:$port (pinned sha256=$fingerprint)',
          sensitive: true);
    } else {
      LogTag.tls.debug(
          'user trusted cert for $host:$port (no DER from platform — not pinned)',
          sensitive: true);
    }
    // Android's SslErrorHandler (and WPE's TLS-error proxy) may have
    // been invalidated during the async prompt — the WebView gives up
    // on the request long before the user finishes reading the dialog,
    // so handler.proceed() lands on a dead request and the page never
    // paints. Reload re-issues the failed nav; this PROCEED arm
    // short-circuits via the now-matching pin synchronously on the
    // new attempt.
    Future.microtask(() async {
      await view?.reload();
    });
    return inapp.ServerTrustAuthResponse(
        action: inapp.ServerTrustAuthResponseAction.PROCEED);
  }

  static String _certCacheKey(String host, {required int port}) =>
      '${host.toLowerCase()}:$port';

  static bool _isLoopbackHost(String host) {
    final h = host.toLowerCase();
    return h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]';
  }

  /// True when [cert] is a self-signed `CN=localhost` certificate served
  /// for a non-loopback [host] — the signature of a device-level DNS/ad
  /// sinkhole answering a blocked tracker on `127.0.0.1`. Such a cert is
  /// never something the user means to trust for a remote host, so the
  /// caller cancels the load without prompting. A real `https://localhost`
  /// dev server is excluded because [host] then matches the cert identity.
  static bool _isLoopbackSinkholeCert(String host,
      {required inapp.SslCertificate? cert}) {
    if (cert == null) return false;
    return isLoopbackSinkholeCert(
      host: host,
      issuedToCName: cert.issuedTo?.CName,
      issuedByCName: cert.issuedBy?.CName,
    );
  }

  /// Pure classification behind [_isLoopbackSinkholeCert], split out so it
  /// can be unit-tested without constructing a plugin `SslCertificate`.
  @visibleForTesting
  static bool isLoopbackSinkholeCert({
    required String host,
    String? issuedToCName,
    String? issuedByCName,
  }) {
    if (_isLoopbackHost(host)) return false;
    final issuedTo = issuedToCName?.trim().toLowerCase();
    final issuedBy = issuedByCName?.trim().toLowerCase();
    return issuedTo == 'localhost' || issuedBy == 'localhost';
  }

  /// Whether [error] indicates the OS rejected the server certificate.
  /// Used by the iOS/macOS post-failure branch in `onReceivedError`.
  static bool isSslError(inapp.WebResourceErrorType type) {
    return type == inapp.WebResourceErrorType.SERVER_CERTIFICATE_UNTRUSTED ||
        type == inapp.WebResourceErrorType.SERVER_CERTIFICATE_HAS_UNKNOWN_ROOT ||
        type == inapp.WebResourceErrorType.SERVER_CERTIFICATE_HAS_BAD_DATE ||
        type == inapp.WebResourceErrorType.SERVER_CERTIFICATE_NOT_YET_VALID ||
        type == inapp.WebResourceErrorType.SERVER_CERTIFICATE_REVOKED ||
        type == inapp.WebResourceErrorType.SERVER_CERTIFICATE_BAD_IDENTITY ||
        type == inapp.WebResourceErrorType.SECURE_CONNECTION_FAILED ||
        type == inapp.WebResourceErrorType.FAILED_SSL_HANDSHAKE;
  }

  /// Hosts with an in-flight prompt — guards against the cascade of
  /// duplicate `onReceivedError` calls a single failed nav can fire
  /// (main frame + favicon + service worker probes).
  static final Set<String> _inflightSslPrompts = {};

  /// Hosts we have recently reloaded after a TLS failure when a pin
  /// existed. iOS WKWebView fires `onReceivedError` for every failed
  /// connection even when our async `.useCredential` would have
  /// succeeded — the underlying NSURLSession has already entered a
  /// failed state by the time the trust callback's response arrives.
  /// Reloading kicks off a fresh connection that does see our PROCEED
  /// in time. We need exactly one reload per failure burst, otherwise
  /// the post-reload's own stale `onReceivedError` triggers another
  /// reload, ad infinitum. Time-based: any reload claim within
  /// [_reloadGuardTimeout] of a previous one for the same host is
  /// suppressed. The timeout is the only clear path, so a genuine
  /// new TLS problem at the host (cert rotation, etc.) is allowed
  /// through after the window expires.
  static final Map<String, DateTime> _pendingSslReloads = {};

  static const Duration _reloadGuardTimeout = Duration(seconds: 10);

  static bool _claimReloadGuard(String key) {
    final now = DateTime.now();
    final prev = _pendingSslReloads[key];
    if (prev != null && now.difference(prev) < _reloadGuardTimeout) {
      return false;
    }
    _pendingSslReloads[key] = now;
    return true;
  }

  /// iOS/macOS post-failure path. The trust callback returned `null`
  /// (deferring to OS), the OS rejected, and now we get a chance to
  /// act. Two cases:
  ///   * Cert is already pinned (cached fingerprint matches) — the OS
  ///     rejection was lower-layer (the trust callback's async
  ///     `.useCredential` didn't beat NSURLSession's failure state).
  ///     A fresh reload starts a new connection where our PROCEED
  ///     wins. Guarded so a single nav can only trigger one reload.
  ///   * Not pinned — show the prompt; on approval pin the cached
  ///     cert and reload. The reload's trust callback finds the pin
  ///     and returns PROCEED.
  static Future<bool> handleSslLoadError({
    required WebViewController? view,
    required String url,
    required Future<bool> Function(String host,
            {required int port, required inapp.SslCertificate? certificate})?
        prompt,
  }) async {
    // Modern Apple platforms (macOS 15+, iOS 26+) reject self-signed
    // certs at the `nw_protocol_boringssl` layer regardless of the
    // app's `URLCredential(trust:)` override. There is no sandboxed-app
    // workaround: `SecTrustSettingsSetTrustSettings` is blocked by the
    // sandbox and Safari uses a private SPI we don't have. Skip the
    // prompt + reload entirely on Apple platforms — both would loop on
    // the same `SECURE_CONNECTION_FAILED`. Public CA-signed sites still
    // load via the normal OS-default path; only self-signed /
    // unknown-CA sites fail closed here. Users can install the cert
    // manually (Keychain Access on macOS, Settings → General →
    // Certificate Trust Settings on iOS).
    if (hostIsMacOS || hostIsIOS) {
      return false;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority) return false;
    final host = uri.host;
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    final key = _certCacheKey(host, port: port);
    final cert = _sslCertificateCache[key];
    final fingerprint =
        TrustedHostsService.fingerprintFromInappCertificate(cert);
    if (TrustedHostsService.instance.isTrusted(
      host: host,
      port: port,
      fingerprint: fingerprint,
    )) {
      if (!_claimReloadGuard(key)) {
        LogTag.tls.debug(
            'ignoring further ssl errors for $host:$port — reload already in flight',
            sensitive: true);
        return true;
      }
      LogTag.tls.debug(
          'pin matches but iOS reported error for $host:$port — reloading once '
          '(os: $hostOperatingSystem $hostOperatingSystemVersion)',
          sensitive: true);
      Future.microtask(() async {
        await view?.loadUrl(url);
      });
      return true;
    }
    if (prompt == null) return false;
    if (!_inflightSslPrompts.add(key)) return true;
    try {
      final approved = await prompt(host, port: port, certificate: cert);
      if (!approved) {
        LogTag.tls.debug(
            'user rejected untrusted cert for $host:$port', sensitive: true);
        return false;
      }
      if (fingerprint == null) {
        LogTag.tls.debug(
            'user trusted cert for $host:$port but DER missing — cannot pin, load will fail again',
            sensitive: true);
        return false;
      }
      await TrustedHostsService.instance.trust(
        host: host,
        port: port,
        fingerprint: fingerprint,
      );
      LogTag.tls.debug(
          'user trusted cert for $host:$port (pinned sha256=$fingerprint) — reloading',
          sensitive: true);
      await view?.loadUrl(url);
      return true;
    } finally {
      _inflightSslPrompts.remove(key);
    }
  }
}

import 'dart:async';
import 'package:webspace/platform/host_platform.dart';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/http_auth_secure_storage.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_proxy.dart';

/// Answer a webview's `onReceivedHttpAuthRequest`: the proxy router's
/// challenge first, then the site's own (HTTPAUTH-001).
///
/// Order is the security property. Android cannot say whether a challenge
/// came from a proxy, so the relay's `407` and a site's `401` arrive here
/// alike; the router claims its own by bound loopback host and per-run realm
/// nonce, and only what it does not claim reaches [session]. A router-owned
/// challenge is never shown to the user and never answered from saved
/// credentials, whatever [session] would say.
Future<inapp.HttpAuthResponse?> answerHttpAuthChallenge({
  required RouterIdentity? routerIdentity,
  required HttpAuthSession? session,
  required inapp.HttpAuthenticationChallenge challenge,
}) async {
  final space = challenge.protectionSpace;
  final router = ProxyRouterService.instance;
  if (router.ownsChallenge(host: space.host, realm: space.realm)) {
    // A site presents its identity only once this run has shown that
    // identity's profile presents its own (PROXY-015); until then the
    // request waits here, and an identity that failed is never answered.
    if (routerIdentity == null || !await router.attributed(routerIdentity)) {
      return null;
    }
    return answerProxyRouterChallenge(routerIdentity, challenge: challenge);
  }
  if (session == null) return null;
  final credential = await session.answer(HttpAuthChallengeInfo(
    host: space.host,
    realm: space.realm,
    isProxy: space.proxyType != null,
    // Android's count is one static shared by every webview in the
    // process, and it already reads 1 on a first challenge.
    platformRetry: !hostIsAndroid && challenge.previousFailureCount > 0,
  ));
  if (credential == null) return null;
  return inapp.HttpAuthResponse(
    action: inapp.HttpAuthResponseAction.PROCEED,
    username: credential.username,
    password: credential.password,
    // The platform's store is app-wide; saving is HttpAuthSecureStorage's
    // job, per site (HTTPAUTH-004).
    permanentPersistence: false,
  );
}

HttpAuthSession httpAuthSessionFor(WebViewConfig config) => HttpAuthSession(
      siteId: config.posture.siteId,
      siteUrl: config.initialUrl,
      memory: config.posture.container.httpAuthMemory,
      store: HttpAuthSecureStorage.instance,
      prompt: config.hooks.httpAuth,
    );

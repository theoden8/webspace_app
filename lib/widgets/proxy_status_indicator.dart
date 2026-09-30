import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/proxy_health_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/theme/design_tokens.dart';

/// Whether a proxy answers: a coloured dot and a line of text, checked when
/// shown and again on tap (PROXY-031).
///
/// [proxy] is the resolved route. An unresolved one ([ProxyType.SAVED] with
/// no address) reads as [problem] without a probe; DEFAULT shows nothing.
class ProxyStatusIndicator extends StatefulWidget {
  const ProxyStatusIndicator({
    super.key,
    required this.proxy,
    this.problem,
    this.service,
  });

  final UserProxySettings proxy;

  /// What an unresolved route reads as; the missing saved proxy by default.
  final String? problem;

  /// Defaults to [ProxyHealthService.instance].
  final ProxyHealthService? service;

  @override
  State<ProxyStatusIndicator> createState() => _ProxyStatusIndicatorState();
}

class _ProxyStatusIndicatorState extends State<ProxyStatusIndicator> {
  ProxyHealthService get _service =>
      widget.service ?? ProxyHealthService.instance;

  /// A proxy that changes under the indicator is usually being typed; each
  /// keystroke is a different proxy, and a complete `host:port` on the way
  /// to the intended one is a real host that would be sent a probe.
  static const Duration _settle = Duration(seconds: 1);
  Timer? _pending;

  @override
  void initState() {
    super.initState();
    _service.addListener(_changed);
    _ensureFresh(immediately: true);
  }

  @override
  void didUpdateWidget(ProxyStatusIndicator old) {
    super.didUpdateWidget(old);
    final oldService = old.service ?? ProxyHealthService.instance;
    if (!identical(oldService, _service)) {
      oldService.removeListener(_changed);
      _service.addListener(_changed);
    }
    if (!_sameProxy(old.proxy, widget.proxy)) _ensureFresh();
  }

  @override
  void dispose() {
    _pending?.cancel();
    _service.removeListener(_changed);
    super.dispose();
  }

  static bool _sameProxy(UserProxySettings a, UserProxySettings b) =>
      a.type == b.type &&
      a.address == b.address &&
      a.username == b.username &&
      a.password == b.password;

  void _changed() {
    if (mounted) setState(() {});
  }

  void _ensureFresh({bool immediately = false}) {
    _pending?.cancel();
    if (!ProxyHealthService.probeable(widget.proxy)) return;
    if (_service.isFresh(widget.proxy)) return;
    if (!immediately) {
      _pending = Timer(_settle, () {
        if (mounted) _service.check(widget.proxy);
      });
      return;
    }
    // After the frame: `check` notifies synchronously, and a listener may
    // not rebuild a widget during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _service.check(widget.proxy);
    });
  }

  @override
  Widget build(BuildContext context) {
    final proxy = widget.proxy;
    if (proxy.type == ProxyType.DEFAULT) return const SizedBox.shrink();
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final missing = proxy.type == ProxyType.SAVED;
    final health = missing ? null : _service.statusOf(proxy);
    final state = health?.state ?? ProxyHealthState.checking;

    final (Color color, String label) = missing
        ? (scheme.error, widget.problem ?? loc.savedProxyMissing)
        : switch (state) {
            ProxyHealthState.checking => (
                scheme.onSurfaceVariant,
                loc.proxyStatusChecking
              ),
            // The padlock green, as in the connection test.
            ProxyHealthState.reachable => (
                SecurityIndicator.secure,
                loc.proxyTestOk
              ),
            ProxyHealthState.authRejected => (
                scheme.error,
                loc.proxyTestAuthRejected
              ),
            ProxyHealthState.unreachable => (
                scheme.error,
                loc.proxyTestUnreachable
              ),
          };
    final checking = !missing && state == ProxyHealthState.checking;
    final text = Text(
      label,
      style: theme.textTheme.bodySmall?.copyWith(color: color),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: IconSizes.inline,
          height: IconSizes.inline,
          child: Center(
            child: checking
                ? const SizedBox(
                    width: Spacing.md,
                    height: Spacing.md,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Container(
                    width: Spacing.sm,
                    height: Spacing.sm,
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
          ),
        ),
        const SizedBox(width: Spacing.xs),
        Flexible(child: _withDetail(health?.detail, text)),
        if (!missing)
          IconButton(
            icon: const Icon(Icons.refresh, size: IconSizes.inline),
            tooltip: loc.proxyStatusCheckAgain,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(
              minWidth: TapTargets.compact,
              minHeight: TapTargets.compact,
            ),
            onPressed:
                checking ? null : () => _service.check(proxy, force: true),
          ),
      ],
    );
  }

  /// The underlying error, verbatim, on long-press: paraphrasing it is what
  /// makes a proxy problem unreportable.
  Widget _withDetail(String? detail, Widget child) =>
      detail == null ? child : Tooltip(message: detail, child: child);
}

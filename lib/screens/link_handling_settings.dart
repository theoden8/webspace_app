import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/link_routing_service.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/hint_button.dart';

/// Global "Link handling" screen (LIR-008): master toggle + routing
/// overview + manual test entry. Tapping a site row opens [onOpenSiteEditor]
/// so the user can refine that site's [DomainClaim] list (LIR-008
/// scenario "Tap row opens site editor").
class LinkHandlingSettingsScreen extends StatefulWidget {
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;

  /// LIR-010 / discussion #439: when true, sending a shared link to a site
  /// also adopts the URL's host as a domain claim on that site; when false
  /// (default) the link just opens there. Opt-in.
  final bool claimDomains;
  final ValueChanged<bool> onClaimDomainsChanged;
  final List<WebViewModel> sites;
  final void Function(WebViewModel site) onOpenSiteEditor;

  /// LIR-010 manual re-route entry point (task 8.6). Invoked when the user
  /// types a URL into the test field; the host runs it through
  /// `LinkIntentDispatchEngine` and shows the picker / activation as if the
  /// URL had arrived via share intent.
  final Future<void> Function(Uri url)? onManualDispatch;

  const LinkHandlingSettingsScreen({
    super.key,
    required this.enabled,
    required this.onEnabledChanged,
    required this.claimDomains,
    required this.onClaimDomainsChanged,
    required this.sites,
    required this.onOpenSiteEditor,
    this.onManualDispatch,
  });

  @override
  State<LinkHandlingSettingsScreen> createState() =>
      _LinkHandlingSettingsScreenState();
}

class _LinkHandlingSettingsScreenState
    extends State<LinkHandlingSettingsScreen> {
  late TextEditingController _testUrlController;

  @override
  void initState() {
    super.initState();
    _testUrlController = TextEditingController();
  }

  @override
  void dispose() {
    _testUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final rows = _buildRoutingOverview(widget.sites);
    return Scaffold(
      appBar: AppBar(title: Text(loc.linkHandlingScreenTitle)),
      body: ListView(
        children: [
          SwitchListTile(
            title: Row(
              children: [
                Flexible(child: Text(loc.linkHandlingMasterToggleTitle)),
                HintButton(
                  title: loc.linkHandlingMasterToggleTitle,
                  description: loc.linkHandlingMasterToggleHint,
                ),
              ],
            ),
            value: widget.enabled,
            onChanged: widget.onEnabledChanged,
          ),
          SwitchListTile(
            title: Row(
              children: [
                Flexible(child: Text(loc.linkHandlingClaimDomainsToggleTitle)),
                HintButton(
                  title: loc.linkHandlingClaimDomainsToggleTitle,
                  description: loc.linkHandlingClaimDomainsToggleHint,
                ),
              ],
            ),
            value: widget.claimDomains,
            onChanged: widget.enabled ? widget.onClaimDomainsChanged : null,
          ),
          const Divider(height: 1),
          if (widget.onManualDispatch != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                loc.linkHandlingTestRoutingTitle,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _testUrlController,
                decoration: InputDecoration(
                  hintText: loc.linkHandlingTestUrlHint,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.send),
                    tooltip: loc.linkHandlingDispatchTooltip,
                    onPressed: widget.enabled ? _dispatch : null,
                  ),
                ),
                keyboardType: TextInputType.url,
                onSubmitted: (_) =>
                    widget.enabled ? _dispatch() : null,
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                loc.linkHandlingTestRoutingHint,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              loc.linkHandlingRoutingOverviewTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(loc.linkHandlingNoSites),
            )
          else
            ...rows,
        ],
      ),
    );
  }

  Future<void> _dispatch() async {
    final raw = _testUrlController.text.trim();
    if (raw.isEmpty) return;
    final parsed = Uri.tryParse(raw);
    if (parsed == null) {
      final loc = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.linkHandlingParseError)),
      );
      return;
    }
    await widget.onManualDispatch?.call(parsed);
  }

  List<Widget> _buildRoutingOverview(List<WebViewModel> sites) {
    if (sites.isEmpty) return const [];
    final rows = <Widget>[];
    for (final site in sites) {
      final claims = site.effectiveDomainClaims;
      final conflicts = LinkRoutingService.validateClaims(
        site.siteId,
        claims,
        sites
            .map((s) => _SiteRouteAdapter(s))
            .where((a) => a.siteId != site.siteId)
            .toList(growable: false),
      );
      final conflictedClaims = <DomainClaim>{
        for (final c in conflicts) c.claim,
      };
      rows.add(ListTile(
        title: Text(site.getDisplayName()),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final claim in claims)
                  _ClaimChip(
                    claim: claim,
                    isConflicting: conflictedClaims.contains(claim),
                  ),
              ],
            ),
            for (final c in conflicts)
              _ConflictExplanation(conflict: c, sites: sites),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => widget.onOpenSiteEditor(site),
      ));
    }
    return rows;
  }
}

class _ClaimChip extends StatelessWidget {
  final DomainClaim claim;
  final bool isConflicting;
  const _ClaimChip({required this.claim, this.isConflicting = false});

  @override
  Widget build(BuildContext context) {
    final label = _claimLabel(AppLocalizations.of(context), claim);
    if (!isConflicting) return Chip(label: Text(label));
    final scheme = Theme.of(context).colorScheme;
    return Chip(
      label: Text(label),
      backgroundColor: scheme.errorContainer,
      side: BorderSide(color: scheme.error),
      labelStyle: TextStyle(color: scheme.onErrorContainer),
    );
  }
}

String _claimLabel(AppLocalizations loc, DomainClaim claim) {
  switch (claim.kind) {
    case DomainClaimKind.exactHost:
      return claim.value;
    case DomainClaimKind.wildcardSubdomain:
      return '*.${claim.value}';
    case DomainClaimKind.baseDomain:
      return loc.linkHandlingClaimBaseLabel(claim.value);
  }
}

/// Single conflict line shown under a routing-overview row, e.g.
/// "Hijacks Site B (mastodon.social) via exactHost: mastodon.social".
/// Looks the other site up by id from the snapshot list so the message
/// names a real site rather than a raw uuid.
class _ConflictExplanation extends StatelessWidget {
  final ClaimConflict conflict;
  final List<WebViewModel> sites;
  const _ConflictExplanation({
    required this.conflict,
    required this.sites,
  });

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final other = sites.firstWhere(
      (s) => s.siteId == conflict.otherSiteId,
      orElse: () => sites.first,
    );
    final isHijack = conflict.kind == ClaimConflictKind.hijack;
    final color = isHijack ? scheme.error : scheme.tertiary;
    final otherName = other.getDisplayName();
    final claimLabel = _claimLabel(loc, conflict.claim);
    final message = isHijack
        ? loc.linkHandlingConflictHijacks(otherName, claimLabel)
        : loc.linkHandlingConflictOverlaps(otherName, claimLabel);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isHijack ? Icons.warning_amber_rounded : Icons.info_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _SiteRouteAdapter implements RoutableSite {
  final WebViewModel model;
  const _SiteRouteAdapter(this.model);

  @override
  String get siteId => model.siteId;

  @override
  String get initUrl => model.initUrl;

  @override
  List<DomainClaim> get domainClaims => model.effectiveDomainClaims;
}

/// Per-site domain-claim editor (LIR-008 task 8.4). Embedded in the
/// per-site settings screen. Surfaces add / remove for `exactHost` and
/// `wildcardSubdomain` claims; the synthesized `baseDomain` claim is
/// displayed but not editable (it's auto-derived from `initUrl`).
class DomainClaimsEditor extends StatefulWidget {
  final WebViewModel model;
  final List<WebViewModel> otherSites;
  final ValueChanged<List<DomainClaim>?> onChanged;

  const DomainClaimsEditor({
    super.key,
    required this.model,
    required this.otherSites,
    required this.onChanged,
  });

  @override
  State<DomainClaimsEditor> createState() => _DomainClaimsEditorState();
}

class _DomainClaimsEditorState extends State<DomainClaimsEditor> {
  late List<DomainClaim> _claims;

  @override
  void initState() {
    super.initState();
    _claims = List<DomainClaim>.from(widget.model.effectiveDomainClaims);
  }

  void _commit(List<DomainClaim> next) {
    setState(() {
      _claims = next;
    });
    final defaultClaims = widget.model.effectiveDomainClaims;
    if (next.length == defaultClaims.length &&
        next.every((c) => defaultClaims.contains(c)) &&
        defaultClaims.every((c) => next.contains(c)) &&
        widget.model.domainClaims == null) {
      widget.onChanged(null);
    } else {
      widget.onChanged(next);
    }
  }

  Future<void> _addClaim() async {
    final result = await showDialog<DomainClaim>(
      context: context,
      builder: (ctx) => const _AddClaimDialog(),
    );
    if (result == null) return;
    if (_claims.contains(result)) return;
    _commit([..._claims, result]);
  }

  void _removeAt(int i) {
    final next = [..._claims]..removeAt(i);
    _commit(next);
  }

  @override
  Widget build(BuildContext context) {
    final adapters = widget.otherSites
        .map((s) => _SiteRouteAdapter(s))
        .toList(growable: false);
    final conflicts = LinkRoutingService.validateClaims(
      widget.model.siteId,
      _claims,
      adapters,
    );
    final conflictsByClaim = <DomainClaim, List<ClaimConflict>>{};
    for (final c in conflicts) {
      conflictsByClaim.putIfAbsent(c.claim, () => []).add(c);
    }
    final loc = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  loc.linkHandlingDomainClaimsTitle,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              HintButton(
                title: loc.linkHandlingDomainClaimsTitle,
                description: loc.linkHandlingDomainClaimsHint,
              ),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: loc.linkHandlingAddClaimTooltip,
                onPressed: _addClaim,
              ),
            ],
          ),
        ),
        for (var i = 0; i < _claims.length; i++)
          _ClaimRow(
            claim: _claims[i],
            conflicts: conflictsByClaim[_claims[i]] ?? const [],
            onRemove: _claims[i].kind == DomainClaimKind.baseDomain &&
                    _claims.length == 1
                ? null
                : () => _removeAt(i),
          ),
      ],
    );
  }
}

class _ClaimRow extends StatelessWidget {
  final DomainClaim claim;
  final List<ClaimConflict> conflicts;
  final VoidCallback? onRemove;

  const _ClaimRow({
    required this.claim,
    required this.conflicts,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final label = _claimLabel(loc, claim);
    final hasHijack =
        conflicts.any((c) => c.kind == ClaimConflictKind.hijack);
    return ListTile(
      title: Text(label),
      subtitle: hasHijack
          ? Text(
              loc.linkHandlingClaimHijackConflict,
              style: const TextStyle(color: Colors.red),
            )
          : conflicts.isNotEmpty
              ? Text(loc.linkHandlingClaimOverlapConflict)
              : null,
      trailing: onRemove == null
          ? null
          : IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: onRemove,
            ),
    );
  }
}

class _AddClaimDialog extends StatefulWidget {
  const _AddClaimDialog();

  @override
  State<_AddClaimDialog> createState() => _AddClaimDialogState();
}

class _AddClaimDialogState extends State<_AddClaimDialog> {
  DomainClaimKind _kind = DomainClaimKind.exactHost;
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(loc.linkHandlingAddClaimDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButton<DomainClaimKind>(
            value: _kind,
            isExpanded: true,
            onChanged: (v) {
              if (v != null) setState(() => _kind = v);
            },
            items: [
              DropdownMenuItem(
                value: DomainClaimKind.exactHost,
                child: Text(loc.linkHandlingClaimKindExactHost),
              ),
              DropdownMenuItem(
                value: DomainClaimKind.wildcardSubdomain,
                child: Text(loc.linkHandlingClaimKindWildcard),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: loc.linkHandlingHostnameLabel,
              border: const OutlineInputBorder(),
              hintText: loc.linkHandlingHostnameHint,
            ),
            keyboardType: TextInputType.url,
            autofocus: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(loc.commonCancel),
        ),
        ElevatedButton(
          onPressed: () {
            final v = _controller.text.trim();
            if (v.isEmpty) return;
            Navigator.of(context).pop(DomainClaim(_kind, v));
          },
          child: Text(loc.commonAdd),
        ),
      ],
    );
  }
}

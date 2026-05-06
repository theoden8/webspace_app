import 'package:flutter/material.dart';
import 'package:webspace/services/link_routing_service.dart';
import 'package:webspace/web_view_model.dart';

/// Global "Link handling" screen (LIR-008): master toggle + routing
/// overview + manual test entry. Tapping a site row opens [onOpenSiteEditor]
/// so the user can refine that site's [DomainClaim] list (LIR-008
/// scenario "Tap row opens site editor").
class LinkHandlingSettingsScreen extends StatefulWidget {
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;
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
    final rows = _buildRoutingOverview(widget.sites);
    return Scaffold(
      appBar: AppBar(title: const Text('Link handling')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Handle shared links'),
            subtitle: const Text(
              'When off, share intents and webspace:// URLs are dropped silently. '
              'Use to keep the app installed without making it the default for other apps.',
            ),
            value: widget.enabled,
            onChanged: widget.onEnabledChanged,
          ),
          const Divider(height: 1),
          if (widget.onManualDispatch != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Test routing',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _testUrlController,
                decoration: InputDecoration(
                  hintText: 'https://example.org/foo',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.send),
                    tooltip: 'Dispatch through routing engine',
                    onPressed: widget.enabled ? _dispatch : null,
                  ),
                ),
                keyboardType: TextInputType.url,
                onSubmitted: (_) =>
                    widget.enabled ? _dispatch() : null,
              ),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Re-runs the LIR-010 picker for an arbitrary URL — useful when '
                'the resolver auto-routes to a site you wanted to override.',
                style: TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Routing overview',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No sites yet.'),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not parse URL')),
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
      rows.add(ListTile(
        title: Text(site.getDisplayName()),
        subtitle: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final claim in claims) _ClaimChip(claim: claim),
            if (conflicts.isNotEmpty)
              Chip(
                label: Text('${conflicts.length} conflict'
                    '${conflicts.length == 1 ? '' : 's'}'),
                backgroundColor:
                    Theme.of(context).colorScheme.errorContainer,
              ),
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
  const _ClaimChip({required this.claim});

  @override
  Widget build(BuildContext context) {
    final label = switch (claim.kind) {
      DomainClaimKind.exactHost => claim.value,
      DomainClaimKind.wildcardSubdomain => '*.${claim.value}',
      DomainClaimKind.baseDomain => '${claim.value} (base)',
    };
    return Chip(label: Text(label));
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Domain claims',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'Add claim',
                onPressed: _addClaim,
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Which hostnames route to this site when shared from another app. '
            'Existing sites synthesize one base-domain claim from their URL.',
            style: TextStyle(fontSize: 12),
          ),
        ),
        const SizedBox(height: 8),
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
    final label = switch (claim.kind) {
      DomainClaimKind.exactHost => claim.value,
      DomainClaimKind.wildcardSubdomain => '*.${claim.value}',
      DomainClaimKind.baseDomain => '${claim.value} (base)',
    };
    final hasHijack =
        conflicts.any((c) => c.kind == ClaimConflictKind.hijack);
    return ListTile(
      title: Text(label),
      subtitle: hasHijack
          ? const Text(
              'Conflict: another site already owns this base domain.',
              style: TextStyle(color: Colors.red),
            )
          : conflicts.isNotEmpty
              ? const Text('Overlaps with another site (non-blocking).')
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
    return AlertDialog(
      title: const Text('Add domain claim'),
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
            items: const [
              DropdownMenuItem(
                value: DomainClaimKind.exactHost,
                child: Text('Exact host (e.g. mail.google.com)'),
              ),
              DropdownMenuItem(
                value: DomainClaimKind.wildcardSubdomain,
                child: Text('Wildcard subdomain (*.google.com)'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            decoration: const InputDecoration(
              labelText: 'Hostname',
              border: OutlineInputBorder(),
              hintText: 'example.com',
            ),
            keyboardType: TextInputType.url,
            autofocus: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final v = _controller.text.trim();
            if (v.isEmpty) return;
            Navigator.of(context).pop(DomainClaim(_kind, v));
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}

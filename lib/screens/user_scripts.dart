import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:webspace/settings/user_script.dart';

/// Screen for managing per-site user scripts.
///
/// Edits apply to the model immediately via [onSave]. The parent Settings
/// screen handles webview reload when "Save Settings" is tapped.
class UserScriptsScreen extends StatefulWidget {
  final String title;
  final List<UserScriptConfig> userScripts;
  final void Function(List<UserScriptConfig>) onSave;
  /// Execute a script source on the current webview immediately.
  /// Returns console output captured during execution.
  final Future<String> Function(String source)? onRun;
  /// Callback to promote a script to global. When set, a long-press
  /// context menu offers "Make Global". The callback receives the script
  /// to add to global scripts; the caller is responsible for persisting it.
  final void Function(UserScriptConfig script)? onMakeGlobal;
  /// Global scripts displayed alongside site scripts (editable).
  final List<UserScriptConfig> globalUserScripts;
  /// Callback when global scripts change (edit/toggle).
  final void Function(List<UserScriptConfig>)? onGlobalUserScriptsChanged;

  const UserScriptsScreen({
    super.key,
    this.title = 'User Scripts',
    required this.userScripts,
    required this.onSave,
    this.onRun,
    this.onMakeGlobal,
    this.globalUserScripts = const [],
    this.onGlobalUserScriptsChanged,
  });

  @override
  State<UserScriptsScreen> createState() => _UserScriptsScreenState();
}

class _UserScriptsScreenState extends State<UserScriptsScreen> {
  late List<UserScriptConfig> _scripts;
  late List<UserScriptConfig> _globalScripts;

  bool get _hasGlobal => _globalScripts.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _scripts = _deepCopy(widget.userScripts);
    _globalScripts = _deepCopy(widget.globalUserScripts);
  }

  static List<UserScriptConfig> _deepCopy(List<UserScriptConfig> scripts) {
    return scripts
        .map((s) => UserScriptConfig(
              name: s.name,
              source: s.source,
              url: s.url,
              urlSource: s.urlSource,
              injectionTime: s.injectionTime,
              enabled: s.enabled,
            ))
        .toList();
  }

  void _syncSite() {
    widget.onSave(_scripts);
  }

  void _syncGlobal() {
    widget.onGlobalUserScriptsChanged?.call(_globalScripts);
  }

  void _addScript() async {
    final result = await Navigator.push<UserScriptConfig>(
      context,
      MaterialPageRoute(
        builder: (_) => UserScriptEditScreen(onRun: widget.onRun),
      ),
    );
    if (result != null) {
      setState(() => _scripts.add(result));
      _syncSite();
    }
  }

  void _editScript(int index) async {
    final result = await Navigator.push<UserScriptConfig>(
      context,
      MaterialPageRoute(
        builder: (_) => UserScriptEditScreen(
          script: _scripts[index],
          onRun: widget.onRun,
        ),
      ),
    );
    if (result != null) {
      setState(() => _scripts[index] = result);
      _syncSite();
    }
  }

  void _deleteScript(int index) {
    setState(() => _scripts.removeAt(index));
    _syncSite();
  }

  Future<void> _makeGlobal(int index) async {
    final script = _scripts[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Make Global'),
        content: Text(
          'Copy "${script.name}" to global scripts?\n\n'
          'It will run on all sites. The site copy will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Make Global'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      setState(() {
        _globalScripts.add(_scripts.removeAt(index));
      });
      _syncSite();
      _syncGlobal();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${script.name}" moved to global scripts')),
        );
      }
    }
  }

  void _editGlobalScript(int index) async {
    final result = await Navigator.push<UserScriptConfig>(
      context,
      MaterialPageRoute(
        builder: (_) => UserScriptEditScreen(
          script: _globalScripts[index],
          onRun: widget.onRun,
        ),
      ),
    );
    if (result != null) {
      setState(() => _globalScripts[index] = result);
      _syncGlobal();
    }
  }

  Widget _buildBody() {
    final allEmpty = _scripts.isEmpty && _globalScripts.isEmpty;
    if (allEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32.0),
          child: Text(
            'No user scripts.\nTap + to add a script.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return ListView(
      children: [
        // Global scripts section
        for (var i = 0; i < _globalScripts.length; i++)
          _buildGlobalTile(i),
        if (_hasGlobal && _scripts.isNotEmpty)
          const Divider(height: 1),
        // Site scripts section (reorderable)
        if (_scripts.isNotEmpty)
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _scripts.length,
            onReorder: (oldIndex, newIndex) {
              setState(() {
                if (newIndex > oldIndex) newIndex--;
                final item = _scripts.removeAt(oldIndex);
                _scripts.insert(newIndex, item);
              });
              _syncSite();
            },
            buildDefaultDragHandles: false,
            itemBuilder: (context, index) {
              final script = _scripts[index];
              return Dismissible(
                key: ValueKey('site_${script.name}_$index'),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Colors.red,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 16),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                onDismissed: (_) => _deleteScript(index),
                child: ListTile(
                  leading: ReorderableDragStartListener(
                    index: index,
                    child: const Icon(Icons.drag_handle),
                  ),
                  title: Text(script.name),
                  subtitle: Text(
                    script.injectionTime == UserScriptInjectionTime.atDocumentStart
                        ? 'Runs at document start'
                        : 'Runs at document end',
                  ),
                  trailing: Switch(
                    value: script.enabled,
                    onChanged: (value) {
                      setState(() => script.enabled = value);
                      _syncSite();
                    },
                  ),
                  onTap: () => _editScript(index),
                  onLongPress: widget.onMakeGlobal != null || widget.onGlobalUserScriptsChanged != null
                      ? () => _makeGlobal(index)
                      : null,
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _buildGlobalTile(int index) {
    final script = _globalScripts[index];
    return ListTile(
      leading: Icon(Icons.public, size: 20, color: Theme.of(context).colorScheme.primary),
      title: Row(
        children: [
          Expanded(child: Text(script.name)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'Global',
              style: TextStyle(
                fontSize: 10,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
      subtitle: Text(
        script.injectionTime == UserScriptInjectionTime.atDocumentStart
            ? 'Runs at document start'
            : 'Runs at document end',
      ),
      trailing: Switch(
        value: script.enabled,
        onChanged: widget.onGlobalUserScriptsChanged != null
            ? (value) {
                setState(() => script.enabled = value);
                _syncGlobal();
              }
            : null,
      ),
      onTap: widget.onGlobalUserScriptsChanged != null
          ? () => _editGlobalScript(index)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addScript,
        child: const Icon(Icons.add),
      ),
      body: _buildBody(),
    );
  }
}

/// Screen for creating or editing a single user script.
class UserScriptEditScreen extends StatefulWidget {
  final UserScriptConfig? script;
  /// Execute a script and return console output captured during execution.
  final Future<String> Function(String source)? onRun;

  const UserScriptEditScreen({super.key, this.script, this.onRun});

  @override
  State<UserScriptEditScreen> createState() => _UserScriptEditScreenState();
}

class _UserScriptEditScreenState extends State<UserScriptEditScreen> {
  late TextEditingController _nameController;
  late TextEditingController _sourceController;
  late TextEditingController _urlController;
  late UserScriptInjectionTime _injectionTime;
  late bool _enabled;
  String? _urlSource;
  String? _originalUrl;
  bool _downloading = false;
  bool _saving = false;
  String? _runOutput;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.script?.name ?? '');
    _sourceController = TextEditingController(text: widget.script?.source ?? '');
    _urlController = TextEditingController(text: widget.script?.url ?? '');
    _injectionTime = widget.script?.injectionTime ?? UserScriptInjectionTime.atDocumentEnd;
    _enabled = widget.script?.enabled ?? true;
    _urlSource = widget.script?.urlSource;
    _originalUrl = widget.script?.url;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _sourceController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    _saving = true;
    try {
      await _saveInner();
    } finally {
      _saving = false;
    }
  }

  Future<void> _saveInner() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Script name is required')),
      );
      return;
    }
    final url = _urlController.text.trim();
    // Auto-download URL source if URL is set and either not yet cached or URL changed.
    if (url.isNotEmpty && (_urlSource == null || url != _originalUrl)) {
      setState(() { _downloading = true; });
      try {
        final response = await http.get(Uri.parse(url));
        if (!mounted) return;
        if (response.statusCode == 200) {
          _urlSource = response.body;
        } else {
          setState(() { _downloading = false; });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('URL download failed: HTTP ${response.statusCode}')),
          );
          return;
        }
      } catch (e) {
        if (!mounted) return;
        setState(() { _downloading = false; });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('URL download failed: $e')),
        );
        return;
      }
    }
    // Clear urlSource if URL was removed.
    if (url.isEmpty) _urlSource = null;
    if (!mounted) return;
    Navigator.pop(
      context,
      UserScriptConfig(
        name: name,
        source: _sourceController.text,
        url: url.isEmpty ? null : url,
        urlSource: _urlSource,
        injectionTime: _injectionTime,
        enabled: _enabled,
      ),
    );
  }

  Future<void> _runScript() async {
    if (widget.onRun == null) return;
    final src = UserScriptConfig(
      name: '',
      source: _sourceController.text,
      urlSource: _urlSource,
    ).fullSource;
    if (src.isEmpty) return;
    setState(() { _runOutput = 'Running...'; });
    try {
      final output = await widget.onRun!(src);
      if (mounted) {
        setState(() { _runOutput = output; });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _runOutput = 'Error: $e'; });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.script != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Script' : 'New Script'),
        actions: [
          if (widget.onRun != null)
            IconButton(
              icon: const Icon(Icons.play_arrow),
              onPressed: _runScript,
              tooltip: 'Run',
            ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _save,
            tooltip: 'Save',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _urlController,
            decoration: InputDecoration(
              labelText: 'Script URL (optional)',
              hintText: 'https://cdn.jsdelivr.net/npm/package/lib.min.js',
              border: const OutlineInputBorder(),
              suffixIcon: _downloading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
          ),
          if (_urlSource != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Cached: ${_urlSource!.length} bytes'
                    '${_urlController.text.trim() != _originalUrl ? ' (will re-download on save)' : ''}',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ),
          const SizedBox(height: 16),
          DropdownButtonFormField<UserScriptInjectionTime>(
            value: _injectionTime,
            decoration: const InputDecoration(
              labelText: 'Injection Time',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: UserScriptInjectionTime.atDocumentStart,
                child: Text('At document start'),
              ),
              DropdownMenuItem(
                value: UserScriptInjectionTime.atDocumentEnd,
                child: Text('At document end'),
              ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _injectionTime = value);
            },
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('Enabled'),
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _sourceController,
            decoration: InputDecoration(
              labelText: _urlSource != null ? 'JavaScript Source (runs after URL script)' : 'JavaScript Source',
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            maxLines: 15,
            minLines: 8,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          if (_runOutput != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _runOutput!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:webspace/settings/user_script.dart';

/// Screen for managing per-site user scripts.
///
/// Edits apply to the model immediately via [onSave]. The parent Settings
/// screen handles webview reload when "Save Settings" is tapped.
class UserScriptsScreen extends StatefulWidget {
  final List<UserScriptConfig> userScripts;
  final void Function(List<UserScriptConfig>) onSave;
  /// Execute a script source on the current webview immediately.
  /// Returns console output captured during execution.
  final Future<String> Function(String source)? onRun;

  const UserScriptsScreen({
    super.key,
    required this.userScripts,
    required this.onSave,
    this.onRun,
  });

  @override
  State<UserScriptsScreen> createState() => _UserScriptsScreenState();
}

class _UserScriptsScreenState extends State<UserScriptsScreen> {
  late List<UserScriptConfig> _scripts;

  @override
  void initState() {
    super.initState();
    // Deep copy so list operations are clean
    _scripts = widget.userScripts
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

  void _sync() {
    widget.onSave(_scripts);
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
      _sync();
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
      _sync();
    }
  }

  void _deleteScript(int index) {
    setState(() => _scripts.removeAt(index));
    _sync();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('User Scripts'),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addScript,
        child: const Icon(Icons.add),
      ),
      body: _scripts.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32.0),
                child: Text(
                  'No user scripts.\nTap + to add a script.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            )
          : ReorderableListView.builder(
              itemCount: _scripts.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex--;
                  final item = _scripts.removeAt(oldIndex);
                  _scripts.insert(newIndex, item);
                });
                _sync();
              },
              itemBuilder: (context, index) {
                final script = _scripts[index];
                return Dismissible(
                  key: ValueKey('${script.name}_$index'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 16),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  onDismissed: (_) => _deleteScript(index),
                  child: ListTile(
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
                        _sync();
                      },
                    ),
                    onTap: () => _editScript(index),
                  ),
                );
              },
            ),
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
  bool _downloading = false;
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
  }

  @override
  void dispose() {
    _nameController.dispose();
    _sourceController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Script name is required')),
      );
      return;
    }
    final url = _urlController.text.trim();
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

  Future<void> _downloadUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() { _downloading = true; });
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        setState(() {
          _urlSource = response.body;
          _downloading = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Downloaded ${response.body.length} bytes')),
          );
        }
      } else {
        setState(() { _downloading = false; });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Download failed: HTTP ${response.statusCode}')),
          );
        }
      }
    } catch (e) {
      setState(() { _downloading = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e')),
        );
      }
    }
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
              hintText: 'https://cdn.jsdelivr.net/npm/darkreader/darkreader.min.js',
              border: const OutlineInputBorder(),
              suffixIcon: _downloading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      icon: Icon(_urlSource != null ? Icons.sync : Icons.download),
                      tooltip: _urlSource != null ? 'Re-download' : 'Download',
                      onPressed: _urlController.text.trim().isEmpty ? null : _downloadUrl,
                    ),
            ),
          ),
          if (_urlSource != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Cached: ${_urlSource!.length} bytes',
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

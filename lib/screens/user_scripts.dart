import 'package:flutter/material.dart';

import 'package:webspace/settings/user_script.dart';

/// Screen for managing per-site user scripts.
class UserScriptsScreen extends StatefulWidget {
  final List<UserScriptConfig> userScripts;
  final void Function(List<UserScriptConfig>) onSave;

  const UserScriptsScreen({
    super.key,
    required this.userScripts,
    required this.onSave,
  });

  @override
  State<UserScriptsScreen> createState() => _UserScriptsScreenState();
}

class _UserScriptsScreenState extends State<UserScriptsScreen> {
  late List<UserScriptConfig> _scripts;

  @override
  void initState() {
    super.initState();
    // Deep copy so edits don't mutate the original until saved
    _scripts = widget.userScripts
        .map((s) => UserScriptConfig(
              name: s.name,
              source: s.source,
              injectionTime: s.injectionTime,
              enabled: s.enabled,
            ))
        .toList();
  }

  void _addScript() async {
    final result = await Navigator.push<UserScriptConfig>(
      context,
      MaterialPageRoute(builder: (_) => const UserScriptEditScreen()),
    );
    if (result != null) {
      setState(() => _scripts.add(result));
    }
  }

  void _editScript(int index) async {
    final result = await Navigator.push<UserScriptConfig>(
      context,
      MaterialPageRoute(
        builder: (_) => UserScriptEditScreen(script: _scripts[index]),
      ),
    );
    if (result != null) {
      setState(() => _scripts[index] = result);
    }
  }

  void _deleteScript(int index) {
    setState(() => _scripts.removeAt(index));
  }

  void _save() {
    widget.onSave(_scripts);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('User Scripts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _save,
            tooltip: 'Save',
          ),
        ],
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

  const UserScriptEditScreen({super.key, this.script});

  @override
  State<UserScriptEditScreen> createState() => _UserScriptEditScreenState();
}

class _UserScriptEditScreenState extends State<UserScriptEditScreen> {
  late TextEditingController _nameController;
  late TextEditingController _sourceController;
  late UserScriptInjectionTime _injectionTime;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.script?.name ?? '');
    _sourceController = TextEditingController(text: widget.script?.source ?? '');
    _injectionTime = widget.script?.injectionTime ?? UserScriptInjectionTime.atDocumentEnd;
    _enabled = widget.script?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _sourceController.dispose();
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
    Navigator.pop(
      context,
      UserScriptConfig(
        name: name,
        source: _sourceController.text,
        injectionTime: _injectionTime,
        enabled: _enabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.script != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Script' : 'New Script'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
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
            decoration: const InputDecoration(
              labelText: 'JavaScript Source',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            maxLines: 15,
            minLines: 8,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ],
      ),
    );
  }
}

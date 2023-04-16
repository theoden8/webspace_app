import 'package:flutter/material.dart';

import 'main.dart';
import 'web_view_model.dart';
import 'settings/proxy.dart';

class SettingsPage extends StatefulWidget {
  final WebViewModel webViewModel;

  SettingsPage({required this.webViewModel});

  @override
  _SettingsPageState createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late ProxySettings _proxySettings;

  @override
  void initState() {
    super.initState();
    _proxySettings = widget.webViewModel.proxySettings;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            title: Text('Proxy Type'),
            trailing: DropdownButton<ProxyType>(
              value: _proxySettings.type,
              onChanged: (ProxyType? newValue) {
                if (newValue != null) {
                  setState(() {
                    _proxySettings.type = newValue;
                  });
                }
              },
              items: ProxyType.values.map<DropdownMenuItem<ProxyType>>(
                (ProxyType value) {
                  return DropdownMenuItem<ProxyType>(
                    value: value,
                    child: Text(value.toString().split('.').last),
                  );
                },
              ).toList(),
            ),
          ),
          if (_proxySettings.type != ProxyType.DEFAULT)
            ListTile(
              title: TextField(
                onChanged: (value) {
                  _proxySettings.address = value;
                },
                decoration: InputDecoration(
                  labelText: 'Proxy Address',
                ),
              ),
            ),
          SwitchListTile(
            title: Text('JavaScript Enabled'),
            value: widget.webViewModel.javascriptEnabled,
            onChanged: (bool value) {
              setState(() {
                widget.webViewModel.javascriptEnabled = value;
              });
            },
          ),
          ElevatedButton(
            onPressed: () {
              widget.webViewModel.proxySettings = _proxySettings;
              Navigator.pop(context);
            },
            child: Text('Save Settings'),
          ),
        ],
      ),
    );
  }
}

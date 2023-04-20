import 'dart:math';
import 'package:flutter/material.dart';

import 'main.dart';
import 'web_view_model.dart';
import 'settings/proxy.dart';

String generateRandomUserAgent() {
  // You can modify these values to add more variety to the generated user-agent strings
  List<String> platforms = [
    'Windows NT 10.0; Win64; x64',
    'Macintosh; Intel Mac OS X 10_15_7',
    'X11; Linux x86_64',
    'iPhone; CPU iPhone OS 15_4 like Mac OS X',
    'Android 13; Mobile', // Add an Android platform
  ];

  String geckoVersion = '112';
  String geckoTrail = '20100101';
  String appName = 'Firefox';
  String appVersion = '102.0';

  String platform = platforms[Random().nextInt(platforms.length)];
  return 'Mozilla/5.0 ($platform; rv:$geckoVersion) Gecko/$geckoTrail $appName/$appVersion';
}

class SettingsPage extends StatefulWidget {
  final WebViewModel webViewModel;

  SettingsPage({required this.webViewModel});

  @override
  _SettingsPageState createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late ProxySettings _proxySettings;
  late TextEditingController _userAgentController;
  late bool _javascriptEnabled;
  late bool _thirdPartyCookiesEnabled;

  @override
  void initState() {
    super.initState();
    _proxySettings = widget.webViewModel.proxySettings;
    _userAgentController = TextEditingController(
      text: widget.webViewModel.userAgent ?? '',
    );
    _javascriptEnabled = widget.webViewModel.javascriptEnabled;
    _thirdPartyCookiesEnabled = widget.webViewModel.thirdPartyCookiesEnabled;
  }

  @override
  void dispose() {
    _userAgentController.dispose();
    super.dispose();
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
            value: _javascriptEnabled,
            onChanged: (bool value) {
              setState(() {
                _javascriptEnabled = value;
              });
            },
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextFormField(
                  decoration: InputDecoration(labelText: 'User-Agent'),
                  controller: _userAgentController,
                ),
              ),
              SizedBox(width: 8), // Add some spacing between the text field and the button
              IconButton(
                onPressed: () {
                  String newUserAgent = generateRandomUserAgent();
                  setState(() {
                    _userAgentController.text = newUserAgent;
                  });
                },
                icon: Icon(Icons.autorenew), // Use an appropriate icon for generating user-agent
                color: Theme.of(context).primaryColor,
                iconSize: 24, // Adjust the icon size as needed
              ),
            ],
          ),
          SwitchListTile(
            title: const Text('Third-party cookies'),
            value: _thirdPartyCookiesEnabled,
            onChanged: (bool value) {
              setState(() {
                _thirdPartyCookiesEnabled = value;
              });
            },
          ),
          ElevatedButton(
            onPressed: () {
              widget.webViewModel.proxySettings = _proxySettings;
              if (_userAgentController.text != '') {
                widget.webViewModel.userAgent = _userAgentController.text;
              }
              widget.webViewModel.javascriptEnabled = _javascriptEnabled;
              widget.webViewModel.thirdPartyCookiesEnabled = _thirdPartyCookiesEnabled;
              Navigator.pop(context);
            },
            child: Text('Save Settings'),
          ),
        ],
      ),
    );
  }
}

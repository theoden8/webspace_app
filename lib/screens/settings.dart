import 'dart:math';

import 'package:flutter/material.dart';

import 'package:webspace/web_view_model.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/platform/webview.dart';

String generateRandomUserAgent() {
  // You can modify these values to add more variety to the generated user-agent strings
  List<String> platforms = [
    'Windows NT 10.0; Win64; x64',
    'Macintosh; Intel Mac OS X 10_15_7',
    'Linux x86_64',
    'iPhone; CPU iPhone OS 15_7_3 like Mac OS X',
    'Android 16; Mobile', // Add an Android platform
  ];

  String geckoVersion = '147.0';
  String geckoTrail = '20100101';
  String appName = 'Firefox';
  String appVersion = '147.0';

  String platform = platforms[Random().nextInt(platforms.length)];
  return 'Mozilla/5.0 ($platform; rv:$geckoVersion) Gecko/$geckoTrail $appName/$appVersion';
}

class SettingsScreen extends StatefulWidget {
  final WebViewModel webViewModel;
  /// Callback to sync proxy settings across all WebViewModels
  final void Function(UserProxySettings)? onProxySettingsChanged;

  SettingsScreen({
    required this.webViewModel,
    this.onProxySettingsChanged,
  });

  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late UserProxySettings _proxySettings;
  late TextEditingController _userAgentController;
  late TextEditingController _proxyAddressController;
  late TextEditingController _proxyUsernameController;
  late TextEditingController _proxyPasswordController;
  late bool _javascriptEnabled;
  late bool _thirdPartyCookiesEnabled;
  late bool _incognito;
  bool _obscureProxyPassword = true;
  bool _showProxyCredentials = false;

  String getResetUserAgent() {
    return (widget.webViewModel.userAgent == '') ? (widget.webViewModel.defaultUserAgent ?? '') : widget.webViewModel.userAgent;
  }

  @override
  void initState() {
    super.initState();
    // Force DEFAULT proxy on unsupported platforms
    _proxySettings = UserProxySettings(
      type: PlatformInfo.isProxySupported
          ? widget.webViewModel.proxySettings.type
          : ProxyType.DEFAULT,
      address: PlatformInfo.isProxySupported
          ? widget.webViewModel.proxySettings.address
          : null,
      username: PlatformInfo.isProxySupported
          ? widget.webViewModel.proxySettings.username
          : null,
      password: PlatformInfo.isProxySupported
          ? widget.webViewModel.proxySettings.password
          : null,
    );
    _userAgentController = TextEditingController(
      text: getResetUserAgent(),
    );
    _proxyAddressController = TextEditingController(
      text: _proxySettings.address ?? '',
    );
    _proxyUsernameController = TextEditingController(
      text: _proxySettings.username ?? '',
    );
    _proxyPasswordController = TextEditingController(
      text: _proxySettings.password ?? '',
    );
    _javascriptEnabled = widget.webViewModel.javascriptEnabled;
    _thirdPartyCookiesEnabled = widget.webViewModel.thirdPartyCookiesEnabled;
    _incognito = widget.webViewModel.incognito;
    // Show credentials section if credentials already exist
    _showProxyCredentials = _proxySettings.hasCredentials;
  }

  @override
  void dispose() {
    _userAgentController.dispose();
    _proxyAddressController.dispose();
    _proxyUsernameController.dispose();
    _proxyPasswordController.dispose();
    super.dispose();
  }

  String? _validateProxyAddress(String? value) {
    if (_proxySettings.type == ProxyType.DEFAULT) {
      return null;
    }
    
    if (value == null || value.isEmpty) {
      return 'Proxy address is required';
    }
    
    final parts = value.split(':');
    if (parts.length != 2) {
      return 'Format: host:port (e.g., proxy.example.com:1080)';
    }
    
    final port = int.tryParse(parts[1]);
    if (port == null || port < 1 || port > 65535) {
      return 'Invalid port number (1-65535)';
    }
    
    return null;
  }

  Future<void> _saveSettings() async {
    // Only validate and update proxy settings on supported platforms
    if (PlatformInfo.isProxySupported) {
      // Validate proxy address if needed
      final proxyError = _validateProxyAddress(_proxyAddressController.text);
      if (proxyError != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Proxy Error: $proxyError')),
        );
        return;
      }
    }

    try {
      // Update proxy settings only on supported platforms
      if (PlatformInfo.isProxySupported) {
        _proxySettings.address = _proxyAddressController.text.isEmpty
            ? null
            : _proxyAddressController.text;
        // Only save credentials if the checkbox is enabled
        if (_showProxyCredentials) {
          _proxySettings.username = _proxyUsernameController.text.isEmpty
              ? null
              : _proxyUsernameController.text;
          _proxySettings.password = _proxyPasswordController.text.isEmpty
              ? null
              : _proxyPasswordController.text;
        } else {
          _proxySettings.username = null;
          _proxySettings.password = null;
        }

        widget.webViewModel.proxySettings = _proxySettings;

        // Apply proxy settings immediately
        await widget.webViewModel.updateProxySettings(_proxySettings);

        // Sync proxy settings to all other WebViewModels (proxy is global)
        widget.onProxySettingsChanged?.call(_proxySettings);
      } else {
        // Force DEFAULT proxy on unsupported platforms
        final defaultProxy = UserProxySettings(type: ProxyType.DEFAULT);
        widget.webViewModel.proxySettings = defaultProxy;
        await widget.webViewModel.updateProxySettings(defaultProxy);
      }

      // Update other settings
      if (_userAgentController.text != '') {
        widget.webViewModel.userAgent = _userAgentController.text;
      }
      widget.webViewModel.javascriptEnabled = _javascriptEnabled;
      widget.webViewModel.thirdPartyCookiesEnabled = _thirdPartyCookiesEnabled;
      widget.webViewModel.incognito = _incognito;

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Settings saved successfully')),
      );

      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving settings: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Settings')),
      body: ListView(
        children: [
          // Only show proxy settings on supported platforms
          if (PlatformInfo.isProxySupported) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Text(
                'Proxy settings are shared across all sites.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
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
            if (_proxySettings.type != ProxyType.DEFAULT) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: TextFormField(
                  controller: _proxyAddressController,
                  decoration: InputDecoration(
                    labelText: 'Proxy Address',
                    hintText: 'host:port (e.g., proxy.example.com:1080)',
                    helperText: 'Format: host:port',
                    border: OutlineInputBorder(),
                  ),
                  validator: _validateProxyAddress,
                ),
              ),
              CheckboxListTile(
                title: Text('Proxy requires authentication'),
                value: _showProxyCredentials,
                onChanged: (bool? value) {
                  setState(() {
                    _showProxyCredentials = value ?? false;
                  });
                },
                controlAffinity: ListTileControlAffinity.leading,
              ),
              if (_showProxyCredentials) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: TextFormField(
                    controller: _proxyUsernameController,
                    decoration: InputDecoration(
                      labelText: 'Proxy Username',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: TextFormField(
                    controller: _proxyPasswordController,
                    obscureText: _obscureProxyPassword,
                    decoration: InputDecoration(
                      labelText: 'Proxy Password',
                      border: OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureProxyPassword ? Icons.visibility : Icons.visibility_off,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscureProxyPassword = !_obscureProxyPassword;
                          });
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ],
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
              IconButton(
                onPressed: () {
                  setState(() {
                    _userAgentController.text = widget.webViewModel.defaultUserAgent ?? widget.webViewModel.userAgent;
                  });
                },
                icon: Icon(Icons.home), // Use an appropriate icon for generating user-agent
                color: Theme.of(context).primaryColor,
                iconSize: 24, // Adjust the icon size as needed
              ),
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
          SwitchListTile(
            title: const Text('Incognito mode'),
            subtitle: const Text('No cookies or cache persist'),
            value: _incognito,
            onChanged: (bool value) {
              setState(() {
                _incognito = value;
              });
            },
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: ElevatedButton(
              onPressed: _saveSettings,
              child: Text('Save Settings'),
            ),
          ),
        ],
      ),
    );
  }
}

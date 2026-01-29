import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/platform/webview.dart';
import 'package:webspace/web_view_model.dart';

void main() {
  group('ProxySettings', () {
    test('UserProxySettings serialization and deserialization', () {
      // Test DEFAULT proxy
      final defaultProxy = UserProxySettings(type: ProxyType.DEFAULT);
      final defaultJson = defaultProxy.toJson();
      final defaultFromJson = UserProxySettings.fromJson(defaultJson);
      
      expect(defaultFromJson.type, ProxyType.DEFAULT);
      expect(defaultFromJson.address, null);
      
      // Test HTTP proxy with address
      final httpProxy = UserProxySettings(
        type: ProxyType.HTTP,
        address: 'proxy.example.com:8080',
      );
      final httpJson = httpProxy.toJson();
      final httpFromJson = UserProxySettings.fromJson(httpJson);
      
      expect(httpFromJson.type, ProxyType.HTTP);
      expect(httpFromJson.address, 'proxy.example.com:8080');
      
      // Test HTTPS proxy
      final httpsProxy = UserProxySettings(
        type: ProxyType.HTTPS,
        address: 'secure.proxy.com:443',
      );
      final httpsJson = httpsProxy.toJson();
      final httpsFromJson = UserProxySettings.fromJson(httpsJson);
      
      expect(httpsFromJson.type, ProxyType.HTTPS);
      expect(httpsFromJson.address, 'secure.proxy.com:443');
      
      // Test SOCKS5 proxy
      final socks5Proxy = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: 'socks.proxy.com:1080',
      );
      final socks5Json = socks5Proxy.toJson();
      final socks5FromJson = UserProxySettings.fromJson(socks5Json);
      
      expect(socks5FromJson.type, ProxyType.SOCKS5);
      expect(socks5FromJson.address, 'socks.proxy.com:1080');
    });

    test('ProxyType enum values', () {
      expect(ProxyType.values.length, 4);
      expect(ProxyType.values, contains(ProxyType.DEFAULT));
      expect(ProxyType.values, contains(ProxyType.HTTP));
      expect(ProxyType.values, contains(ProxyType.HTTPS));
      expect(ProxyType.values, contains(ProxyType.SOCKS5));
    });

    test('ProxyType index consistency', () {
      final proxy = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: 'test.com:1080',
      );
      final json = proxy.toJson();
      final index = json['type'] as int;
      
      expect(ProxyType.values[index], ProxyType.SOCKS5);
    });
  });

  group('ProxyManager', () {
    test('ProxyManager is singleton', () {
      final manager1 = ProxyManager();
      final manager2 = ProxyManager();
      
      expect(identical(manager1, manager2), true);
    });
  });

  group('WebViewModel with Proxy', () {
    test('WebViewModel initializes with default proxy', () {
      final viewModel = WebViewModel(
        initUrl: 'https://example.com',
      );
      
      expect(viewModel.proxySettings.type, ProxyType.DEFAULT);
      expect(viewModel.proxySettings.address, null);
    });

    test('WebViewModel initializes with custom proxy', () {
      final proxySettings = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: 'localhost:9050',
      );
      
      final viewModel = WebViewModel(
        initUrl: 'https://example.com',
        proxySettings: proxySettings,
      );
      
      expect(viewModel.proxySettings.type, ProxyType.SOCKS5);
      expect(viewModel.proxySettings.address, 'localhost:9050');
    });

    test('WebViewModel serialization includes proxy settings', () {
      final proxySettings = UserProxySettings(
        type: ProxyType.HTTP,
        address: 'proxy.test.com:3128',
      );
      
      final viewModel = WebViewModel(
        initUrl: 'https://example.com',
        proxySettings: proxySettings,
      );
      
      final json = viewModel.toJson();
      
      expect(json['proxySettings'], isNotNull);
      expect(json['proxySettings']['type'], ProxyType.HTTP.index);
      expect(json['proxySettings']['address'], 'proxy.test.com:3128');
    });

    test('WebViewModel deserialization restores proxy settings', () {
      final json = {
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com',
        'name': 'Example',
        'pageTitle': null,
        'cookies': [],
        'proxySettings': {
          'type': ProxyType.SOCKS5.index,
          'address': 'tor.proxy.com:9050',
        },
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
      };
      
      final viewModel = WebViewModel.fromJson(json, null);
      
      expect(viewModel.proxySettings.type, ProxyType.SOCKS5);
      expect(viewModel.proxySettings.address, 'tor.proxy.com:9050');
    });
  });

  group('Proxy Address Validation', () {
    test('Valid proxy addresses', () {
      final validAddresses = [
        'localhost:8080',
        'proxy.example.com:3128',
        '192.168.1.1:1080',
        'my-proxy.company.net:8888',
        'proxy:9050',
        '127.0.0.1:8080',
      ];
      
      for (final address in validAddresses) {
        final parts = address.split(':');
        expect(parts.length, 2, reason: 'Address should have host:port format: $address');
        
        final port = int.tryParse(parts[1]);
        expect(port, isNotNull, reason: 'Port should be numeric: $address');
        expect(port! >= 1 && port <= 65535, true, reason: 'Port should be valid: $address');
      }
    });

    test('Invalid proxy addresses', () {
      final invalidAddresses = [
        'proxy.example.com', // Missing port
        'proxy.example.com:abc', // Non-numeric port
        'proxy.example.com:0', // Invalid port (0)
        'proxy.example.com:70000', // Port out of range
        ':8080', // Missing host
        'proxy.example.com:8080:extra', // Too many colons
        '', // Empty
      ];
      
      for (final address in invalidAddresses) {
        final parts = address.split(':');
        
        bool isValid = parts.length == 2 && 
                      parts[0].isNotEmpty && 
                      parts[1].isNotEmpty;
        
        if (isValid) {
          final port = int.tryParse(parts[1]);
          isValid = port != null && port >= 1 && port <= 65535;
        }
        
        expect(isValid, false, reason: 'Address should be invalid: $address');
      }
    });
  });

  group('Proxy Type to Scheme Conversion', () {
    test('HTTP proxy scheme', () {
      final proxy = UserProxySettings(
        type: ProxyType.HTTP,
        address: 'proxy.com:8080',
      );
      
      // We expect HTTP to map to 'http' scheme
      expect(proxy.type, ProxyType.HTTP);
    });

    test('HTTPS proxy scheme', () {
      final proxy = UserProxySettings(
        type: ProxyType.HTTPS,
        address: 'proxy.com:443',
      );
      
      // We expect HTTPS to map to 'https' scheme
      expect(proxy.type, ProxyType.HTTPS);
    });

    test('SOCKS5 proxy scheme', () {
      final proxy = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: 'proxy.com:1080',
      );
      
      // We expect SOCKS5 to map to 'socks5' scheme
      expect(proxy.type, ProxyType.SOCKS5);
    });

    test('DEFAULT proxy has no scheme', () {
      final proxy = UserProxySettings(
        type: ProxyType.DEFAULT,
      );
      
      expect(proxy.type, ProxyType.DEFAULT);
      expect(proxy.address, null);
    });
  });

  group('Proxy Settings Edge Cases', () {
    test('Proxy with null address for DEFAULT type', () {
      final proxy = UserProxySettings(
        type: ProxyType.DEFAULT,
        address: null,
      );
      
      final json = proxy.toJson();
      final restored = UserProxySettings.fromJson(json);
      
      expect(restored.type, ProxyType.DEFAULT);
      expect(restored.address, null);
    });

    test('Proxy settings with empty address string', () {
      final proxy = UserProxySettings(
        type: ProxyType.HTTP,
        address: '',
      );
      
      expect(proxy.address, '');
      expect(proxy.address!.isEmpty, true);
    });

    test('Multiple proxy settings with same address', () {
      final address = 'shared.proxy.com:8080';
      
      final httpProxy = UserProxySettings(
        type: ProxyType.HTTP,
        address: address,
      );
      
      final socks5Proxy = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: address,
      );
      
      expect(httpProxy.address, socks5Proxy.address);
      expect(httpProxy.type, isNot(socks5Proxy.type));
    });
  });

  group('WebViewModel Proxy Update', () {
    test('Update proxy settings on existing WebViewModel', () {
      final viewModel = WebViewModel(
        initUrl: 'https://example.com',
      );
      
      expect(viewModel.proxySettings.type, ProxyType.DEFAULT);
      
      final newProxy = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: 'new.proxy.com:1080',
      );
      
      // Simulate updating proxy settings
      viewModel.proxySettings = newProxy;
      
      expect(viewModel.proxySettings.type, ProxyType.SOCKS5);
      expect(viewModel.proxySettings.address, 'new.proxy.com:1080');
    });

    test('Proxy settings persist through serialization', () {
      final originalProxy = UserProxySettings(
        type: ProxyType.HTTP,
        address: 'test.proxy.com:8080',
      );
      
      final viewModel = WebViewModel(
        initUrl: 'https://example.com',
        proxySettings: originalProxy,
      );
      
      // Serialize
      final json = viewModel.toJson();
      
      // Deserialize
      final restored = WebViewModel.fromJson(json, null);
      
      expect(restored.proxySettings.type, originalProxy.type);
      expect(restored.proxySettings.address, originalProxy.address);
    });
  });

  group('Common Proxy Configurations', () {
    test('Tor SOCKS5 proxy configuration', () {
      final torProxy = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: 'localhost:9050',
      );
      
      expect(torProxy.type, ProxyType.SOCKS5);
      expect(torProxy.address, 'localhost:9050');
      
      final parts = torProxy.address!.split(':');
      expect(parts[0], 'localhost');
      expect(parts[1], '9050');
    });

    test('Corporate HTTP proxy configuration', () {
      final corpProxy = UserProxySettings(
        type: ProxyType.HTTP,
        address: 'proxy.company.com:8080',
      );
      
      expect(corpProxy.type, ProxyType.HTTP);
      expect(corpProxy.address, 'proxy.company.com:8080');
    });

    test('SSH tunnel SOCKS5 proxy configuration', () {
      final sshProxy = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '127.0.0.1:1080',
      );
      
      expect(sshProxy.type, ProxyType.SOCKS5);
      expect(sshProxy.address, '127.0.0.1:1080');
    });

    test('System default proxy configuration', () {
      final systemProxy = UserProxySettings(
        type: ProxyType.DEFAULT,
      );

      expect(systemProxy.type, ProxyType.DEFAULT);
      expect(systemProxy.address, null);
    });
  });

  group('Proxy Credentials', () {
    test('UserProxySettings with username and password', () {
      final proxy = UserProxySettings(
        type: ProxyType.HTTP,
        address: 'proxy.example.com:8080',
        username: 'myuser',
        password: 'mypassword',
      );

      expect(proxy.type, ProxyType.HTTP);
      expect(proxy.address, 'proxy.example.com:8080');
      expect(proxy.username, 'myuser');
      expect(proxy.password, 'mypassword');
      expect(proxy.hasCredentials, true);
    });

    test('hasCredentials returns false when username is null', () {
      final proxy = UserProxySettings(
        type: ProxyType.HTTP,
        address: 'proxy.example.com:8080',
        username: null,
        password: 'mypassword',
      );

      expect(proxy.hasCredentials, false);
    });

    test('hasCredentials returns false when password is null', () {
      final proxy = UserProxySettings(
        type: ProxyType.HTTP,
        address: 'proxy.example.com:8080',
        username: 'myuser',
        password: null,
      );

      expect(proxy.hasCredentials, false);
    });

    test('hasCredentials returns false when username is empty', () {
      final proxy = UserProxySettings(
        type: ProxyType.HTTP,
        address: 'proxy.example.com:8080',
        username: '',
        password: 'mypassword',
      );

      expect(proxy.hasCredentials, false);
    });

    test('hasCredentials returns false when password is empty', () {
      final proxy = UserProxySettings(
        type: ProxyType.HTTP,
        address: 'proxy.example.com:8080',
        username: 'myuser',
        password: '',
      );

      expect(proxy.hasCredentials, false);
    });

    test('hasCredentials returns false for DEFAULT proxy without credentials', () {
      final proxy = UserProxySettings(
        type: ProxyType.DEFAULT,
      );

      expect(proxy.hasCredentials, false);
    });

    test('Credentials serialize and deserialize correctly', () {
      final proxy = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: 'socks.example.com:1080',
        username: 'testuser',
        password: 'testpass123',
      );

      final json = proxy.toJson();
      expect(json['username'], 'testuser');
      expect(json['password'], 'testpass123');

      final restored = UserProxySettings.fromJson(json);
      expect(restored.username, 'testuser');
      expect(restored.password, 'testpass123');
      expect(restored.hasCredentials, true);
    });

    test('Null credentials deserialize correctly', () {
      final json = {
        'type': ProxyType.HTTP.index,
        'address': 'proxy.example.com:8080',
        'username': null,
        'password': null,
      };

      final proxy = UserProxySettings.fromJson(json);
      expect(proxy.username, null);
      expect(proxy.password, null);
      expect(proxy.hasCredentials, false);
    });

    test('Missing credentials in JSON deserialize as null', () {
      final json = {
        'type': ProxyType.HTTP.index,
        'address': 'proxy.example.com:8080',
      };

      final proxy = UserProxySettings.fromJson(json);
      expect(proxy.username, null);
      expect(proxy.password, null);
      expect(proxy.hasCredentials, false);
    });

    test('WebViewModel serializes proxy credentials', () {
      final proxySettings = UserProxySettings(
        type: ProxyType.HTTP,
        address: 'proxy.corp.com:3128',
        username: 'corpuser',
        password: 'corppass',
      );

      final viewModel = WebViewModel(
        initUrl: 'https://example.com',
        proxySettings: proxySettings,
      );

      final json = viewModel.toJson();
      expect(json['proxySettings']['username'], 'corpuser');
      expect(json['proxySettings']['password'], 'corppass');
    });

    test('WebViewModel deserializes proxy credentials', () {
      final json = {
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com',
        'name': 'Example',
        'pageTitle': null,
        'cookies': [],
        'proxySettings': {
          'type': ProxyType.HTTP.index,
          'address': 'proxy.corp.com:3128',
          'username': 'corpuser',
          'password': 'corppass',
        },
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
      };

      final viewModel = WebViewModel.fromJson(json, null);
      expect(viewModel.proxySettings.username, 'corpuser');
      expect(viewModel.proxySettings.password, 'corppass');
      expect(viewModel.proxySettings.hasCredentials, true);
    });

    test('Proxy with special characters in credentials', () {
      final proxy = UserProxySettings(
        type: ProxyType.HTTP,
        address: 'proxy.example.com:8080',
        username: 'user@domain.com',
        password: 'p@ss:word/123',
      );

      final json = proxy.toJson();
      final restored = UserProxySettings.fromJson(json);

      expect(restored.username, 'user@domain.com');
      expect(restored.password, 'p@ss:word/123');
      expect(restored.hasCredentials, true);
    });
  });
}

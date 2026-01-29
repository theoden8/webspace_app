import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/webview.dart';

void main() {
  group('Proxy Integration Tests', () {
    test('Complete workflow: Create WebViewModel with SOCKS5 proxy', () {
      // Step 1: Create a SOCKS5 proxy configuration (like Tor)
      final torProxy = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: 'localhost:9050',
      );

      // Step 2: Create a WebViewModel with this proxy
      final viewModel = WebViewModel(
        initUrl: 'https://check.torproject.org',
        proxySettings: torProxy,
        javascriptEnabled: true,
        userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      );

      // Step 3: Verify the proxy settings are applied
      expect(viewModel.proxySettings.type, ProxyType.SOCKS5);
      expect(viewModel.proxySettings.address, 'localhost:9050');
      expect(viewModel.initUrl, 'https://check.torproject.org');
    });

    test('Workflow: Update proxy settings from HTTP to SOCKS5', () {
      // Start with HTTP proxy
      final httpProxy = UserProxySettings(
        type: ProxyType.HTTP,
        address: 'proxy.company.com:8080',
      );

      final viewModel = WebViewModel(
        initUrl: 'https://example.com',
        proxySettings: httpProxy,
      );

      expect(viewModel.proxySettings.type, ProxyType.HTTP);

      // User changes to SOCKS5 in settings
      final socks5Proxy = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: 'localhost:1080',
      );

      viewModel.proxySettings = socks5Proxy;

      expect(viewModel.proxySettings.type, ProxyType.SOCKS5);
      expect(viewModel.proxySettings.address, 'localhost:1080');
    });

    test('Workflow: Disable proxy (change to DEFAULT)', () {
      // Start with a proxy
      final socks5Proxy = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: 'localhost:9050',
      );

      final viewModel = WebViewModel(
        initUrl: 'https://example.com',
        proxySettings: socks5Proxy,
      );

      expect(viewModel.proxySettings.type, ProxyType.SOCKS5);

      // User disables proxy
      final defaultProxy = UserProxySettings(
        type: ProxyType.DEFAULT,
      );

      viewModel.proxySettings = defaultProxy;

      expect(viewModel.proxySettings.type, ProxyType.DEFAULT);
      expect(viewModel.proxySettings.address, null);
    });

    test('Workflow: Persist and restore proxy settings', () {
      // User configures SOCKS5 proxy
      final originalProxy = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '192.168.1.100:1080',
      );

      final viewModel = WebViewModel(
        initUrl: 'https://example.com',
        name: 'My Site',
        proxySettings: originalProxy,
        javascriptEnabled: false,
        userAgent: 'CustomAgent/1.0',
      );

      // Serialize (save to disk)
      final savedJson = viewModel.toJson();

      // Simulate app restart - deserialize (load from disk)
      final restoredViewModel = WebViewModel.fromJson(savedJson, null);

      // Verify all settings including proxy are restored
      expect(restoredViewModel.initUrl, viewModel.initUrl);
      expect(restoredViewModel.name, viewModel.name);
      expect(restoredViewModel.proxySettings.type, ProxyType.SOCKS5);
      expect(restoredViewModel.proxySettings.address, '192.168.1.100:1080');
      expect(restoredViewModel.javascriptEnabled, false);
      expect(restoredViewModel.userAgent, 'CustomAgent/1.0');
    });

    test('Workflow: Multiple sites with different proxy configurations', () {
      // Site 1: Uses Tor
      final site1 = WebViewModel(
        initUrl: 'https://onion-site.onion',
        proxySettings: UserProxySettings(
          type: ProxyType.SOCKS5,
          address: 'localhost:9050',
        ),
      );

      // Site 2: Uses corporate proxy
      final site2 = WebViewModel(
        initUrl: 'https://corporate-intranet.com',
        proxySettings: UserProxySettings(
          type: ProxyType.HTTP,
          address: 'proxy.company.com:8080',
        ),
      );

      // Site 3: No proxy (direct connection)
      final site3 = WebViewModel(
        initUrl: 'https://public-site.com',
        proxySettings: UserProxySettings(
          type: ProxyType.DEFAULT,
        ),
      );

      // Verify each site has independent proxy settings
      expect(site1.proxySettings.type, ProxyType.SOCKS5);
      expect(site1.proxySettings.address, 'localhost:9050');

      expect(site2.proxySettings.type, ProxyType.HTTP);
      expect(site2.proxySettings.address, 'proxy.company.com:8080');

      expect(site3.proxySettings.type, ProxyType.DEFAULT);
      expect(site3.proxySettings.address, null);
    });

    test('Workflow: Error handling for invalid proxy address', () {
      // Test that invalid addresses can be detected
      final invalidAddresses = [
        'no-port',
        'invalid:abc',
        ':8080',
        'host:0',
        'host:99999',
        '',
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

        expect(isValid, false, 
          reason: 'Address "$address" should be detected as invalid');
      }
    });

    test('Real-world: Configure SSH tunnel proxy', () {
      // User sets up SSH tunnel: ssh -D 1080 user@remote-server
      // Then configures app to use it
      final sshTunnelProxy = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '127.0.0.1:1080',
      );

      final viewModel = WebViewModel(
        initUrl: 'https://restricted-site.com',
        proxySettings: sshTunnelProxy,
      );

      expect(viewModel.proxySettings.type, ProxyType.SOCKS5);
      expect(viewModel.proxySettings.address, '127.0.0.1:1080');

      // Serialize and verify it can be restored
      final json = viewModel.toJson();
      final restored = WebViewModel.fromJson(json, null);

      expect(restored.proxySettings.type, ProxyType.SOCKS5);
      expect(restored.proxySettings.address, '127.0.0.1:1080');
    });

    test('Real-world: Switch from corporate proxy to VPN', () {
      // Initially using corporate HTTP proxy
      final viewModel = WebViewModel(
        initUrl: 'https://example.com',
        proxySettings: UserProxySettings(
          type: ProxyType.HTTP,
          address: 'proxy.corp.com:8080',
        ),
      );

      expect(viewModel.proxySettings.type, ProxyType.HTTP);

      // User connects to VPN, no longer needs proxy
      viewModel.proxySettings = UserProxySettings(
        type: ProxyType.DEFAULT,
      );

      expect(viewModel.proxySettings.type, ProxyType.DEFAULT);
      expect(viewModel.proxySettings.address, null);
    });

    test('ProxyManager singleton behavior', () {
      // Verify that we always get the same instance
      final manager1 = ProxyManager();
      final manager2 = ProxyManager();
      final manager3 = ProxyManager();

      expect(identical(manager1, manager2), true);
      expect(identical(manager2, manager3), true);
      expect(identical(manager1, manager3), true);
    });

    test('Proxy settings with different protocols for same server', () {
      // Some servers support multiple protocols
      final server = 'multiproto.proxy.com:8080';

      final httpProxy = UserProxySettings(
        type: ProxyType.HTTP,
        address: server,
      );

      final httpsProxy = UserProxySettings(
        type: ProxyType.HTTPS,
        address: server,
      );

      // Both should be valid but use different protocols
      expect(httpProxy.address, httpsProxy.address);
      expect(httpProxy.type, isNot(httpsProxy.type));
    });
  });

  group('Proxy Validation Scenarios', () {
    test('Valid proxy configurations', () {
      final validConfigs = [
        {'type': ProxyType.HTTP, 'address': 'proxy.example.com:8080'},
        {'type': ProxyType.HTTPS, 'address': 'secure.proxy.com:443'},
        {'type': ProxyType.SOCKS5, 'address': 'localhost:9050'},
        {'type': ProxyType.SOCKS5, 'address': '127.0.0.1:1080'},
        {'type': ProxyType.HTTP, 'address': '192.168.1.1:3128'},
        {'type': ProxyType.DEFAULT, 'address': null},
      ];

      for (final config in validConfigs) {
        final proxy = UserProxySettings(
          type: config['type'] as ProxyType,
          address: config['address'] as String?,
        );

        if (proxy.type != ProxyType.DEFAULT) {
          expect(proxy.address, isNotNull);
          final parts = proxy.address!.split(':');
          expect(parts.length, 2);
          final port = int.tryParse(parts[1]);
          expect(port, isNotNull);
          expect(port! >= 1 && port <= 65535, true);
        }
      }
    });

    test('Standard proxy ports', () {
      final standardPorts = {
        ProxyType.HTTP: [8080, 3128, 8888],
        ProxyType.HTTPS: [443, 8443],
        ProxyType.SOCKS5: [1080, 9050],
      };

      for (final entry in standardPorts.entries) {
        for (final port in entry.value) {
          final proxy = UserProxySettings(
            type: entry.key,
            address: 'proxy.example.com:$port',
          );

          expect(proxy.type, entry.key);
          expect(proxy.address, 'proxy.example.com:$port');
        }
      }
    });
  });
}

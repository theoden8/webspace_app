# Proxy Configuration Guide

## Quick Start

The webspace app now supports HTTP, HTTPS, and SOCKS5 proxy configurations for Android devices. Each website can have its own independent proxy settings.

## How to Configure a Proxy

1. Open a website in the app
2. Tap the **Settings** icon (⚙️) for that site
3. In the **Proxy Type** dropdown, select your desired proxy type:
   - **DEFAULT** - Use system proxy (no override)
   - **HTTP** - Standard HTTP proxy
   - **HTTPS** - Secure HTTPS proxy
   - **SOCKS5** - SOCKS5 proxy (for Tor, SSH tunnels, etc.)
4. If you selected a proxy type other than DEFAULT, enter the **Proxy Address** in the format: `host:port`
   - Example: `proxy.example.com:8080`
   - Example: `localhost:9050` (for Tor)
5. Tap **Save Settings**

## Common Use Cases

### Use Case 1: Tor Browser

To route traffic through Tor:

1. Install and start Tor on your device (default port: 9050)
2. In app settings, select **SOCKS5**
3. Enter: `localhost:9050`
4. Save settings

### Use Case 2: Corporate Proxy

For corporate networks:

1. Get your proxy details from IT (e.g., `proxy.company.com:8080`)
2. In app settings, select **HTTP** or **HTTPS**
3. Enter your proxy address
4. Save settings

### Use Case 3: SSH Tunnel

To use an SSH tunnel as a proxy:

1. Set up SSH tunnel: `ssh -D 1080 user@remote-server`
2. In app settings, select **SOCKS5**
3. Enter: `127.0.0.1:1080`
4. Save settings

### Use Case 4: Different Proxies per Site

You can configure different proxies for different sites:

- Site A: Tor (SOCKS5 → `localhost:9050`)
- Site B: Corporate proxy (HTTP → `proxy.company.com:8080`)
- Site C: Direct connection (DEFAULT)

Each site maintains its own proxy configuration independently.

## Troubleshooting

### Error: "Proxy address is required"
You selected a proxy type but didn't provide an address. Either enter an address or select DEFAULT.

### Error: "Format: host:port"
The proxy address must include both hostname and port separated by a colon.
- ✅ Correct: `proxy.example.com:8080`
- ❌ Wrong: `proxy.example.com`

### Error: "Invalid port number"
Port must be between 1 and 65535.
- ✅ Correct: `1080`, `8080`, `443`
- ❌ Wrong: `0`, `99999`, `abc`

### Connection Issues

If the website won't load after configuring a proxy:

1. **Verify proxy is running**: Test with `telnet proxy.example.com 8080`
2. **Check address and port**: Ensure they're correct
3. **Try DEFAULT**: Temporarily switch to DEFAULT to confirm the proxy is the issue
4. **Check proxy type**: Some proxies only support specific protocols

## Proxy Address Format

```
host:port
```

Where:
- **host** can be:
  - Domain name: `proxy.example.com`
  - IP address: `192.168.1.100`
  - Localhost: `localhost` or `127.0.0.1`
- **port** must be:
  - A number between 1 and 65535
  - Common ports: 8080 (HTTP), 443 (HTTPS), 1080 (SOCKS5), 9050 (Tor)

## Examples

| Use Case | Type | Address |
|----------|------|---------|
| Tor Browser | SOCKS5 | `localhost:9050` |
| Corporate HTTP Proxy | HTTP | `proxy.company.com:8080` |
| Secure Corporate Proxy | HTTPS | `proxy.company.com:443` |
| SSH Tunnel | SOCKS5 | `127.0.0.1:1080` |
| Local Test Proxy | HTTP | `127.0.0.1:8888` |
| Remote SOCKS Proxy | SOCKS5 | `proxy.vpn.com:1080` |
| No Proxy | DEFAULT | (no address needed) |

## Security Notes

- Proxy settings are saved per site and persist across app restarts
- Currently, authenticated proxies (requiring username/password) are not supported
- Use HTTPS proxies for sensitive traffic when possible
- For maximum privacy, consider using SOCKS5 with Tor

## Platform Support

- ✅ **Android**: Full proxy support via ProxyController
- ✅ **iOS**: Full proxy support via ProxyController  
- ❌ **Linux**: Limited support (webview_cef doesn't support proxies)
- ❌ **Desktop**: Platform-dependent support

## Need Help?

If you encounter issues:

1. Check the error message in the snackbar notification
2. Verify your proxy server is running and accessible
3. Test the proxy with another application first
4. Try switching to DEFAULT temporarily to isolate the issue
5. Check the app logs for detailed error messages

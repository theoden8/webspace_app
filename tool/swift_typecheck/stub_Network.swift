// Stand-in for the Network framework symbols the proxy probe uses.
//
// Transcribed from the SDK's Network module interface: NWEndpoint's nested
// Host/Port, IPv4Address's failable string init, and the ProxyConfiguration
// SOCKSv5 initializer (macOS 14+). A stub written from memory would pass
// exactly the argument-label mistakes this exists to catch.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct IPv4Address {
  public init?(_ string: String) { return nil }
}

public struct IPv6Address {
  public init?(_ string: String) { return nil }
}

public enum NWEndpoint {
  public enum Host {
    case ipv4(IPv4Address)
    case ipv6(IPv6Address)
    case name(String, Int?)
    public init(_ string: String) { self = .name(string, nil) }
  }

  public struct Port {
    public init?(rawValue: UInt16) { return nil }
  }

  case hostPort(host: Host, port: Port)
}

// Mirrors the real Network framework surface, which is why `applyCredential`
// is non-mutating: Apple's own sample calls it on a `let` binding
// (developer.apple.com/forums/thread/734679). That method is reported broken
// in WebKit by DTS (FB13350370, r.113346270); the stub exists to type-check
// the call, not to promise it works.
public struct ProxyConfiguration {
  public init(socksv5Proxy: NWEndpoint) {}
  public init(httpCONNECTProxy: NWEndpoint, tlsOptions: Int?) {}
  public func applyCredential(username: String, password: String) {}
}

// `URLSessionConfiguration.proxyConfigurations` is Apple-only: Foundation
// declares it, but swift-corelibs-foundation does not, so type-checking the
// probe on Linux rejects a call the SDK accepts. Declared here rather than
// dropped from the gate, so a wrong element type or a misspelled member in
// ProxyProbePlugin.swift is still an error.
//
// Transcribed from developer.apple.com/documentation/foundation/
// urlsessionconfiguration/proxyconfigurations:
//   var proxyConfigurations: [ProxyConfiguration] { get set }
// iOS 17.0 / macOS 14.0. No `@available` here: Linux ignores Apple platform
// availability, so it would gate nothing.
extension URLSessionConfiguration {
  public var proxyConfigurations: [ProxyConfiguration] {
    get { return [] }
    set { _ = newValue }
  }
}

// Stand-in for the Network framework symbols the proxy probe uses.
//
// Transcribed from the SDK's Network module interface: NWEndpoint's nested
// Host/Port, IPv4Address's failable string init, and the ProxyConfiguration
// SOCKSv5 initializer (macOS 14+). A stub written from memory would pass
// exactly the argument-label mistakes this exists to catch.

import Foundation

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

public struct ProxyConfiguration {
  public init(socksv5Proxy: NWEndpoint) {}
  public init(httpCONNECTProxy: NWEndpoint, tlsOptions: Int?) {}
}

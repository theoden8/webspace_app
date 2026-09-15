// Stand-in for the IPtProxy module that ios/Runner/TorControllerPlugin.swift imports,
// so its Swift can be type-checked on a machine with no Xcode.
//
// Every signature here is transcribed from the real header of the pinned
// version, named above it. That is the point: a stub invented from memory
// would pass exactly the mistakes this is meant to catch. When a pod moves,
// re-read the header rather than adjusting a stub until the check goes
// quiet.
//
// This is not a build. It cannot see anything the type checker does not,
// and it cannot run a line of the plugin.

import Foundation

// MARK: - IPtProxy 5.5.1 (IPtProxyController, gomobile-generated)

public class IPtProxyController: NSObject {
  public init?(_ stateDir: String, enableLogging: Bool, unsafeLogging: Bool,
               logLevel: String, transportEvents: Any?) {}
  public func start(_ transport: String, proxy: String?) throws {}
  public func stop(_ transport: String) {}
  public func port(_ transport: String) -> Int { 0 }
}

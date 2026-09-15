// Stand-in for the Tor module that ios/Runner/TorControllerPlugin.swift imports,
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
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Tor 409.11.2 (TORConfiguration.h, TORController.h, TORThread.h)

public typealias TORObserverBlock =
  ([NSNumber], [Data], UnsafeMutablePointer<ObjCBool>) -> Bool

public class TorConfiguration: NSObject {
  public var dataDirectory: URL?
  public var cacheDirectory: URL?
  public var logfile: URL?
  public var controlSocket: URL?
  public var socksURL: URL?
  public var geoipFile: URL?
  public var geoip6File: URL?
  public var ignoreMissingTorrc: Bool = false
  public var cookieAuthentication: Bool = false
  public var autoControlPort: Bool = false
  public var avoidDiskWrites: Bool = false
  public var clientOnly: Bool = false
  public var options: NSMutableDictionary?
  public var arguments: NSMutableArray?
  public var controlPortFile: URL? { nil }
  public var cookie: Data? { nil }
  public var isLocked: Bool { false }
}

// TORThread really subclasses NSThread. Linux's Foundation ships Thread with
// overridable members a Swift 5 language-mode module cannot inherit, so the
// stub restates the three members the plugin uses instead of the superclass.
public class TorThread: NSObject {
  public init(configuration: TorConfiguration?) {}
  public init(arguments: [String]?) {}

  public func start() {}
  public func cancel() {}
  public var isExecuting: Bool { false }
  public var isFinished: Bool { false }
}

public class TorController: NSObject {
  // Each of these connects inside the initializer ([self connect:nil]), and
  // `connect()` on a connected controller returns NO without writing an
  // error. The type checker cannot see either fact; it is recorded here
  // because a stub read as a header is where the wrong assumption started.
  public init(socketURL url: URL) {}
  public init(socketHost host: String, port: UInt16) {}
  public init(controlPortFile file: URL) {}

  public var events: NSOrderedSet { NSOrderedSet() }
  public var isConnected: Bool { false }

  public func connect() throws {}
  public func disconnect() {}

  public func authenticate(
    with data: Data, completion: ((Bool, Error?) -> Void)?
  ) {}
  public func resetConf(forKey key: String, completion: ((Bool, Error?) -> Void)?) {}
  public func setConf(forKey key: String, withValue value: String,
                      completion: ((Bool, Error?) -> Void)?) {}
  public func setConfs(_ configs: [[String: String]], completion: ((Bool, Error?) -> Void)?) {}
  public func listen(forEvents events: [String], completion: ((Bool, Error?) -> Void)?) {}
  public func info(forKeys keys: [String]) async -> [String] { [] }
  public func getSessionConfiguration(_ completion: @escaping (URLSessionConfiguration?) -> Void) {}
  public func sendCommand(_ command: String, arguments: [String]?, data: Data?,
                          observer: @escaping TORObserverBlock) {}
  public func resetConnection(_ completion: ((Bool) -> Void)?) {}

  public func addObserver(forCircuitEstablished block: @escaping (Bool) -> Void) -> Any {
    NSObject()
  }
  public func addObserver(
    forStatusEvents block: @escaping (String, String, String, [String: String]?) -> Bool
  ) -> Any {
    NSObject()
  }
  public func removeObserver(_ observer: Any?) {}
}


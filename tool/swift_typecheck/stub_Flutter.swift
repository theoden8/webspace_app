// Stand-in for the Flutter module that ios/Runner/TorControllerPlugin.swift imports,
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

// MARK: - Flutter (FlutterMethodChannel.h, FlutterEventChannel.h, FlutterCodecs.h)

public typealias FlutterResult = (Any?) -> Void
public typealias FlutterEventSink = (Any?) -> Void

public let FlutterMethodNotImplemented: Any? = nil

public protocol FlutterBinaryMessenger: AnyObject {}

public class FlutterError: NSObject {
  public init(code: String, message: String?, details: Any?) {}
}

public class FlutterMethodCall: NSObject {
  public var method: String = ""
  public var arguments: Any?
}

public class FlutterMethodChannel: NSObject {
  public init(name: String, binaryMessenger: FlutterBinaryMessenger) {}
  public func setMethodCallHandler(
    _ handler: ((FlutterMethodCall, @escaping FlutterResult) -> Void)?
  ) {}
}

public protocol FlutterStreamHandler: AnyObject {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  func onCancel(withArguments arguments: Any?) -> FlutterError?
}

public class FlutterEventChannel: NSObject {
  public init(name: String, binaryMessenger: FlutterBinaryMessenger) {}
  public func setStreamHandler(_ handler: FlutterStreamHandler?) {}
}


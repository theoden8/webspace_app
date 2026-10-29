// Stand-in for ScreenCaptureKit (macOS 14), as much as
// macos/Runner/ScreenSharePlugin.swift touches, so it type-checks on Linux.
//
// Shapes from SCContentSharingPicker.h, SCStream.h and SCShareableContent.h:
// the selectors as WebRTC calls them (modules/desktop_capture/mac/
// screen_capturer_sck.mm, sck_picker_handle.mm) and the Swift names Apple's
// "Capturing screen content in macOS" sample uses, and the Swift-facing
// shapes from the SDK's ScreenCaptureKit.swiftinterface where a header is
// NS_REFINED_FOR_SWIFT: the picker configuration is a struct and
// maximumStreamCount an Int?. `active` is declared with getter=isActive, so
// Swift reads `isActive`. Availability is not modelled. See
// stub_FlutterMacOS.swift for what a stub can and cannot catch.

import CoreMedia
import CoreVideo
import Foundation

public struct SCContentSharingPickerMode: OptionSet {
  public let rawValue: UInt
  public init(rawValue: UInt) { self.rawValue = rawValue }
  public static let singleWindow = SCContentSharingPickerMode(rawValue: 1 << 0)
  public static let multipleWindows = SCContentSharingPickerMode(rawValue: 1 << 1)
  public static let singleApplication = SCContentSharingPickerMode(rawValue: 1 << 2)
  public static let multipleApplications = SCContentSharingPickerMode(rawValue: 1 << 3)
  public static let singleDisplay = SCContentSharingPickerMode(rawValue: 1 << 4)
}

public struct SCContentSharingPickerConfiguration {
  public var allowedPickerModes: SCContentSharingPickerMode = []
  public var excludedWindowIDs: [Int] = []
  public var excludedBundleIDs: [String] = []
  public var allowsChangingSelectedContent: Bool = true
  public init() {}
}

public class SCContentFilter: NSObject {
  public var contentRect: CGRect { .zero }
  public var pointPixelScale: Float { 1 }
}

public class SCStreamConfiguration: NSObject {
  public var width: Int = 0
  public var height: Int = 0
  public var minimumFrameInterval = CMTime(value: 0, timescale: 0)
  public var pixelFormat: OSType = 0
  public var showsCursor: Bool = true
  public var capturesAudio: Bool = false
  public var queueDepth: Int = 3
}

public enum SCStreamOutputType: Int {
  case screen, audio, microphone
}

public enum SCFrameStatus: Int {
  case complete, idle, blank, suspended, started, stopped
}

// typedef NSString *SCStreamFrameInfo NS_TYPED_ENUM; SCStreamFrameInfoStatus
// imports as SCStreamFrameInfo.status.
public struct SCStreamFrameInfo: Hashable, RawRepresentable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public static let status = SCStreamFrameInfo(rawValue: "SCStreamUpdateFrameStatus")
}

public protocol SCStreamOutput: NSObjectProtocol {
  // - (void)stream:(SCStream*)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
  //     ofType:(SCStreamOutputType)type;
  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType)
}

public protocol SCStreamDelegate: NSObjectProtocol {
  // - (void)stream:(SCStream*)stream didStopWithError:(NSError*)error;
  func stream(_ stream: SCStream, didStopWithError error: Error)
}

public class SCStream: NSObject {
  // - (instancetype)initWithFilter:configuration:delegate:
  public init(
    filter: SCContentFilter, configuration: SCStreamConfiguration,
    delegate: SCStreamDelegate?
  ) {}
  // - (BOOL)addStreamOutput:type:sampleHandlerQueue:error:
  public func addStreamOutput(
    _ output: SCStreamOutput, type: SCStreamOutputType, sampleHandlerQueue: DispatchQueue?
  ) throws {}
  // - (BOOL)removeStreamOutput:type:error:
  public func removeStreamOutput(_ output: SCStreamOutput, type: SCStreamOutputType) throws {}
  // - (void)startCaptureWithCompletionHandler:
  public func startCapture(completionHandler: (@Sendable (Error?) -> Void)? = nil) {}
  // - (void)stopCaptureWithCompletionHandler:
  public func stopCapture(completionHandler: (@Sendable (Error?) -> Void)? = nil) {}
}

public protocol SCContentSharingPickerObserver: NSObjectProtocol {
  // - (void)contentSharingPicker:(SCContentSharingPicker*)picker didCancelForStream:(SCStream*)stream;
  func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?)
  // - (void)contentSharingPicker:didUpdateWithFilter:forStream:
  func contentSharingPicker(
    _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?)
  // - (void)contentSharingPickerStartDidFailWithError:(NSError*)error;
  func contentSharingPickerStartDidFailWithError(_ error: Error)
}

public class SCContentSharingPicker: NSObject {
  // + (instancetype)sharedPicker; - (instancetype)init NS_UNAVAILABLE.
  public static let shared = SCContentSharingPicker()
  private override init() {}
  public var defaultConfiguration = SCContentSharingPickerConfiguration()
  public var maximumStreamCount: Int?
  public var isActive: Bool = false
  public func add(_ observer: SCContentSharingPickerObserver) {}
  public func remove(_ observer: SCContentSharingPickerObserver) {}
  public func present() {}
}

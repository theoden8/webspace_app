import CoreImage
import CoreMedia
import CoreVideo
import FlutterMacOS
import Foundation
import ImageIO
import ScreenCaptureKit

/// The `screen_share` channel on macOS (SHARE-018): the same calls as
/// Android's `ScreenSharePlugin.kt` (`start`, `frame`, `stop`, and `ended`
/// back to Dart), served from ScreenCaptureKit.
///
/// Every share starts from the system's own content picker
/// (`SCContentSharingPicker`, macOS 14), which also means the app needs no
/// Screen Recording permission: the user's pick is the grant, and only for
/// what they picked. Below macOS 14 every start answers nil, which the page
/// reads as a dismissed picker; Dart does not offer the mode there anyway.
enum ScreenSharePlugin {
  private static var sharing: AnyObject?

  static func attach(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "org.codeberg.theoden8.webspace/screen_share",
      binaryMessenger: messenger
    )
    if #available(macOS 14.0, *) {
      let picked = PickedScreenShare(channel: channel)
      sharing = picked
      channel.setMethodCallHandler { call, result in picked.handle(call, result: result) }
    } else {
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "start", "stop": result(nil)
        case "frame": result(["ended": true])
        default: result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}

/// One share at a time, and everything about it, read and written on the
/// main queue only: the channel's calls arrive there, and the picker's, the
/// stream's and the encoder's callbacks hop there before touching it
/// (BUG-007: none-shared).
@available(macOS 14.0, *)
private final class PickedScreenShare: NSObject, SCContentSharingPickerObserver,
  SCStreamDelegate
{
  private struct Request {
    let maxWidth: Int
    let maxHeight: Int
    let maxLongSide: Int
    let fps: Int
  }

  /// A start waiting on the picker. Only the first pick answers it, and a
  /// stream started for one start never answers another.
  private struct Pending {
    let request: Request
    let result: FlutterResult
    let token: Int
    var picked = false
  }

  private struct Waiting {
    let after: Int
    let result: FlutterResult
    let token: Int
  }

  private static let pullWait: DispatchTimeInterval = .milliseconds(1500)

  private let channel: FlutterMethodChannel
  private let picker = SCContentSharingPicker.shared
  private var observing = false

  private var pending: Pending?
  private var pendingTokens = 0
  private var live: Capture?
  private var latest: (seq: Int, jpeg: Data)?
  private var waiting: Waiting?
  private var waitTokens = 0

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      start(
        Request(
          maxWidth: args["maxWidth"] as? Int ?? 0,
          maxHeight: args["maxHeight"] as? Int ?? 0,
          maxLongSide: args["maxLongSide"] as? Int ?? 1280,
          fps: min(max(args["fps"] as? Int ?? 10, 1), 30)
        ),
        result: result
      )
    case "frame":
      frame(after: args["after"] as? Int ?? 0, result: result)
    case "stop":
      answerStart(nil)
      end(notify: false)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Starting

  private func start(_ request: Request, result: @escaping FlutterResult) {
    if pending != nil {
      result(nil)
      return
    }
    end(notify: false)
    pendingTokens += 1
    pending = Pending(request: request, result: result, token: pendingTokens)
    if !observing {
      picker.add(self)
      observing = true
    }
    var configuration = SCContentSharingPickerConfiguration()
    configuration.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
    configuration.allowsChangingSelectedContent = false
    picker.defaultConfiguration = configuration
    // No maximumStreamCount: the picker presents nothing while that many
    // streams still run, and a stopped one may not have finished stopping.
    // One share at a time is this class's own rule.
    picker.isActive = true
    picker.present()
  }

  func contentSharingPicker(
    _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?
  ) {
    DispatchQueue.main.async { self.picked(filter) }
  }

  func contentSharingPicker(
    _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
  ) {
    DispatchQueue.main.async { self.answerStart(nil) }
  }

  func contentSharingPickerStartDidFailWithError(_ error: Error) {
    DispatchQueue.main.async { self.answerStart(nil) }
  }

  private func picked(_ filter: SCContentFilter) {
    guard var waiting = pending, !waiting.picked else { return }
    waiting.picked = true
    pending = waiting
    let request = waiting.request
    let token = waiting.token
    let scale = CGFloat(filter.pointPixelScale)
    let size = Self.fit(
      width: Int(filter.contentRect.width * scale),
      height: Int(filter.contentRect.height * scale),
      request: request
    )
    let configuration = SCStreamConfiguration()
    configuration.width = size.width
    configuration.height = size.height
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(request.fps))
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = true
    configuration.capturesAudio = false
    configuration.queueDepth = 3

    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    let capture = Capture(stream: stream) { [weak self] capture, seq, jpeg in
      DispatchQueue.main.async { self?.offer(seq: seq, jpeg: jpeg, from: capture) }
    }
    do {
      try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
    } catch {
      answerStart(nil)
      return
    }
    stream.startCapture { [weak self] error in
      DispatchQueue.main.async {
        guard let self = self else { return }
        guard error == nil, self.pending?.token == token else {
          stream.stopCapture { _ in }
          if self.pending?.token == token { self.answerStart(nil) }
          return
        }
        self.live = capture
        self.latest = nil
        self.answerStart(["width": size.width, "height": size.height])
      }
    }
  }

  private func answerStart(_ reply: Any?) {
    guard let result = pending?.result else { return }
    pending = nil
    if live == nil { picker.isActive = false }
    result(reply)
  }

  // MARK: - Frames

  private func offer(seq: Int, jpeg: Data, from capture: Capture) {
    guard live === capture else { return }
    latest = (seq, jpeg)
    guard let w = waiting, seq > w.after else { return }
    answer(w, reply: ["seq": seq, "jpeg": FlutterStandardTypedData(bytes: jpeg)])
  }

  /// The newest frame after [after], or the same seq once [pullWait] passes
  /// with none, so a still screen costs a round trip a second and a half.
  private func frame(after: Int, result: @escaping FlutterResult) {
    guard live != nil else {
      result(["ended": true])
      return
    }
    if let w = waiting { answer(w, reply: ["seq": w.after]) }
    if let now = latest, now.seq > after {
      result(["seq": now.seq, "jpeg": FlutterStandardTypedData(bytes: now.jpeg)])
      return
    }
    waitTokens += 1
    let w = Waiting(after: after, result: result, token: waitTokens)
    waiting = w
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.pullWait) { [weak self] in
      guard let self = self, self.waiting?.token == w.token else { return }
      self.answer(w, reply: ["seq": after])
    }
  }

  private func answer(_ w: Waiting, reply: Any) {
    waiting = nil
    w.result(reply)
  }

  // MARK: - Ending

  /// The user stopped it from the menu bar, or the system did.
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    DispatchQueue.main.async { self.stopped(stream) }
  }

  @available(macOS 14.4, *)
  func userDidStopStream(_ stream: SCStream) {
    DispatchQueue.main.async { self.stopped(stream) }
  }

  private func stopped(_ stream: SCStream) {
    guard live?.stream === stream else { return }
    end(notify: true)
  }

  private func end(notify: Bool) {
    guard let capture = live else { return }
    live = nil
    latest = nil
    picker.isActive = false
    try? capture.stream.removeStreamOutput(capture, type: .screen)
    capture.stream.stopCapture { _ in }
    if let w = waiting { answer(w, reply: ["ended": true]) }
    if notify { channel.invokeMethod("ended", arguments: nil) }
  }

  /// The picked content scaled down, never up, to the page's caps and the
  /// app's long-side cap, in even pixels for the video encoder the page
  /// feeds it to. The same rule as `ScreenShareService.fit` on Android.
  private static func fit(width: Int, height: Int, request: Request) -> (width: Int, height: Int) {
    var scale = 1.0
    let longSide = max(width, height)
    if request.maxLongSide > 0 && request.maxLongSide < longSide {
      scale = min(scale, Double(request.maxLongSide) / Double(longSide))
    }
    if request.maxWidth > 0 && request.maxWidth < width {
      scale = min(scale, Double(request.maxWidth) / Double(width))
    }
    if request.maxHeight > 0 && request.maxHeight < height {
      scale = min(scale, Double(request.maxHeight) / Double(height))
    }
    func even(_ v: Double) -> Int { max(2, (Int(v.rounded()) / 2) * 2) }
    return (even(Double(width) * scale), even(Double(height) * scale))
  }
}

/// One stream's output: each complete frame as a JPEG, encoded on the
/// stream's own queue and handed to the main queue by [onFrame], which is
/// told which capture it came from. Its sequence counter is that queue's
/// alone.
@available(macOS 14.0, *)
private final class Capture: NSObject, SCStreamOutput {
  let stream: SCStream
  let queue = DispatchQueue(label: "org.codeberg.theoden8.webspace.screen-share")
  private let onFrame: (Capture, Int, Data) -> Void
  private let context = CIContext()
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  private var seq = 0

  init(stream: SCStream, onFrame: @escaping (Capture, Int, Data) -> Void) {
    self.stream = stream
    self.onFrame = onFrame
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
  ) {
    // A complete frame, or the first one a stream sends, carries a new
    // image; an idle one means the screen did not change.
    guard type == .screen,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let raw = attachments.first?[.status] as? Int,
      let status = SCFrameStatus(rawValue: raw),
      status == .complete || status == .started,
      let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
    else { return }
    let image = CIImage(cvPixelBuffer: pixels)
    let options = [
      CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String):
        0.6
    ]
    guard
      let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
    else { return }
    seq += 1
    onFrame(self, seq, jpeg)
  }
}

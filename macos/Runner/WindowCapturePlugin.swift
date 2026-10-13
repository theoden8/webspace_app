import Cocoa
import FlutterMacOS

#if DEBUG
  import ScreenCaptureKit

  /// The `window_capture` channel integration_test/screenshot_test.dart drives
  /// on macOS. Flutter's own integration_test plugin answers
  /// `captureScreenshot` with not-implemented here, and a capture of Flutter's
  /// layer alone would leave out the site, which WKWebView draws in another
  /// process. Debug builds only: no shipped build can image its own window.
  enum WindowCapturePlugin {
    static func attach(to messenger: FlutterBinaryMessenger, window: NSWindow) {
      let channel = FlutterMethodChannel(
        name: "org.codeberg.theoden8.webspace/window_capture",
        binaryMessenger: messenger
      )
      channel.setMethodCallHandler { [weak window] call, result in
        guard let window = window else {
          result(FlutterError(code: "no_window", message: nil, details: nil))
          return
        }
        switch call.method {
        case "resize":
          guard let args = call.arguments as? [String: Any],
            let width = args["width"] as? Double,
            let height = args["height"] as? Double
          else {
            result(
              FlutterError(
                code: "bad_args", message: "resize takes width and height",
                details: nil))
            return
          }
          resize(window, to: NSSize(width: width, height: height))
          result(nil)
        case "capture":
          if #available(macOS 14.4, *) {
            capture(windowID: CGWindowID(window.windowNumber), result: result)
          } else {
            result(
              FlutterError(
                code: "unsupported",
                message: "window capture needs macOS 14.4 (ScreenCaptureKit)",
                details: nil))
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    /// The whole window, title bar included, at [size] points, pinned to the
    /// top left of its screen's visible area.
    private static func resize(_ window: NSWindow, to size: NSSize) {
      let visible = window.screen?.visibleFrame ?? window.frame
      window.setFrame(
        NSRect(
          x: visible.minX, y: visible.maxY - size.height,
          width: size.width, height: size.height),
        display: true)
    }

    /// The window as the window server composites it, so the webview is in
    /// it, as PNG. The current process's own windows need no Screen
    /// Recording permission. Not CGWindowListCreateImage: it returns no
    /// image on macOS 26.
    @available(macOS 14.4, *)
    private static func capture(
      windowID: CGWindowID, result: @escaping FlutterResult
    ) {
      func reply(_ value: Any?) {
        DispatchQueue.main.async { result(value) }
      }
      func failure(_ message: String) {
        reply(
          FlutterError(code: "capture_failed", message: message, details: nil))
      }
      SCShareableContent.getCurrentProcessShareableContent { content, error in
        guard
          let scWindow = content?.windows.first(where: {
            $0.windowID == windowID
          })
        else {
          failure("window \(windowID) not shareable: \(String(describing: error))")
          return
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        SCScreenshotManager.captureImage(
          contentFilter: filter, configuration: config
        ) { image, error in
          guard let image = image,
            let png = NSBitmapImageRep(cgImage: image).representation(
              using: .png, properties: [:])
          else {
            failure("no image: \(String(describing: error))")
            return
          }
          reply(FlutterStandardTypedData(bytes: png))
        }
      }
    }
  }
#endif

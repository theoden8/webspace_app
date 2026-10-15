import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Same runtime as iOS, behind the same developer-mode gate (TOR-007),
  /// and the one an integration tier can actually drive (TOR-021).
  ///
  /// Registered here rather than from the app delegate: that path looks the
  /// window up through `NSApplication.shared.windows.first` and returns
  /// quietly when it is not there yet, which under `flutter test -d macos`
  /// it is not. Every Tor call then answered `MissingPluginException`. This
  /// is where the engine is known to exist -- the generated plugins register
  /// on the line above.
  private var torControllerPlugin: TorControllerPlugin?
  private var contentRuleListPlugin: ContentRuleListPlugin?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    torControllerPlugin = TorControllerPlugin(
      messenger: flutterViewController.engine.binaryMessenger)
    contentRuleListPlugin = ContentRuleListPlugin(
      messenger: flutterViewController.engine.binaryMessenger)
    HostBrowserPlugin.attach(to: flutterViewController.engine.binaryMessenger)
    #if DEBUG
      WindowCapturePlugin.attach(
        to: flutterViewController.engine.binaryMessenger, window: self)
    #endif

    super.awakeFromNib()
  }

  #if DEBUG
    /// Set by WindowCapturePlugin's resize. A store-size window is taller
    /// than a CI runner's screen, and AppKit would shrink it to fit.
    var keepsFrameBeyondScreen = false

    override func constrainFrameRect(
      _ frameRect: NSRect, to screen: NSScreen?
    ) -> NSRect {
      keepsFrameBeyondScreen
        ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
  #endif
}

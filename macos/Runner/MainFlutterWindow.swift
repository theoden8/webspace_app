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

  /// BUG-014's probe. Registered the same way and for the same reason: the
  /// integration tier drives it, and nothing reaches it otherwise.
  private var proxyProbePlugin: ProxyProbePlugin?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    torControllerPlugin = TorControllerPlugin(
      messenger: flutterViewController.engine.binaryMessenger)
    proxyProbePlugin = ProxyProbePlugin(
      messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

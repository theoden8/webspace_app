import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var profilePlugin: WebSpaceProfilePlugin?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    profilePlugin = WebSpaceProfilePlugin(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

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

  /// NOTIF-018: the app setting, which lib/services/desktop_window.dart sends
  /// over the `desktop_window` channel. With it on, a close hides the window
  /// and the app keeps running; the Dock icon (AppDelegate) and the channel's
  /// `show` bring it back.
  private(set) var closeHides = false

  /// NOTIF-019: the menu bar icon lib/services/menu_bar_tray.dart draws over
  /// the `tray` channel while a close only hides the window. A press on a
  /// line, and the menu about to open, go back over the same channel.
  private var trayChannel: FlutterMethodChannel?
  private var statusItem: NSStatusItem?
  private let trayMenu = NSMenu()

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
    ScreenSharePlugin.attach(to: flutterViewController.engine.binaryMessenger)
    attachDesktopWindowChannel(to: flutterViewController.engine.binaryMessenger)
    attachTrayChannel(to: flutterViewController.engine.binaryMessenger)
    #if DEBUG
      WindowCapturePlugin.attach(
        to: flutterViewController.engine.binaryMessenger, window: self)
    #endif

    super.awakeFromNib()
  }

  /// The close button sends this.
  override func performClose(_ sender: Any?) {
    if closeHides {
      orderOut(sender)
    } else {
      super.performClose(sender)
    }
  }

  private func attachDesktopWindowChannel(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "org.codeberg.theoden8.webspace/desktop_window",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "no_window", message: nil, details: nil))
        return
      }
      switch call.method {
      case "setKeepRunningWhenClosed":
        guard let args = call.arguments as? [String: Any],
          let keep = args["keep"] as? Bool
        else {
          result(
            FlutterError(
              code: "bad_args", message: "setKeepRunningWhenClosed takes keep",
              details: nil))
          return
        }
        self.closeHides = keep
        result(nil)
      case "show":
        // A press in the menu bar icon's menu leaves another app in front
        // (NOTIF-019); the Dock and a notification activate the app themselves.
        if #available(macOS 14.0, *) {
          NSApp.activate()
        } else {
          NSApp.activate(ignoringOtherApps: true)
        }
        self.makeKeyAndOrderFront(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func attachTrayChannel(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "org.codeberg.theoden8.webspace/tray",
      binaryMessenger: messenger
    )
    trayMenu.delegate = self
    trayMenu.autoenablesItems = false
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "no_window", message: nil, details: nil))
        return
      }
      switch call.method {
      case "show":
        guard let args = call.arguments as? [String: Any],
          let title = args["title"] as? String,
          let entries = args["entries"] as? [[String: Any]]
        else {
          result(
            FlutterError(
              code: "bad_args", message: "show takes title and entries", details: nil))
          return
        }
        let icon = (args["icon"] as? FlutterStandardTypedData)?.data
        self.showTray(title: title, icon: icon, entries: entries)
        result(nil)
      case "remove":
        if let item = self.statusItem {
          NSStatusBar.system.removeStatusItem(item)
        }
        self.statusItem = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    trayChannel = channel
  }

  private func showTray(title: String, icon: Data?, entries: [[String: Any]]) {
    let item =
      statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    if let button = item.button {
      if let icon = icon, let image = NSImage(data: icon) {
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        button.image = image
        button.title = ""
      } else {
        button.image = nil
        button.title = title
      }
      button.toolTip = title
    }
    trayMenu.removeAllItems()
    for entry in entries {
      guard let id = entry["id"] as? Int else { continue }
      guard let label = entry["label"] as? String else {
        trayMenu.addItem(NSMenuItem.separator())
        continue
      }
      let line = NSMenuItem(
        title: label, action: #selector(trayPressed(_:)),
        keyEquivalent: (entry["quits"] as? Bool ?? false) ? "q" : "")
      line.target = self
      line.tag = id
      trayMenu.addItem(line)
    }
    item.menu = trayMenu
  }

  @objc private func trayPressed(_ sender: NSMenuItem) {
    trayChannel?.invokeMethod("pressed", arguments: ["id": sender.tag])
  }

  #if DEBUG
    /// The menu bar icon's lines, a separator as "-", or nil with no icon:
    /// for window_capture's `trayMenu` (NOTIF-019).
    var trayMenuTitles: [String]? {
      statusItem == nil
        ? nil : trayMenu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    /// What a click on the menu bar icon tells the app before the menu shows.
    func openTray() {
      menuWillOpen(trayMenu)
    }

    /// A press on line [index] of the menu, as a click sends it.
    func pressTray(at index: Int) -> Bool {
      guard statusItem != nil, index >= 0, index < trayMenu.items.count else {
        return false
      }
      trayMenu.performActionForItem(at: index)
      return true
    }
  #endif

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

extension MainFlutterWindow: NSMenuDelegate {
  /// The app reads each site's unread count afresh and sends the menu again.
  func menuWillOpen(_ menu: NSMenu) {
    guard menu === trayMenu else { return }
    trayChannel?.invokeMethod("opening", arguments: nil)
  }
}

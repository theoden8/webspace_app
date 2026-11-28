import Cocoa
import FlutterMacOS

/// A11Y-012: the Site menu, which lists the app's keyboard shortcuts as
/// lib/services/shortcut_menu.dart sends them over the `shortcut_menu`
/// channel. It goes beside the stock menus of MainMenu.xib rather than in
/// place of them: WKWebView takes Cut, Copy, Paste, Undo and Select All from
/// the Edit menu's items, which Flutter's PlatformMenuBar would remove.
///
/// The items write their keys but answer none of them (`menuHasKeyEquivalent`),
/// so a key reaches the Flutter view as it did and runs once there; a click
/// on an item goes back over the channel by its id.
final class ShortcutMenuPlugin: NSObject, NSMenuDelegate {
  private static var attached: ShortcutMenuPlugin?

  private let channel: FlutterMethodChannel
  private let menu = NSMenu()
  private var holder: NSMenuItem?

  static func attach(to messenger: FlutterBinaryMessenger) {
    attached = ShortcutMenuPlugin(
      channel: FlutterMethodChannel(
        name: "org.codeberg.theoden8.webspace/shortcut_menu",
        binaryMessenger: messenger))
  }

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    menu.delegate = self
    menu.autoenablesItems = false
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "no_menu", message: nil, details: nil))
        return
      }
      switch call.method {
      case "show":
        guard let args = call.arguments as? [String: Any],
          let title = args["title"] as? String,
          let items = args["items"] as? [[String: Any]]
        else {
          result(
            FlutterError(
              code: "bad_args", message: "show takes title and items", details: nil))
          return
        }
        self.show(title: title, items: items)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func show(title: String, items: [[String: Any]]) {
    menu.title = title
    menu.removeAllItems()
    for entry in items {
      guard let id = entry["id"] as? Int,
        let label = entry["title"] as? String,
        let key = entry["key"] as? String
      else { continue }
      let item = NSMenuItem(
        title: label, action: #selector(pressed(_:)), keyEquivalent: key)
      var modifiers: NSEvent.ModifierFlags = []
      if entry["command"] as? Bool == true { modifiers.insert(.command) }
      if entry["shift"] as? Bool == true { modifiers.insert(.shift) }
      if entry["option"] as? Bool == true { modifiers.insert(.option) }
      if entry["control"] as? Bool == true { modifiers.insert(.control) }
      item.keyEquivalentModifierMask = modifiers
      item.target = self
      item.tag = id
      menu.addItem(item)
    }
    place(title: title, shown: !menu.items.isEmpty)
  }

  /// Before the Window menu, where Safari keeps its History menu; out of the
  /// menu bar while it lists nothing.
  private func place(title: String, shown: Bool) {
    guard let bar = NSApp.mainMenu else { return }
    guard shown else {
      if let holder = holder { bar.removeItem(holder) }
      holder = nil
      return
    }
    let item = holder ?? NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.title = title
    item.submenu = menu
    if holder == nil {
      let window = bar.items.firstIndex { $0.submenu === NSApp.windowsMenu }
      bar.insertItem(item, at: window ?? bar.items.count)
      holder = item
    }
  }

  @objc private func pressed(_ sender: Any?) {
    guard let item = sender as? NSMenuItem else { return }
    channel.invokeMethod("pressed", arguments: ["id": item.tag])
  }

  func menuHasKeyEquivalent(
    _ menu: NSMenu, for event: NSEvent,
    target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
    action: UnsafeMutablePointer<Selector?>
  ) -> Bool {
    false
  }
}

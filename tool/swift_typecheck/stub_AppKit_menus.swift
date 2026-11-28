// AppKit's menus, compiled into a second Cocoa stub beside stub_Cocoa.swift
// for macos/Runner/ShortcutMenuPlugin.swift alone, since it needs the
// Objective-C stand-in the other Runner sources must not see (their
// Selector is linux_foundation_gaps.swift's). Shapes transcribed from
// NSMenu.h, NSMenuItem.h, NSEvent.h and NSApplication.h.

@_exported import ObjectiveC

open class NSEvent: NSObject {
  // typedef NS_OPTIONS(NSUInteger, NSEventModifierFlags)
  public struct ModifierFlags: OptionSet {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let shift = ModifierFlags(rawValue: 1 << 17)
    public static let control = ModifierFlags(rawValue: 1 << 18)
    public static let option = ModifierFlags(rawValue: 1 << 19)
    public static let command = ModifierFlags(rawValue: 1 << 20)
  }
}

open class NSMenuItem: NSObject {
  // - (instancetype)initWithTitle:(NSString *)string action:(nullable SEL)selector
  //     keyEquivalent:(NSString *)charCode;
  public init(title string: String, action selector: Selector?, keyEquivalent charCode: String) {}
  open var title: String = ""
  open var submenu: NSMenu?
  open weak var target: AnyObject?
  open var tag: Int = 0
  open var keyEquivalentModifierMask: NSEvent.ModifierFlags = []
}

// NSMenuDelegate, the one optional method a Runner source implements. The
// real protocol is an @objc one that refines NSObjectProtocol and leaves the
// method optional; with no Objective-C classes here it is a plain
// requirement, so the one source checked against it must match the SDK's
// signature exactly or fail to type-check.
public protocol NSMenuDelegate: AnyObject {
  // - (BOOL)menuHasKeyEquivalent:(NSMenu *)menu forEvent:(NSEvent *)event
  //     target:(id _Nullable * _Nonnull)target action:(SEL _Nullable * _Nonnull)action;
  func menuHasKeyEquivalent(
    _ menu: NSMenu, for event: NSEvent,
    target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
    action: UnsafeMutablePointer<Selector?>
  ) -> Bool
}

open class NSMenu: NSObject {
  open var title: String = ""
  open weak var delegate: NSMenuDelegate?
  open var autoenablesItems: Bool = true
  open var items: [NSMenuItem] = []
  open func addItem(_ newItem: NSMenuItem) {}
  open func insertItem(_ newItem: NSMenuItem, at index: Int) {}
  open func removeItem(_ item: NSMenuItem) {}
  open func removeAllItems() {}
}

extension NSApplication {
  // @property (nullable, strong) NSMenu *mainMenu;
  public var mainMenu: NSMenu? {
    get { nil }
    set {}
  }
  // @property (nullable, strong) NSMenu *windowsMenu;
  public var windowsMenu: NSMenu? {
    get { nil }
    set {}
  }
}

// APPKIT_EXTERN __kindof NSApplication * _Null_unspecified NSApp;
public var NSApp: NSApplication! = NSApplication.shared

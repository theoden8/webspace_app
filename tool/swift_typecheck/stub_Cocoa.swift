// Stand-in for the Cocoa umbrella that macos/Runner/*.swift imports.
//
// Almost empty on purpose: what the probe needs from Cocoa is what the real
// umbrella re-exports from Foundation -- NSObject, URL, UUID, NSRect,
// URLRequest. Re-exporting rather than redeclaring keeps the type checker
// policing those signatures instead of ones invented here.

@_exported import Foundation
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif

// AppKit, only as much of it as the probe touches. The real Cocoa umbrella
// re-exports these; on Linux there is no AppKit at all, so the shapes are
// transcribed from NSView.h / NSWindow.h / NSApplication.h rather than
// guessed -- a stub that got addSubview's label wrong would pass exactly the
// mistake this exists to catch.

open class NSView: NSObject {
  open func addSubview(_ view: NSView) {}
  open func removeFromSuperview() {}
}

open class NSWindow: NSObject {
  open var contentView: NSView?
}

open class NSApplication: NSObject {
  public static let shared = NSApplication()
  open var keyWindow: NSWindow?
}

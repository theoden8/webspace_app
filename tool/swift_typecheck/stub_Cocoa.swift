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

// Stand-in for the ObjectiveC module, which the real Cocoa umbrella
// re-exports and Linux has none of. With it, and the compiler's Objective-C
// interop switched on, a Runner source that names its action by #selector
// type-checks here: #selector then checks that the method exists and is
// exposed to Objective-C, which is the mistake it is here to catch.

// objc/objc.h: typedef struct objc_selector *SEL;
public struct Selector: ExpressibleByStringLiteral {
  public init(_ name: String) {}
  public init(stringLiteral value: String) {}
}

// The standard library's on Apple platforms (`id *` in an Objective-C
// signature), compiled only where the Objective-C runtime is.
public struct AutoreleasingUnsafeMutablePointer<Pointee> {}

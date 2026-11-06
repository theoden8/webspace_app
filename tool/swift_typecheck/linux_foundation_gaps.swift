// What Apple's Foundation has and swift-corelibs-foundation lacks, compiled
// beside the shared ios/Runner sources so they type-check on Linux. Never
// built on macOS, where the real declarations would collide with these.

import Foundation

extension FileManager {
  // NSFileManager.h:
  // - (nullable NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier;
  public func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
    nil
  }
}

// The Objective-C runtime, which Foundation re-exports on Apple platforms
// (objc/runtime.h, objc/objc.h, NSObject.h).

// typedef struct objc_selector *SEL;
public struct Selector {}
// FOUNDATION_EXPORT SEL NSSelectorFromString(NSString *aSelectorName);
public func NSSelectorFromString(_ aSelectorName: String) -> Selector { Selector() }
// typedef void (*IMP)(void /* id, SEL, ... */ );
public typealias IMP = OpaquePointer
// OBJC_EXPORT BOOL class_addMethod(Class cls, SEL name, IMP imp, const char *types);
public func class_addMethod(
  _ cls: AnyClass?, _ name: Selector, _ imp: IMP, _ types: UnsafePointer<CChar>?
) -> Bool { false }
// OBJC_EXPORT IMP imp_implementationWithBlock(id block);
public func imp_implementationWithBlock(_ block: Any) -> IMP { OpaquePointer(bitPattern: 1)! }

extension NSObject {
  // - (BOOL)respondsToSelector:(SEL)aSelector;
  public func responds(to aSelector: Selector!) -> Bool { false }
  // - (nullable id)valueForKey:(NSString *)key;
  public func value(forKey key: String) -> Any? { nil }
}

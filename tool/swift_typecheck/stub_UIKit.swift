// Stand-in for the UIKit that the iOS side of the shared ios/Runner sources
// imports, so it can be type-checked on a machine with no SDK.
//
// Only what those sources touch, transcribed from the headers named below
// rather than guessed: a stub that got a label wrong would pass exactly the mistake this
// exists to catch. The platform-view code is iOS-only (`#if os(iOS)`) and is
// not compiled here.

@_exported import Foundation

// MARK: - UIApplication.h

open class UIApplication: NSObject {
  // @property(class, nonatomic, readonly) UIApplication *sharedApplication;
  open class var shared: UIApplication { UIApplication() }

  // typedef NSString * UIApplicationOpenExternalURLOptionsKey NS_TYPED_ENUM;
  public struct OpenExternalURLOptionsKey: Hashable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
  }

  // - (void)openURL:(NSURL *)url
  //         options:(NSDictionary<UIApplicationOpenExternalURLOptionsKey, id> *)options
  // completionHandler:(void (^ __nullable)(BOOL success))completion;
  open func open(
    _ url: URL,
    options: [UIApplication.OpenExternalURLOptionsKey: Any] = [:],
    completionHandler completion: ((Bool) -> Void)? = nil
  ) {}
}

// MARK: - UIResponder.h, UIScene.h, UISceneSession.h, UISceneOptions.h, UIOpenURLContext.h

open class UIResponder: NSObject {}

// @interface UIScene : UIResponder
open class UIScene: UIResponder {
  // @interface UISceneConnectionOptions : NSObject, UIScene.ConnectionOptions in Swift
  open class ConnectionOptions: NSObject {
    // @property (nonatomic, readonly, copy) NSSet<UIOpenURLContext *> *URLContexts;
    open var urlContexts: Set<UIOpenURLContext> { [] }
  }
}

// @interface UISceneSession : NSObject <NSSecureCoding>
open class UISceneSession: NSObject {}

// @interface UIOpenURLContext : NSObject
open class UIOpenURLContext: NSObject {
  // @property (nonatomic, readonly, copy) NSURL *URL;
  open var url: URL { URL(fileURLWithPath: "/") }
}

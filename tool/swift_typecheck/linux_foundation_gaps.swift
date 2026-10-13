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

// One source, both Apple Runners, every build: counting only, no WebKit and
// no private API, so it is tested apart from the hook in
// WebKitBlockReports.swift that only a -direct build compiles (CB-023):
// tool/swift_tests on any Swift toolchain, ios/RunnerTests in Xcode.
import Foundation

/// The loads one view's content rule lists blocked since its last hand-off
/// to the page. WebKit reports a load once per list that acted on it, so a
/// URL's loads are its reports over the lists that made them: each load of a
/// URL meets the same lists.
struct WebKitBlockedLoads {
  private var order: [String] = []
  private var seen: [String: (lists: Set<String>, reports: Int)] = [:]
  private let capacity: Int

  init(capacity: Int) {
    precondition(capacity > 0, "a batch holds at least one URL")
    self.capacity = capacity
  }

  /// Counts one report of `url` by the list named `list`. False when the
  /// batch is full and `url` is new to it.
  @discardableResult
  mutating func report(url: String, list: String) -> Bool {
    if let (lists, reports) = seen[url] {
      seen[url] = (lists.union([list]), reports + 1)
      return true
    }
    guard order.count < capacity else { return false }
    order.append(url)
    seen[url] = ([list], 1)
    return true
  }

  /// Each URL once per load, in the order first reported.
  var loads: [String] {
    order.flatMap { url -> [String] in
      guard let (lists, reports) = seen[url] else { return [] }
      return Array(repeating: url, count: max(1, reports / lists.count))
    }
  }
}

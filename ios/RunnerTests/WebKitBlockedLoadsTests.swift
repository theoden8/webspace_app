import XCTest

// The macOS app's module takes its product name; iOS and tool/swift_tests
// name theirs Runner.
#if os(macOS)
  @testable import Webspace
#else
  @testable import Runner
#endif

/// How WebKit's block reports become loads (content-blocker CB-023). WebKit
/// reports a blocked load once per content rule list that acted on it, and
/// the app's rules are split across several lists, so counting reports
/// counts some loads twice.
///
/// Run headlessly by tool/swift_tests on any Swift toolchain (CI's validate
/// job), and by `xcodebuild test` in the macOS app (CI's Apple job).
final class WebKitBlockedLoadsTests: XCTestCase {

  func testALoadTwoListsBlockedCountsOnce() {
    var blocked = WebKitBlockedLoads(capacity: 10)
    blocked.report(url: "https://ads.example/a.js", list: "wcrl-x-0of2")
    blocked.report(url: "https://ads.example/a.js", list: "wcrl-x-1of2")
    XCTAssertEqual(blocked.loads, ["https://ads.example/a.js"])
  }

  func testEachLoadOfAURLCounts() {
    var blocked = WebKitBlockedLoads(capacity: 10)
    for _ in 0..<3 {
      blocked.report(url: "https://ads.example/p.gif", list: "wcrl-x-0of2")
      blocked.report(url: "https://ads.example/p.gif", list: "wcrl-x-1of2")
    }
    blocked.report(url: "https://t.example/b", list: "wcrl-x-0of2")
    blocked.report(url: "https://t.example/b", list: "wcrl-x-0of2")
    XCTAssertEqual(blocked.loads, [
      "https://ads.example/p.gif", "https://ads.example/p.gif", "https://ads.example/p.gif",
      "https://t.example/b", "https://t.example/b",
    ])
  }

  func testLoadsKeepTheOrderFirstReported() {
    var blocked = WebKitBlockedLoads(capacity: 10)
    blocked.report(url: "https://b.example/", list: "wcrl-x-0of1")
    blocked.report(url: "https://a.example/", list: "wcrl-x-0of1")
    XCTAssertEqual(blocked.loads, ["https://b.example/", "https://a.example/"])
  }

  func testAFullBatchRefusesANewURLButCountsAKnownOne() {
    var blocked = WebKitBlockedLoads(capacity: 1)
    XCTAssertTrue(blocked.report(url: "https://a.example/", list: "wcrl-x-0of1"))
    XCTAssertFalse(blocked.report(url: "https://b.example/", list: "wcrl-x-0of1"))
    XCTAssertTrue(blocked.report(url: "https://a.example/", list: "wcrl-x-0of1"))
    XCTAssertEqual(blocked.loads, ["https://a.example/", "https://a.example/"])
  }

  func testNothingReportedIsNoLoad() {
    XCTAssertEqual(WebKitBlockedLoads(capacity: 1).loads, [])
  }
}

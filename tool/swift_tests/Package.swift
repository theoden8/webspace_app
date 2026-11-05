// swift-tools-version:5.9
// The Runner's plain Swift (no Apple framework, no Flutter) under XCTest on
// any Swift toolchain, so CI's Linux validate job runs it headlessly: each
// file under Sources/Runner and Tests/RunnerTests is a link to the one the
// Xcode projects compile, and the module is named Runner, so a test's
// `@testable import Runner` holds in both places. Run: tool/swift_tests/run.sh
import PackageDescription

let package = Package(
  name: "RunnerSwiftTests",
  targets: [
    .target(name: "Runner", path: "Sources/Runner"),
    .testTarget(name: "RunnerTests", dependencies: ["Runner"], path: "Tests/RunnerTests"),
  ]
)

// swift-tools-version:5.9
// The Runner's Swift that runs without an Apple SDK, under XCTest on any
// Swift toolchain, so CI's Linux validate job runs it headlessly: each file
// under Sources/Runner and Tests/RunnerTests is a link to the one the Xcode
// projects compile, and the module is named Runner, so a test's
// `@testable import Runner` holds in both places. The Tor plugin builds
// against the stand-ins for Flutter, Tor and IPtProxy that tool/swift_typecheck
// transcribes, so its tests reach only what runs without them: the parsing of
// tor's control-port output. Run: tool/swift_tests/run.sh
import PackageDescription

let package = Package(
  name: "RunnerSwiftTests",
  targets: [
    .target(name: "Flutter", path: "Sources/Flutter"),
    .target(name: "Tor", path: "Sources/Tor"),
    .target(name: "IPtProxy", path: "Sources/IPtProxy"),
    .target(
      name: "Runner", dependencies: ["Flutter", "Tor", "IPtProxy"], path: "Sources/Runner"),
    .testTarget(name: "RunnerTests", dependencies: ["Runner"], path: "Tests/RunnerTests"),
  ]
)

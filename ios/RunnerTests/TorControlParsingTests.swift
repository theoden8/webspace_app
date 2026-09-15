import XCTest

@testable import Runner

/// Parsing of tor's control-port output (TOR-018).
///
/// The shapes below are what tor and Tor.framework actually hand over — in
/// particular `getInfoForKeys` trims the outer quotes off a value, so the
/// `SUMMARY="…"` of a `status/bootstrap-phase` answer arrives with its
/// closing quote already gone. Getting that wrong loses the phase text
/// silently: the bar still moves and the line under it is simply absent.
///
/// No CI tier in this repo runs Swift, so these run in Xcode.
class TorControlParsingTests: XCTestCase {

  func testBootstrapPhaseFromGetInfo() {
    let phase = TorControllerPlugin.parseBootstrapPhase(
      "NOTICE BOOTSTRAP PROGRESS=45 TAG=loading_descriptors SUMMARY=\"Loading relay descriptors")
    XCTAssertEqual(phase?.pct, 45)
    XCTAssertEqual(phase?.tag, "loading_descriptors")
    XCTAssertEqual(phase?.summary, "Loading relay descriptors")
  }

  func testBootstrapPhaseWithClosingQuote() {
    let phase = TorControllerPlugin.parseBootstrapPhase(
      "NOTICE BOOTSTRAP PROGRESS=100 TAG=done SUMMARY=\"Done\"")
    XCTAssertEqual(phase?.pct, 100)
    XCTAssertEqual(phase?.summary, "Done")
  }

  func testBootstrapProblemKeepsItsSummary() {
    let line = "WARN BOOTSTRAP PROGRESS=10 TAG=conn_done SUMMARY=\"Connected to a relay\" "
      + "WARNING=\"Connection refused\" REASON=CONNECTREFUSED COUNT=3 RECOMMENDATION=warn"
    XCTAssertEqual(TorControllerPlugin.parseBootstrapPhase(line)?.summary, "Connected to a relay")
    XCTAssertEqual(TorControllerPlugin.parseKeyValues(line)["REASON"], "CONNECTREFUSED")
  }

  func testNonBootstrapLines() {
    XCTAssertNil(TorControllerPlugin.parseBootstrapPhase("250 OK"))
    XCTAssertNil(TorControllerPlugin.parseBootstrapPhase("NOTICE BOOTSTRAP TAG=starting"))
  }

  func testLogEventSeverities() {
    let notice = TorControllerPlugin.parseLogEvent(
      "NOTICE Bootstrapped 30% (loading_status): Loading networkstatus consensus")
    XCTAssertEqual(notice?.severity, "notice")
    XCTAssertEqual(
      notice?.message, "Bootstrapped 30% (loading_status): Loading networkstatus consensus")
    XCTAssertEqual(TorControllerPlugin.parseLogEvent("WARN Problem bootstrapping.")?.severity, "warn")
    XCTAssertEqual(TorControllerPlugin.parseLogEvent("ERR Reading config failed.")?.severity, "err")
  }

  func testStatusEventsAreNotLogLines() {
    // They belong to the status observer; treating one as a log line would
    // also mean the observer never sees it.
    XCTAssertNil(TorControllerPlugin.parseLogEvent("STATUS_CLIENT NOTICE BOOTSTRAP PROGRESS=5"))
    XCTAssertNil(TorControllerPlugin.parseLogEvent("NOTICEBOARD something"))
  }

  func testSocksEndpoint() {
    let endpoint = TorControllerPlugin.parseSocksEndpoint("\"127.0.0.1:41337\"")
    XCTAssertEqual(endpoint?.host, "127.0.0.1")
    XCTAssertEqual(endpoint?.port, 41337)
    XCTAssertNil(TorControllerPlugin.parseSocksEndpoint(""))
    XCTAssertNil(TorControllerPlugin.parseSocksEndpoint(nil))
    XCTAssertNil(TorControllerPlugin.parseSocksEndpoint("127.0.0.1:0"))
  }
}

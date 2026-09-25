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

  func testTorLogLines() {
    // What tor writes to its log file. The timestamp goes: every entry in
    // the app log already carries one.
    let notice = TorControllerPlugin.parseTorLogLine(
      "Sep 15 16:29:42.123 [notice] Opening Socks listener on 127.0.0.1:0")
    XCTAssertEqual(notice.severity, "notice")
    XCTAssertEqual(notice.message, "Opening Socks listener on 127.0.0.1:0")

    XCTAssertEqual(
      TorControllerPlugin.parseTorLogLine("Sep 15 16:29:42.123 [warn] Nope").severity, "warn")
    XCTAssertEqual(
      TorControllerPlugin.parseTorLogLine("Sep 15 16:29:42.123 [err] Fatal").severity, "err")
    XCTAssertEqual(
      TorControllerPlugin.parseTorLogLine("Sep 15 16:29:42.123 [info] Chatty").severity, "notice")
  }

  func testTorLogLineWithoutASeverity() {
    // A continuation line, or anything else tor decides to write: keep it
    // whole rather than dropping it.
    let line = "  (Closing stream)"
    let parsed = TorControllerPlugin.parseTorLogLine(line)
    XCTAssertEqual(parsed.severity, "notice")
    XCTAssertEqual(parsed.message, line)
  }

  func testSocksEndpoint() {
    let endpoint = TorControllerPlugin.parseSocksEndpoint("\"127.0.0.1:41337\"")
    XCTAssertEqual(endpoint?.host, "127.0.0.1")
    XCTAssertEqual(endpoint?.port, 41337)
    XCTAssertNil(TorControllerPlugin.parseSocksEndpoint(""))
    XCTAssertNil(TorControllerPlugin.parseSocksEndpoint(nil))
    XCTAssertNil(TorControllerPlugin.parseSocksEndpoint("127.0.0.1:0"))
  }

  func testExitCircuitIds() {
    // `GETINFO circuit-status`, one circuit per line (control-spec 4.1.1).
    let status = [
      "5 BUILT $AAAA~guard,$BBBB~middle,$CCCC~exit BUILD_FLAGS=NEED_CAPACITY "
        + "PURPOSE=GENERAL TIME_CREATED=2026-09-23T22:43:33.140529",
      "9 BUILT $AAAA~guard,$DDDD~middle BUILD_FLAGS=IS_INTERNAL,NEED_CAPACITY "
        + "PURPOSE=HS_CLIENT_REND HS_STATE=HSCR_JOINED",
      "12 LAUNCHED BUILD_FLAGS=NEED_CAPACITY PURPOSE=CONFLUX_UNLINKED",
      "13 EXTENDED $AAAA~guard,$EEEE~middle PURPOSE=CONFLUX_LINKED",
      "14 FAILED $AAAA~guard PURPOSE=GENERAL REASON=TIMEOUT",
      "15 BUILT $AAAA~guard,$FFFF~middle,$GGGG~exit",
      "",
    ].joined(separator: "\r\n")
    XCTAssertEqual(
      TorControllerPlugin.exitCircuitIds(fromCircuitStatus: status), ["5", "12", "13", "15"])
    XCTAssertEqual(TorControllerPlugin.exitCircuitIds(fromCircuitStatus: ""), [])
  }

  func testExitAddressesFromNetworkStatus() {
    // `GETINFO ns/all`: an `r` line per relay, then its flags. The control
    // port prints the descriptor digest; a microdescriptor consensus has
    // none, so the address is counted from the end of the line.
    let status = [
      "r ForPrivacyNET ADb6NqtDX9XQ9kBiZjaGfr+3LGg epP7Gxm+NYhwC3V7SPORQCPoVgc "
        + "2022-11-18 00:01:48 185.220.101.33 10133 0",
      "a [2a0b:f4c2:2::33]:10133",
      "s Exit Fast Running V2Dir Valid",
      "w Bandwidth=37000",
      "r middle AAAA 2022-11-18 00:01:48 10.0.0.2 9001 0",
      "s Fast Guard Running Stable Valid",
      "r flagged BBBB CCCC 2022-11-18 00:01:48 10.0.0.3 9001 0",
      "s BadExit Exit Fast Running Valid",
      "r md DDDD 2022-11-18 00:01:48 10.0.0.4 443 0",
      "s Exit Fast Running Valid",
    ].joined(separator: "\r\n")
    XCTAssertEqual(
      TorControllerPlugin.exitAddresses(fromNetworkStatus: status),
      ["185.220.101.33", "10.0.0.4"])
  }

  func testExitCountFromConsensusAndTable() {
    // Read from tor's files rather than the control port (a GETINFO ns/all
    // there stalled every controller behind it). 10.0.0.4 is the only exit,
    // and the table puts it in DE.
    let consensus = [
      "r middle AAAA 2022-11-18 00:01:48 10.0.0.2 9001 0",
      "s Fast Guard Running Stable Valid",
      "r md DDDD 2022-11-18 00:01:48 10.0.0.4 443 0",
      "s Exit Fast Running Valid",
    ].joined(separator: "\n")
    let table = [
      "# comment",
      "167772160,167772163,NL",
      "167772164,167772164,DE",
    ].joined(separator: "\n")
    XCTAssertEqual(
      TorControllerPlugin.exitCount(in: ["de"], consensus: consensus, geoipTable: table), 1)
    XCTAssertEqual(
      TorControllerPlugin.exitCount(in: ["nl"], consensus: consensus, geoipTable: table), 0,
      "the NL relay is a middle, not an exit")
    XCTAssertEqual(
      TorControllerPlugin.exitCount(in: ["br"], consensus: consensus, geoipTable: table), 0)
    XCTAssertNil(
      TorControllerPlugin.exitCount(in: ["de"], consensus: "", geoipTable: table),
      "no exits read means the count says nothing")
  }

  func testPinnedCountries() {
    XCTAssertEqual(TorControllerPlugin.pinnedCountries("{br}"), ["br"])
    XCTAssertEqual(TorControllerPlugin.pinnedCountries("{DE},{nl}"), ["de", "nl"])
    // Anything but a country is not ours to count.
    XCTAssertNil(TorControllerPlugin.pinnedCountries("{de},$ABCD"))
    XCTAssertNil(TorControllerPlugin.pinnedCountries(""))
  }

  func testExitPinTurnsConfluxOffAndClearingRestoresIt() {
    func settings(_ confs: [[AnyHashable: Any]]) -> [String: String] {
      var out: [String: String] = [:]
      for conf in confs {
        out[conf["key"] as! String] = (conf["value"] as! String)
      }
      return out
    }
    // One SETCONF: a conflux set recovering a closed leg keeps its pre-pin
    // exit, so the pin is not in force until conflux is off with it.
    XCTAssertEqual(
      settings(TorControllerPlugin.exitPinConfigs("{br}")),
      ["ExitNodes": "{br}", "StrictNodes": "1", "ConfluxEnabled": "0"])
    XCTAssertEqual(
      settings(TorControllerPlugin.exitPinClearConfigs),
      ["StrictNodes": "0", "ConfluxEnabled": "auto"])
  }
}

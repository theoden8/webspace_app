import Foundation
import Network
import UIKit

/// Builds a Web Clip configuration profile (`.mobileconfig`) for one site and
/// hands it to Safari to install (HS-011).
///
/// iOS exposes no API to drop a Home Screen icon with a custom image. The only
/// supported path is a Web Clip payload delivered through a configuration
/// profile. iOS also only triggers the "Install Profile" flow when the
/// `.mobileconfig` is fetched by Safari with the
/// `application/x-apple-aspen-config` content type — opening a local file URL
/// does not — so the profile is served from a one-shot loopback HTTP listener
/// that we then open in Safari. A background-task assertion keeps the listener
/// alive across the app backgrounding while Safari connects.
@available(iOS 13, *)
final class WebClipInstaller {
  private var listener: NWListener?
  private var bgTask: UIBackgroundTaskIdentifier = .invalid
  private var profileData = Data()

  func install(label: String, urlString: String, iconBase64: String?) -> Bool {
    guard
      let data = Self.buildProfile(
        label: label, urlString: urlString, iconBase64: iconBase64)
    else { return false }
    profileData = data
    return serveAndOpen()
  }

  private static func buildProfile(
    label: String, urlString: String, iconBase64: String?
  ) -> Data? {
    let clipUUID = UUID().uuidString
    let profileUUID = UUID().uuidString
    var clip: [String: Any] = [
      "URL": urlString,
      "Label": label,
      "IsRemovable": true,
      "FullScreen": true,
      "Precomposed": true,
      "PayloadType": "com.apple.webClip.managed",
      "PayloadVersion": 1,
      "PayloadIdentifier": "org.codeberg.theoden8.webspace.webclip.\(clipUUID)",
      "PayloadUUID": clipUUID,
      "PayloadDisplayName": label,
    ]
    if let iconBase64 = iconBase64, let iconData = Data(base64Encoded: iconBase64) {
      clip["Icon"] = iconData
    }
    let profile: [String: Any] = [
      "PayloadContent": [clip],
      "PayloadType": "Configuration",
      "PayloadVersion": 1,
      "PayloadIdentifier":
        "org.codeberg.theoden8.webspace.webclip.profile.\(profileUUID)",
      "PayloadUUID": profileUUID,
      "PayloadDisplayName": "WebSpace: \(label)",
      "PayloadDescription": "Adds a Home Screen icon that opens \(label) in WebSpace.",
      "PayloadOrganization": "WebSpace",
      "PayloadRemovalDisallowed": false,
    ]
    return try? PropertyListSerialization.data(
      fromPropertyList: profile, format: .xml, options: 0)
  }

  private func serveAndOpen() -> Bool {
    let params = NWParameters.tcp
    params.requiredInterfaceType = .loopback
    guard let listener = try? NWListener(using: params) else { return false }
    self.listener = listener

    bgTask = UIApplication.shared.beginBackgroundTask(withName: "webclip-install") {
      [weak self] in self?.teardown()
    }

    listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
    listener.stateUpdateHandler = { [weak self] state in
      guard let self = self else { return }
      switch state {
      case .ready:
        guard
          let port = self.listener?.port?.rawValue,
          let url = URL(string: "http://127.0.0.1:\(port)/webspace.mobileconfig")
        else {
          self.teardown()
          return
        }
        DispatchQueue.main.async {
          UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
      case .failed, .cancelled:
        self.teardown()
      default:
        break
      }
    }
    listener.start(queue: .global(qos: .userInitiated))

    // Safety net: reclaim the listener + background assertion if Safari
    // never connects (user dismissed the download prompt, etc.).
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
      self?.teardown()
    }
    return true
  }

  private func handle(_ conn: NWConnection) {
    conn.start(queue: .global(qos: .userInitiated))
    // Drain (and ignore) the request line/headers, then respond once.
    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] _, _, _, _ in
      guard let self = self else {
        conn.cancel()
        return
      }
      let header =
        "HTTP/1.1 200 OK\r\n"
        + "Content-Type: application/x-apple-aspen-config\r\n"
        + "Content-Disposition: attachment; filename=\"webspace.mobileconfig\"\r\n"
        + "Content-Length: \(self.profileData.count)\r\n"
        + "Connection: close\r\n\r\n"
      var payload = Data(header.utf8)
      payload.append(self.profileData)
      conn.send(
        content: payload,
        completion: .contentProcessed { _ in
          conn.cancel()
          self.teardown()
        })
    }
  }

  private func teardown() {
    listener?.cancel()
    listener = nil
    if bgTask != .invalid {
      UIApplication.shared.endBackgroundTask(bgTask)
      bgTask = .invalid
    }
  }
}

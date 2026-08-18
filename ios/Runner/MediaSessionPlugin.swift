import AVFoundation
import Flutter
import MediaPlayer
import UIKit

/// BGAUDIO-010 iOS bridge for
/// [`MediaSessionService`](../../lib/services/media_session_service.dart), the
/// counterpart of `MediaSessionPlugin.kt`. Dart calls `start`/`update` with the
/// playing site's metadata and `stop` to tear the session down; transport taps
/// travel back as `onTransport`, which Dart applies to the owning webview's
/// primary media element.
///
/// iOS previously left this to WebKit: it publishes its own Now Playing info
/// for whatever a page is playing. That is invisible to the app — nothing knew
/// the controls were up, nothing could clear them, and a play tap had no route
/// back into the page. Owning the Now Playing info and the remote commands
/// makes the surface ours for the sites the user opted in for.
///
/// All state is confined to the main queue: the channel handler already runs
/// there, and the remote-command targets — whose queue is not documented — hop
/// onto it before touching anything (BUG-007 — partially synchronized native
/// state is the recurring failure).
class MediaSessionPlugin: NSObject {
  private let channel: FlutterMethodChannel

  /// Handles for the targets we added, so teardown removes exactly ours and a
  /// second `start` cannot stack a duplicate handler per command.
  private var commandTargets: [(MPRemoteCommand, Any)] = []

  /// Whether we currently publish Now Playing info for a background-audio
  /// site. Gates the interruption recovery: an interruption that ends while
  /// the app owns nothing must not activate a session or ask a page to play.
  private var publishing = false

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(
      name: "org.codeberg.theoden8.webspace/media_session",
      binaryMessenger: messenger
    )
    super.init()
    self.channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    // An interruption (a call, Siri, another app taking the session) leaves
    // OUR session deactivated. Nothing re-activates it on its own, so without
    // this the audio never comes back and the transport controls keep reaching
    // a page whose engine has no session to play into — "I hit play and
    // nothing happens" (BGAUDIO-011).
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleMediaServicesReset(_:)),
      name: AVAudioSession.mediaServicesWereResetNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  /// AVAudioSession posts on an arbitrary queue; everything this plugin owns
  /// lives on main (BUG-007), so hop before reading or writing any of it.
  @objc private func handleInterruption(_ note: Notification) {
    guard let info = note.userInfo,
          let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    let options = AVAudioSession.InterruptionOptions(
      rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      switch type {
      case .began:
        self.reportSessionState("audio session interrupted")
      case .ended:
        guard self.publishing else {
          self.reportSessionState("interruption ended, nothing of ours playing")
          return
        }
        self.activateSession()
        self.reportSessionState("interruption ended, session re-activated")
        // `shouldResume` is the system saying the user expects playback back.
        if options.contains(.shouldResume) {
          self.channel.invokeMethod("onTransport", arguments: ["action": "play"])
        }
      @unknown default:
        break
      }
    }
  }

  /// The media server can die and restart; every session and Now Playing entry
  /// dies with it. Re-establish ours rather than looking alive with nothing
  /// behind it.
  @objc private func handleMediaServicesReset(_ note: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.publishing else { return }
      self.activateSession()
      self.reportSessionState("media services reset, session re-established")
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start", "update":
      let args = call.arguments as? [String: Any] ?? [:]
      startOrUpdate(
        title: args["title"] as? String ?? "",
        artist: args["artist"] as? String ?? "",
        album: args["album"] as? String ?? "",
        playing: args["playing"] as? Bool ?? false,
        artwork: (args["artwork"] as? FlutterStandardTypedData)?.data
      )
      result(nil)
    case "stop":
      stop()
      result(nil)
    case "isNotificationActive":
      // Read back from the OS rather than from a local flag: the point of
      // BGAUDIO-007's probe is to tell "we asked" from "it is on screen".
      result(MPNowPlayingInfoCenter.default().nowPlayingInfo != nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startOrUpdate(
    title: String,
    artist: String,
    album: String,
    playing: Bool,
    artwork: Data?
  ) {
    activateSession()

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: artist,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
    ]
    if !album.isEmpty {
      info[MPMediaItemPropertyAlbumTitle] = album
    }
    if let bytes = artwork, let image = UIImage(data: bytes) {
      info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in
        image
      }
    }
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = info
    center.playbackState = playing ? .playing : .paused
    publishing = true

    registerCommands()
  }

  private func stop() {
    publishing = false
    unregisterCommands()
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = nil
    center.playbackState = .stopped
    // The session is deliberately NOT deactivated here: another loaded site
    // may still be sounding in the foreground, and `setActive(false)` would
    // cut it. `BackgroundTaskService.setBackgroundAudioActive(false)` puts the
    // category back to `.ambient` (BGAUDIO-003), which is the posture that
    // matters once no background-audio site is loaded.
  }

  /// An ACTIVE `.playback` session is what keeps iOS from suspending the
  /// process once the app leaves the foreground, and what lets playback begin
  /// again from the background. Setting only the category (BGAUDIO-003) is not
  /// enough for either: the page stops when the app is suspended, and a play
  /// tap then resumes nothing. Called when the page reports playback, and
  /// before a play command is handed to the page — at that moment the session
  /// may have been torn down by the very suspension we are recovering from.
  private func activateSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default)
      try session.setActive(true)
    } catch {
      reportSessionState("activation failed", error: error)
    }
  }

  /// Send one non-sensitive line (no site name, URL or track metadata) into the
  /// app's own log. Whether the session is `.playback` and active at the moment
  /// audio dies is the fact that separates every candidate cause here, and it
  /// is invisible in a device console the user cannot easily export.
  private func reportSessionState(_ what: String, error: Error? = nil) {
    let session = AVAudioSession.sharedInstance()
    var message = "\(what) [category=\(session.category.rawValue) "
      + "otherAudio=\(session.isOtherAudioPlaying)]"
    if let error = error {
      message += " error=\(error.localizedDescription)"
    }
    channel.invokeMethod("onSessionState", arguments: ["message": message])
  }

  /// Play / pause / stop only, mirroring the Android notification's controls:
  /// next/previous have no universal web mechanism. `togglePlayPause` is
  /// deliberately left to WebKit — it registers its own targets for the media
  /// it plays, and a toggle handled twice cancels itself out, while a play or
  /// a pause handled twice is idempotent.
  private func registerCommands() {
    guard commandTargets.isEmpty else { return }
    let center = MPRemoteCommandCenter.shared()
    let commands: [(MPRemoteCommand, String)] = [
      (center.playCommand, "play"),
      (center.pauseCommand, "pause"),
      (center.stopCommand, "stop"),
    ]
    for (command, action) in commands {
      command.isEnabled = true
      let target = command.addTarget { [weak self] _ in
        // The command centre does not promise a queue, and a Flutter channel
        // must be spoken to from the platform (main) thread.
        DispatchQueue.main.async {
          guard let self = self else { return }
          // Before the page is asked to play, not after: WebKit cannot start
          // playback against an inactive session, and the tap that gets here
          // is usually the one meant to bring the app back from suspension.
          if action == "play" {
            self.activateSession()
          }
          self.channel.invokeMethod("onTransport", arguments: ["action": action])
        }
        return .success
      }
      commandTargets.append((command, target))
    }
  }

  private func unregisterCommands() {
    for (command, target) in commandTargets {
      command.removeTarget(target)
    }
    commandTargets.removeAll()
  }
}

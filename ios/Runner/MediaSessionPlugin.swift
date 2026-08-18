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

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(
      name: "org.codeberg.theoden8.webspace/media_session",
      binaryMessenger: messenger
    )
    super.init()
    self.channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
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
    // Only reached for a site whose page is (or just was) playing, so WebKit
    // has already taken audio focus — activating here does not interrupt
    // anyone who was not going to be interrupted anyway. It is what makes the
    // system attribute the Now Playing controls to us.
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default)
      try session.setActive(true)
    } catch {
      NSLog("MediaSessionPlugin: audio session activation failed: \(error)")
    }

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

    registerCommands()
  }

  private func stop() {
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
          self?.channel.invokeMethod("onTransport", arguments: ["action": action])
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

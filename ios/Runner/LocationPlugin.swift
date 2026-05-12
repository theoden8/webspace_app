import CoreLocation
import Flutter
import UIKit

/// Returns a single GPS fix from CLLocationManager. Permission is requested on
/// demand (When-In-Use). The Flutter side calls "getCurrentLocation"; this plugin
/// either resolves with a fix, or with a status describing why it could not.
class LocationPlugin: NSObject, CLLocationManagerDelegate {
  private let channel: FlutterMethodChannel
  private let locationManager = CLLocationManager()
  private var pendingResult: FlutterResult?
  private var timeoutWorkItem: DispatchWorkItem?
  private var pendingTimeoutSeconds: TimeInterval = 30
  // "fine" or "coarse" — selects desiredAccuracy when the next fix
  // starts. Defaults to fine for back-compat with callers that don't
  // pass the argument.
  private var pendingAccuracy: String = "fine"

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(
      name: "org.codeberg.theoden8.webspace/location",
      binaryMessenger: messenger
    )
    super.init()
    self.locationManager.delegate = self
    self.channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getCurrentLocation":
      if let args = call.arguments as? [String: Any] {
        if let ms = args["timeoutMs"] as? Int {
          pendingTimeoutSeconds = TimeInterval(ms) / 1000.0
        }
        if let acc = args["accuracy"] as? String {
          pendingAccuracy = acc
        }
      }
      requestLocation(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestLocation(result: @escaping FlutterResult) {
    if pendingResult != nil {
      result(["status": "error", "message": "Another location request is already in progress."])
      return
    }
    if !CLLocationManager.locationServicesEnabled() {
      result(["status": "service_disabled", "message": "Location services are disabled."])
      return
    }
    let status: CLAuthorizationStatus
    if #available(iOS 14.0, *) {
      status = locationManager.authorizationStatus
    } else {
      status = CLLocationManager.authorizationStatus()
    }
    switch status {
    case .notDetermined:
      pendingResult = result
      locationManager.requestWhenInUseAuthorization()
    case .denied:
      result(["status": "permission_denied_forever",
              "message": "Location permission was denied. Enable it in Settings."])
    case .restricted:
      result(["status": "permission_denied_forever",
              "message": "Location access is restricted on this device."])
    case .authorizedAlways, .authorizedWhenInUse:
      pendingResult = result
      startSingleFix()
    @unknown default:
      result(["status": "error", "message": "Unknown authorization status."])
    }
  }

  private func startSingleFix() {
    // Set desiredAccuracy per the caller's request. CoreLocation uses
    // this as a hint to decide whether to power up the GPS chip:
    // kCLLocationAccuracyKilometer / kCLLocationAccuracyThreeKilometers
    // can be served entirely from cell-tower / Wi-Fi positioning, so
    // coarse mode never spins up GPS even if the user has granted full
    // (Precise) location authorization. This is the iOS equivalent of
    // routing through Android's NETWORK_PROVIDER for coarse.
    if pendingAccuracy == "coarse" {
      locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    } else {
      locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, let pending = self.pendingResult else { return }
      self.pendingResult = nil
      self.locationManager.stopUpdatingLocation()
      pending(["status": "timeout", "message": "Timed out waiting for a location fix."])
    }
    timeoutWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + pendingTimeoutSeconds, execute: work)
    locationManager.requestLocation()
  }

  // MARK: CLLocationManagerDelegate

  func locationManager(_ manager: CLLocationManager,
                       didChangeAuthorization status: CLAuthorizationStatus) {
    handleAuthChange(status: status)
  }

  @available(iOS 14.0, *)
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    handleAuthChange(status: manager.authorizationStatus)
  }

  private func handleAuthChange(status: CLAuthorizationStatus) {
    guard let pending = pendingResult else { return }
    switch status {
    case .authorizedAlways, .authorizedWhenInUse:
      startSingleFix()
    case .denied, .restricted:
      pendingResult = nil
      pending(["status": "permission_denied",
               "message": "Location permission was not granted."])
    case .notDetermined:
      // System is still deciding (modal still up); wait for next callback.
      break
    @unknown default:
      pendingResult = nil
      pending(["status": "error", "message": "Unknown authorization status."])
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let pending = pendingResult, let loc = locations.last else { return }
    pendingResult = nil
    timeoutWorkItem?.cancel()
    timeoutWorkItem = nil
    pending([
      "status": "ok",
      "latitude": loc.coordinate.latitude,
      "longitude": loc.coordinate.longitude,
      "accuracy": loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : 0,
    ])
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard let pending = pendingResult else { return }
    pendingResult = nil
    timeoutWorkItem?.cancel()
    timeoutWorkItem = nil
    pending(["status": "error", "message": error.localizedDescription])
  }
}

// Stand-in for ImageIO, as much as macos/Runner/ScreenSharePlugin.swift
// touches. CGImageDestination.h: kCGImageDestinationLossyCompressionQuality,
// a CFString, which the plugin reads `as String`.

public let kCGImageDestinationLossyCompressionQuality: String =
  "kCGImageDestinationLossyCompressionQuality"

// Stand-in for CoreVideo, as much as macos/Runner/ScreenSharePlugin.swift
// touches, so it type-checks on Linux. Shapes from CVBuffer.h, CVPixelBuffer.h
// and MacTypes.h; see stub_FlutterMacOS.swift for what a stub can and cannot
// catch.

import Foundation

// MacTypes.h: typedef FourCharCode OSType; typedef UInt32 FourCharCode;
public typealias OSType = UInt32

// CVBuffer.h: CVBufferRef is a CF type; CVImageBuffer.h and CVPixelBuffer.h
// typedef CVImageBufferRef and CVPixelBufferRef to it.
public final class CVBuffer {}
public typealias CVImageBuffer = CVBuffer
public typealias CVPixelBuffer = CVImageBuffer

// CVPixelBuffer.h: kCVPixelFormatType_32BGRA = 'BGRA'
public let kCVPixelFormatType_32BGRA: OSType = 0x4247_5241

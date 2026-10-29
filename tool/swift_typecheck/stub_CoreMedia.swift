// Stand-in for CoreMedia, as much as macos/Runner/ScreenSharePlugin.swift
// touches. Shapes from CMTime.h and CMSampleBuffer.h.

import CoreVideo
import Foundation

public typealias CMTimeValue = Int64
public typealias CMTimeScale = Int32

// CMTime.h; the Swift overlay adds init(value:timescale:).
public struct CMTime {
  public init(value: CMTimeValue, timescale: CMTimeScale) {}
}

// CMSampleBuffer.h: CMSampleBufferRef is a CF type.
public final class CMSampleBuffer {}

// CVImageBufferRef CMSampleBufferGetImageBuffer(CMSampleBufferRef sbuf);
public func CMSampleBufferGetImageBuffer(_ sbuf: CMSampleBuffer) -> CVImageBuffer? { nil }

// CFArrayRef CMSampleBufferGetSampleAttachmentsArray(CMSampleBufferRef sbuf,
//     Boolean createIfNecessary); a CFArray, bridged here as NSArray.
public func CMSampleBufferGetSampleAttachmentsArray(
  _ sbuf: CMSampleBuffer, createIfNecessary: Bool
) -> NSArray? { nil }

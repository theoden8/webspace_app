// Stand-in for CoreImage (and the CoreGraphics colour space it takes), as
// much as macos/Runner/ScreenSharePlugin.swift touches. Shapes from CIImage.h,
// CIContext.h and CGColorSpace.h; CFString constants are Strings here.

import CoreVideo
import Foundation

// CGColorSpace.h: CGColorSpaceCreateWithName, imported as init?(name:);
// kCGColorSpaceSRGB, imported as CGColorSpace.sRGB.
public final class CGColorSpace {
  public init?(name: String) {}
  public static let sRGB = "kCGColorSpaceSRGB"
}

// CIImage.h: - (instancetype)initWithCVPixelBuffer:(CVPixelBufferRef)pixelBuffer;
public class CIImage: NSObject {
  public init(cvPixelBuffer pixelBuffer: CVPixelBuffer) {}
}

// CIContext.h: typedef NSString *CIImageRepresentationOption NS_TYPED_ENUM;
public struct CIImageRepresentationOption: Hashable, RawRepresentable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

// CIContext.h:
// - (nullable NSData*)JPEGRepresentationOfImage:(CIImage*)image
//     colorSpace:(CGColorSpaceRef)colorSpace
//     options:(NSDictionary<CIImageRepresentationOption, id>*)options;
public class CIContext: NSObject {
  public override init() {}
  public func jpegRepresentation(
    of image: CIImage, colorSpace: CGColorSpace,
    options: [CIImageRepresentationOption: Any] = [:]
  ) -> Data? { nil }
}

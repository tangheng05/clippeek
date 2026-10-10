import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Thumbnail {
    /// A small PNG for the history grid; ImageIO decodes only what it needs.
    public static func make(from data: Data, maxPixels: Int = 256) -> Data? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return png(image)
    }

    /// The first frame of a video, as the same small PNG.
    public static func make(fromVideo url: URL, maxPixels: Int = 256) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return png(image)
    }

    private static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

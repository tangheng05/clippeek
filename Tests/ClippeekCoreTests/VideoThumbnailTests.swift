import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import ClippeekCore

@Suite struct VideoThumbnailTests {
    /// A one-second 320×240 movie, written frame by frame.
    func writeMovie(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(adaptor.pixelBufferPool)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            #expect(adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    @Test func firstFrameIsSmall() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "clippeek-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeMovie(to: url)
        let thumbnail = try #require(await Thumbnail.make(fromVideo: url))
        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let size = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(size[kCGImagePropertyPixelWidth] as? Int == 256)
        #expect(size[kCGImagePropertyPixelHeight] as? Int == 192)
    }

    @Test func notAVideoGivesNothing() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "clippeek-\(UUID().uuidString).mov")
        try Data("not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await Thumbnail.make(fromVideo: url) == nil)
    }
}

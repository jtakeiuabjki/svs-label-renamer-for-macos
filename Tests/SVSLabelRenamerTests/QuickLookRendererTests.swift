import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SVSQuickLookCore

@Test func quickLookChoosesSmallestSafeLevelAtOrAboveTarget() {
    let levels = [
        SVSPreviewRenderer.PyramidLevel(index: 0, width: 100_000, height: 80_000),
        SVSPreviewRenderer.PyramidLevel(index: 1, width: 4_000, height: 3_000),
        SVSPreviewRenderer.PyramidLevel(index: 2, width: 1_600, height: 1_200)
    ]

    let selected = SVSPreviewRenderer.chooseOverviewLevel(
        from: levels,
        targetDimension: 2_048
    )

    #expect(selected?.index == 1)
}

@Test func quickLookFallsBackToLargestSafeSmallLevel() {
    let levels = [
        SVSPreviewRenderer.PyramidLevel(index: 0, width: 40_000, height: 30_000),
        SVSPreviewRenderer.PyramidLevel(index: 1, width: 1_600, height: 1_200),
        SVSPreviewRenderer.PyramidLevel(index: 2, width: 800, height: 600)
    ]

    let selected = SVSPreviewRenderer.chooseOverviewLevel(
        from: levels,
        targetDimension: 2_048
    )

    #expect(selected?.index == 1)
}

@Test func quickLookSkipsLevelsAboveMemoryLimit() {
    let levels = [
        SVSPreviewRenderer.PyramidLevel(index: 0, width: 5_000, height: 5_000),
        SVSPreviewRenderer.PyramidLevel(index: 1, width: 2_000, height: 2_000)
    ]

    let selected = SVSPreviewRenderer.chooseOverviewLevel(
        from: levels,
        targetDimension: 2_048
    )

    #expect(selected?.index == 1)
}

@Test func quickLookRendersOptionalSampleAsBoundedPNG() throws {
    guard let path = ProcessInfo.processInfo.environment["SVS_SAMPLE"],
          FileManager.default.fileExists(atPath: path) else {
        return
    }
    let libraryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".vendor/openslide/lib/libopenslide.1.dylib")
    let data = try SVSPreviewRenderer.renderPreviewData(
        from: URL(fileURLWithPath: path),
        libraryURL: libraryURL
    )
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else {
        Issue.record("Quick Look preview is not a readable PNG")
        return
    }

    #expect(max(width, height) <= SVSPreviewRenderer.defaultMaximumDimension)
    #expect(width > 0 && height > 0)
}

import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum SVSPreviewError: LocalizedError {
    case openSlideUnavailable
    case cannotOpenSlide
    case previewUnavailable
    case invalidDimensions
    case renderingFailed(String)
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .openSlideUnavailable:
            "SVSを読み込むためのOpenSlideが見つかりません"
        case .cannotOpenSlide:
            "SVSファイルを開けません"
        case .previewUnavailable:
            "このSVSには表示できる低倍率画像がありません"
        case .invalidDimensions:
            "SVSの画像サイズが不正です"
        case .renderingFailed(let message):
            "SVSのプレビュー生成に失敗しました: \(message)"
        case .encodingFailed:
            "SVSのプレビュー画像を書き出せません"
        }
    }
}

public struct SVSPreviewRenderer {
    public static let defaultMaximumDimension = 2048
    static let maximumSourcePixels = 16_000_000

    struct PyramidLevel: Equatable {
        let index: Int32
        let width: Int
        let height: Int

        var maximumDimension: Int { max(width, height) }
        var pixelCount: Int {
            let (count, overflow) = width.multipliedReportingOverflow(by: height)
            return overflow ? .max : count
        }
    }

    public static func renderPreviewData(
        from sourceURL: URL,
        maximumDimension: Int = defaultMaximumDimension,
        libraryURL: URL? = nil
    ) throws -> Data {
        guard maximumDimension > 0 else { throw SVSPreviewError.invalidDimensions }
        let library = try OpenSlideLibrary(explicitURL: libraryURL)

        let sourceImage: CGImage
        do {
            sourceImage = try library.readPyramidOverview(
                from: sourceURL,
                targetDimension: maximumDimension
            )
        } catch {
            sourceImage = try library.readAssociatedThumbnail(from: sourceURL)
        }

        let previewImage = try resize(
            sourceImage,
            maximumDimension: maximumDimension
        )
        return try encodePNG(previewImage)
    }

    static func chooseOverviewLevel(
        from levels: [PyramidLevel],
        targetDimension: Int,
        maximumPixels: Int = maximumSourcePixels
    ) -> PyramidLevel? {
        let safeLevels = levels.filter {
            $0.width > 0 &&
            $0.height > 0 &&
            $0.pixelCount <= maximumPixels
        }
        let largeEnough = safeLevels.filter {
            $0.maximumDimension >= targetDimension
        }
        if let closest = largeEnough.min(by: {
            $0.maximumDimension < $1.maximumDimension
        }) {
            return closest
        }
        return safeLevels.max(by: {
            $0.maximumDimension < $1.maximumDimension
        })
    }

    private static func resize(
        _ image: CGImage,
        maximumDimension: Int
    ) throws -> CGImage {
        let sourceMaximum = max(image.width, image.height)
        guard sourceMaximum > maximumDimension else { return image }

        let scale = Double(maximumDimension) / Double(sourceMaximum)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw SVSPreviewError.renderingFailed("描画領域を作成できません")
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else {
            throw SVSPreviewError.renderingFailed("画像を作成できません")
        }
        return resized
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw SVSPreviewError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SVSPreviewError.encodingFailed
        }
        return output as Data
    }
}

private final class OpenSlideLibrary {
    private typealias OpenFunction =
        @convention(c) (UnsafePointer<CChar>) -> OpaquePointer?
    private typealias CloseFunction =
        @convention(c) (OpaquePointer) -> Void
    private typealias ErrorFunction =
        @convention(c) (OpaquePointer) -> UnsafePointer<CChar>?
    private typealias LevelCountFunction =
        @convention(c) (OpaquePointer) -> Int32
    private typealias LevelDimensionsFunction =
        @convention(c) (
            OpaquePointer,
            Int32,
            UnsafeMutablePointer<Int64>,
            UnsafeMutablePointer<Int64>
        ) -> Void
    private typealias ReadRegionFunction =
        @convention(c) (
            OpaquePointer,
            UnsafeMutablePointer<UInt32>?,
            Int64,
            Int64,
            Int32,
            Int64,
            Int64
        ) -> Void
    private typealias AssociatedDimensionsFunction =
        @convention(c) (
            OpaquePointer,
            UnsafePointer<CChar>,
            UnsafeMutablePointer<Int64>,
            UnsafeMutablePointer<Int64>
        ) -> Void
    private typealias ReadAssociatedFunction =
        @convention(c) (
            OpaquePointer,
            UnsafePointer<CChar>,
            UnsafeMutablePointer<UInt32>?
        ) -> Void

    private let handle: UnsafeMutableRawPointer
    private let openSlide: OpenFunction
    private let closeSlide: CloseFunction
    private let getError: ErrorFunction
    private let getLevelCount: LevelCountFunction
    private let getLevelDimensions: LevelDimensionsFunction
    private let readRegion: ReadRegionFunction
    private let getAssociatedDimensions: AssociatedDimensionsFunction
    private let readAssociated: ReadAssociatedFunction

    init(explicitURL: URL?) throws {
        guard let libraryURL = Self.locateLibrary(explicitURL: explicitURL),
              let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw SVSPreviewError.openSlideUnavailable
        }
        self.handle = handle
        do {
            openSlide = try Self.symbol("openslide_open", in: handle)
            closeSlide = try Self.symbol("openslide_close", in: handle)
            getError = try Self.symbol("openslide_get_error", in: handle)
            getLevelCount = try Self.symbol("openslide_get_level_count", in: handle)
            getLevelDimensions = try Self.symbol(
                "openslide_get_level_dimensions",
                in: handle
            )
            readRegion = try Self.symbol("openslide_read_region", in: handle)
            getAssociatedDimensions = try Self.symbol(
                "openslide_get_associated_image_dimensions",
                in: handle
            )
            readAssociated = try Self.symbol(
                "openslide_read_associated_image",
                in: handle
            )
        } catch {
            dlclose(handle)
            throw error
        }
    }

    deinit {
        dlclose(handle)
    }

    func readPyramidOverview(
        from sourceURL: URL,
        targetDimension: Int
    ) throws -> CGImage {
        try withSlide(at: sourceURL) { slide in
            let count = getLevelCount(slide)
            guard count > 0 else { throw SVSPreviewError.previewUnavailable }

            var levels: [SVSPreviewRenderer.PyramidLevel] = []
            for index in 0..<count {
                var width: Int64 = 0
                var height: Int64 = 0
                getLevelDimensions(slide, index, &width, &height)
                guard width > 0, height > 0,
                      width <= Int64(Int.max), height <= Int64(Int.max) else {
                    continue
                }
                levels.append(.init(
                    index: index,
                    width: Int(width),
                    height: Int(height)
                ))
            }
            guard let level = SVSPreviewRenderer.chooseOverviewLevel(
                from: levels,
                targetDimension: targetDimension
            ) else {
                throw SVSPreviewError.previewUnavailable
            }

            var pixels = [UInt32](repeating: 0, count: level.pixelCount)
            pixels.withUnsafeMutableBufferPointer { buffer in
                readRegion(
                    slide,
                    buffer.baseAddress,
                    0,
                    0,
                    level.index,
                    Int64(level.width),
                    Int64(level.height)
                )
            }
            try throwIfSlideFailed(slide)
            return try Self.makeImage(
                pixels: pixels,
                width: level.width,
                height: level.height
            )
        }
    }

    func readAssociatedThumbnail(from sourceURL: URL) throws -> CGImage {
        try withSlide(at: sourceURL) { slide in
            var width: Int64 = -1
            var height: Int64 = -1
            "thumbnail".withCString { name in
                getAssociatedDimensions(slide, name, &width, &height)
            }
            guard width > 0, height > 0,
                  width <= Int64(Int.max), height <= Int64(Int.max) else {
                throw SVSPreviewError.previewUnavailable
            }

            let integerWidth = Int(width)
            let integerHeight = Int(height)
            let (pixelCount, overflow) = integerWidth.multipliedReportingOverflow(
                by: integerHeight
            )
            guard !overflow, pixelCount <= SVSPreviewRenderer.maximumSourcePixels else {
                throw SVSPreviewError.invalidDimensions
            }

            var pixels = [UInt32](repeating: 0, count: pixelCount)
            pixels.withUnsafeMutableBufferPointer { buffer in
                "thumbnail".withCString { name in
                    readAssociated(slide, name, buffer.baseAddress)
                }
            }
            try throwIfSlideFailed(slide)
            return try Self.makeImage(
                pixels: pixels,
                width: integerWidth,
                height: integerHeight
            )
        }
    }

    private func withSlide<T>(
        at sourceURL: URL,
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }

        guard let slide = sourceURL.path.withCString({ openSlide($0) }) else {
            throw SVSPreviewError.cannotOpenSlide
        }
        defer { closeSlide(slide) }
        try throwIfSlideFailed(slide)
        return try body(slide)
    }

    private func throwIfSlideFailed(_ slide: OpaquePointer) throws {
        guard let message = getError(slide) else { return }
        throw SVSPreviewError.renderingFailed(String(cString: message))
    }

    private static func makeImage(
        pixels: [UInt32],
        width: Int,
        height: Int
    ) throws -> CGImage {
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw SVSPreviewError.renderingFailed("画素データを読み込めません")
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = [
            .byteOrder32Little,
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        ]
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw SVSPreviewError.renderingFailed("画像を作成できません")
        }
        return image
    }

    private static func locateLibrary(explicitURL: URL?) -> URL? {
        let manager = FileManager.default
        var candidates: [URL] = []
        if let explicitURL {
            candidates.append(explicitURL)
        }
        if let environmentPath = ProcessInfo.processInfo.environment[
            "OPENSLIDE_LIBRARY_PATH"
        ] {
            candidates.append(URL(fileURLWithPath: environmentPath))
        }
        if let frameworksURL = Bundle.main.privateFrameworksURL {
            candidates.append(
                frameworksURL.appendingPathComponent("libopenslide.1.dylib")
            )
        }
        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Frameworks/libopenslide.1.dylib")
        )
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".vendor/openslide/lib/libopenslide.1.dylib")
        )
        candidates.append(
            URL(fileURLWithPath: "/opt/homebrew/lib/libopenslide.1.dylib")
        )
        candidates.append(
            URL(fileURLWithPath: "/usr/local/lib/libopenslide.1.dylib")
        )
        return candidates.first {
            manager.fileExists(atPath: $0.path)
        }
    }

    private static func symbol<T>(
        _ name: String,
        in handle: UnsafeMutableRawPointer
    ) throws -> T {
        guard let pointer = dlsym(handle, name) else {
            let detail = dlerror().map { String(cString: $0) } ?? name
            throw SVSPreviewError.renderingFailed(detail)
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}

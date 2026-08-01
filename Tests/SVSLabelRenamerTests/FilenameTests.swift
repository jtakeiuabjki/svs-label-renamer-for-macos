import CoreGraphics
import Testing
@testable import SVSLabelRenamer

private func positionedText(
    _ text: String,
    x: CGFloat = 0.25,
    y: CGFloat,
    width: CGFloat = 0.30,
    height: CGFloat = 0.08,
    confidence: Float = 0.95
) -> OCRTextObservation {
    OCRTextObservation(
        text: text,
        confidence: confidence,
        boundingBox: CGRect(x: x, y: y, width: width, height: height)
    )
}

@Test func filenameWithOptionalBlock() {
    #expect(FilenameBuilder.make(pathology: "K1234", block: "", stain: "CD163") == "K1234_CD163")
    #expect(FilenameBuilder.make(pathology: "K1234", block: "2", stain: "CD68") == "K1234_2_CD68")
}

@Test func unsafeCharactersAreRemoved() {
    #expect(FilenameBuilder.make(pathology: " K 123 ", block: "A/2", stain: "H&E") == "K123_A2_HE")
}

@Test func parsesPathologyBlockAndLongestStain() {
    let parsed = OCRService.parse(["K1234", "2", "CD31"])
    #expect(parsed.pathology == "K1234")
    #expect(parsed.block == "2")
    #expect(parsed.stain == "CD31")
}

@Test func correctsCloseStainAndPrefersShortPathologyIdentifier() {
    let parsed = OCRService.parse(["KP17-99999", "K599", "C0163"])
    #expect(parsed.pathology == "K599")
    #expect(parsed.stain == "CD163")
}

@Test func doesNotTreatHER2AsHE() {
    let parsed = OCRService.parse(["K200", "HER2"])
    #expect(parsed.stain == "HER2")
}

@Test func positionlessParsingKeepsLegacyPathologyPreference() {
    let parsed = OCRService.parse(["KP00-00000", "KX00", "VEGFA"])
    #expect(parsed.pathology == "KX00")
    #expect(parsed.stain == "VEGFA")
}

@Test func spatialLayoutPrefersPrintedPathologyNearTopEdge() {
    let parsed = OCRService.parse([
        positionedText("KP00-00000", x: 0.05, y: 0.84, width: 0.82),
        positionedText("KX00", y: 0.50, width: 0.24),
        positionedText("VEGFA", y: 0.25, width: 0.32),
    ])

    #expect(parsed.pathology == "KP00-00000")
    #expect(parsed.stain == "VEGFA")
}

@Test func spatialParsingDoesNotDependOnVisionObservationOrder() {
    let observations = [
        positionedText("KP00-00000", x: 0.05, y: 0.84, width: 0.82),
        positionedText("KX00", y: 0.50, width: 0.24),
        positionedText("VEGFA", y: 0.25, width: 0.32),
    ]
    let ordered = OCRService.parse(observations)
    let shuffled = OCRService.parse([observations[2], observations[0], observations[1]])

    #expect(ordered.pathology == "KP00-00000")
    #expect(shuffled.pathology == ordered.pathology)
    #expect(shuffled.block == ordered.block)
    #expect(shuffled.stain == ordered.stain)
    #expect(shuffled.raw == "KP00-00000 | KX00 | VEGFA")
}

@Test func correctsCO68ToCD68OnlyInLowerStainRegion() {
    let parsed = OCRService.parse([
        positionedText("K1234", y: 0.68),
        positionedText("CO68", y: 0.24),
    ])

    #expect(parsed.pathology == "K1234")
    #expect(parsed.stain == "CD68")
}

@Test func doesNotCorrectCO68InUpperLabelRegion() {
    let parsed = OCRService.parse([
        positionedText("K1234", y: 0.91),
        positionedText("CO68", y: 0.80),
    ])

    #expect(parsed.pathology == "K1234")
    #expect(parsed.stain.isEmpty)
}

@Test func leavesAmbiguousLowerCD63Unconfirmed() {
    let parsed = OCRService.parse([
        positionedText("K1234", y: 0.68),
        positionedText("CD63", y: 0.24),
    ])

    #expect(parsed.pathology == "K1234")
    #expect(parsed.stain.isEmpty)
}

@Test func doesNotApplyTwoCharacterStainCorrectionAutomatically() {
    let parsed = OCRService.parse([
        positionedText("K1234", y: 0.68),
        positionedText("VECIFA", y: 0.24),
    ])

    #expect(parsed.pathology == "K1234")
    #expect(parsed.stain.isEmpty)
}

@Test func invalidBoundingBoxesUseLegacyParsingRules() {
    let parsed = OCRService.parse([
        OCRTextObservation(
            text: "KP00-00000",
            boundingBox: CGRect(x: .nan, y: 0, width: 0.3, height: 0.1)
        ),
        OCRTextObservation(text: "KX00", boundingBox: .zero),
        OCRTextObservation(
            text: "C0163",
            boundingBox: CGRect(x: -0.2, y: 0.1, width: 0.1, height: 0.1)
        ),
    ])

    #expect(parsed.pathology == "KX00")
    #expect(parsed.stain == "CD163")
    #expect(parsed.raw == "KP00-00000 | KX00 | C0163")
}

@Test func bestOrientationPrefersTopEdgePathologyAndLowerStain() {
    let upright = [
        positionedText("KP00-00000", x: 0.05, y: 0.84, width: 0.82),
        positionedText("KX00", y: 0.50, width: 0.24),
        positionedText("CD68", y: 0.24),
    ]
    let upsideDown = [
        positionedText("CD68", y: 0.68),
        positionedText("KX00", y: 0.42, width: 0.24),
        positionedText("KP00-00000", x: 0.05, y: 0.08, width: 0.82),
    ]

    let parsed = OCRService.parseBestOrientation([upsideDown, upright])

    #expect(parsed?.pathology == "KP00-00000")
    #expect(parsed?.stain == "CD68")
    #expect(parsed?.raw == "KP00-00000 | KX00 | CD68")
}

@Test func spatialParsingFindsBlockBetweenPathologyAndStain() {
    let parsed = OCRService.parse([
        positionedText("CD163", y: 0.20),
        positionedText("2", y: 0.44, width: 0.08),
        positionedText("KP00-00000", x: 0.05, y: 0.84, width: 0.82),
    ])

    #expect(parsed.pathology == "KP00-00000")
    #expect(parsed.block == "2")
    #expect(parsed.stain == "CD163")
    #expect(parsed.raw == "KP00-00000 | 2 | CD163")
}

@Test func blockOnSameOCRLineUsesReadingOrderFallback() {
    let sharedLine = CGRect(x: 0.25, y: 0.58, width: 0.34, height: 0.09)
    let parsed = OCRService.parse([
        OCRTextObservation(text: "K1234 2", boundingBox: sharedLine),
        positionedText("CD163", y: 0.20),
    ])

    #expect(parsed.pathology == "K1234")
    #expect(parsed.block == "2")
    #expect(parsed.stain == "CD163")
}

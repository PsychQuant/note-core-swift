import XCTest
@testable import NoteCore

final class NoteParserLogicalPageHeightTests: XCTestCase {

    // MARK: - Letter portrait

    func testLetterPortrait_iPadLogicalWidth() {
        // Notability iPad logical width = 583.8 pt (from paperSizingBehavior lockedWidth:583.8:iPad)
        // Letter aspect ratio = 792/612 = 1.2941
        // Expected logical height = 583.8 * 1.2941 ≈ 755.5
        let h = NoteParser.logicalPageHeight(
            paperSize: "letter",
            paperOrientation: "portrait",
            pageWidth: 583.8
        )
        XCTAssertNotNil(h)
        XCTAssertEqual(h!, 583.8 * (792.0 / 612.0), accuracy: 0.01)
    }

    func testLetterPortrait_caseInsensitive() {
        let h1 = NoteParser.logicalPageHeight(paperSize: "Letter", paperOrientation: "Portrait", pageWidth: 583.8)
        let h2 = NoteParser.logicalPageHeight(paperSize: "LETTER", paperOrientation: "PORTRAIT", pageWidth: 583.8)
        let h3 = NoteParser.logicalPageHeight(paperSize: "letter", paperOrientation: "portrait", pageWidth: 583.8)
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h2, h3)
    }

    // MARK: - A4 portrait

    func testA4Portrait() {
        // A4 aspect ratio = 841.68/595.2 ≈ √2
        let h = NoteParser.logicalPageHeight(
            paperSize: "A4",
            paperOrientation: "portrait",
            pageWidth: 583.8
        )
        XCTAssertNotNil(h)
        XCTAssertEqual(h!, 583.8 * (841.68 / 595.2), accuracy: 0.01)
    }

    // MARK: - Landscape

    func testLetterLandscape() {
        // Landscape → height < width (inverse ratio)
        let h = NoteParser.logicalPageHeight(
            paperSize: "letter",
            paperOrientation: "landscape",
            pageWidth: 583.8
        )
        XCTAssertNotNil(h)
        XCTAssertEqual(h!, 583.8 / (792.0 / 612.0), accuracy: 0.01)
        XCTAssertLessThan(h!, 583.8)
    }

    // MARK: - Fallback

    func testUnknownSizeReturnsNil() {
        let h = NoteParser.logicalPageHeight(
            paperSize: "customWidth",
            paperOrientation: "portrait",
            pageWidth: 583.8
        )
        XCTAssertNil(h, "Unknown paper size should return nil so caller can fallback to heuristic")
    }

    func testNilPaperSizeReturnsNil() {
        let h = NoteParser.logicalPageHeight(
            paperSize: nil,
            paperOrientation: "portrait",
            pageWidth: 583.8
        )
        XCTAssertNil(h)
    }

    // MARK: - Orientation defaults

    func testMissingOrientationDefaultsToPortrait() {
        let h = NoteParser.logicalPageHeight(
            paperSize: "letter",
            paperOrientation: nil,
            pageWidth: 583.8
        )
        XCTAssertNotNil(h)
        // Default should be portrait (height > width for portrait papers)
        XCTAssertGreaterThan(h!, 583.8)
    }
}

final class NoteParserHeuristicPageBoundsTests: XCTestCase {

    // MARK: - Realistic case (matches Wei .note debug data)

    func testRealisticCase_5pages_nonZeroMinY() {
        // Debug data from actual Wei .note (see #77 scope-guard comment):
        // bounds.minY = 1146.02, bounds.maxY = 9075.37, pageCount = 5
        let bounds = StrokeBounds(minX: -3.68, minY: 1146.02, maxX: 552.25, maxY: 9075.37)
        let result = NoteParser.heuristicPageBounds(bounds: bounds, pageCount: 5)

        // pageYOffset = minY (skip empty region above first stroke)
        XCTAssertEqual(result.pageYOffset, 1146.02, accuracy: 0.01)

        // pageHeight = (maxY - minY) / pageCount = 7929.35 / 5 = 1585.87
        XCTAssertEqual(result.pageHeight, (9075.37 - 1146.02) / 5.0, accuracy: 0.01)
    }

    // MARK: - Edge cases

    func testSinglePage() {
        let bounds = StrokeBounds(minX: 0, minY: 100, maxX: 500, maxY: 800)
        let result = NoteParser.heuristicPageBounds(bounds: bounds, pageCount: 1)

        XCTAssertEqual(result.pageYOffset, 100, accuracy: 0.01)
        XCTAssertEqual(result.pageHeight, 700, accuracy: 0.01)  // maxY - minY
    }

    func testZeroMinY() {
        // If bounds.minY is 0, pageYOffset is 0 (fix degrades to same behavior as old)
        let bounds = StrokeBounds(minX: 0, minY: 0, maxX: 500, maxY: 5000)
        let result = NoteParser.heuristicPageBounds(bounds: bounds, pageCount: 5)

        XCTAssertEqual(result.pageYOffset, 0, accuracy: 0.01)
        XCTAssertEqual(result.pageHeight, 1000, accuracy: 0.01)
    }

    func testPageCountZero_safeDefault() {
        // Divide-by-zero protection: pageCount=0 should not crash
        let bounds = StrokeBounds(minX: 0, minY: 0, maxX: 500, maxY: 1000)
        let result = NoteParser.heuristicPageBounds(bounds: bounds, pageCount: 0)

        XCTAssertGreaterThan(result.pageHeight, 0, "pageHeight must be positive to avoid divide-by-zero downstream")
    }

    func testNegativeMinY_clampedToZero() {
        // StrokeBounds could theoretically have negative minY.
        // pageYOffset should clamp to >= 0 for safety.
        let bounds = StrokeBounds(minX: -10, minY: -50, maxX: 500, maxY: 1000)
        let result = NoteParser.heuristicPageBounds(bounds: bounds, pageCount: 1)

        XCTAssertGreaterThanOrEqual(result.pageYOffset, 0, "pageYOffset should be clamped to >= 0")
    }
}

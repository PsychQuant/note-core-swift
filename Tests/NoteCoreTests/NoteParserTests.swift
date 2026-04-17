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

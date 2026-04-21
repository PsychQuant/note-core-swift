import XCTest
@testable import NoteCore

final class GutterDetectionTests: XCTestCase {

    /// Build `StrokeData` from per-page Y-value ranges.
    ///
    /// Each inner array becomes one Curve at a fixed X=100, with points sampled
    /// along the given Y range at 1-pt resolution. Enough density per page that
    /// `quietBandThreshold` filtering recognises pages as "dense" buckets.
    private func makeStrokes(_ perPageYRanges: [(start: Float, end: Float)]) -> StrokeData {
        var curves: [Curve] = []
        var allY: [Float] = []
        for range in perPageYRanges {
            var pts: [(x: Float, y: Float)] = []
            var y: Float = range.start
            while y <= range.end {
                pts.append((x: 100, y: y))
                allY.append(y)
                y += 1
            }
            curves.append(Curve(points: pts, color: 0xFF000000, width: 2, style: 0))
        }
        let minY = allY.min() ?? 0
        let maxY = allY.max() ?? 0
        let bounds = StrokeBounds(minX: 100, minY: minY, maxX: 100, maxY: maxY)
        return StrokeData(
            curves: curves,
            totalPoints: allY.count,
            bounds: bounds,
            curveUUIDs: []
        )
    }

    // MARK: - gutterDetection

    func testGutterDetection_threePagesWithClearGutters() {
        // Pages at [100-200], [300-400], [500-600] — two 100-pt gutters
        let strokes = makeStrokes([(100, 200), (300, 400), (500, 600)])
        let bounds = NoteParser.gutterDetection(strokes: strokes, pageCount: 3)

        XCTAssertEqual(bounds.count, 3, "expect pageCount bounds when all gutters found")
        XCTAssertEqual(bounds.map(\.documentPageNumber), [1, 2, 3])

        // Adjacent pages share boundary (continuous)
        XCTAssertEqual(bounds[0].yEnd, bounds[1].yStart, accuracy: 0.01)
        XCTAssertEqual(bounds[1].yEnd, bounds[2].yStart, accuracy: 0.01)

        // First page starts at minY, last page ends at maxY
        XCTAssertEqual(bounds[0].yStart, 100, accuracy: 0.01)
        XCTAssertEqual(bounds[2].yEnd, 600, accuracy: 0.01)

        // Gutter 1 midpoint (200-300 → ~250) should fall in [200, 300]
        XCTAssertGreaterThanOrEqual(bounds[0].yEnd, 200)
        XCTAssertLessThanOrEqual(bounds[0].yEnd, 300)
    }

    func testGutterDetection_returnsEmptyWhenNoGuttersFound() {
        // Single continuous drawing Y 0-1000 — no quiet bands
        let strokes = makeStrokes([(0, 1000)])
        let bounds = NoteParser.gutterDetection(strokes: strokes, pageCount: 3)
        XCTAssertTrue(bounds.isEmpty, "no qualifying gutters → empty (caller falls back)")
    }

    func testGutterDetection_returnsEmptyOnWrongGutterCount() {
        // 2 gutters present but pageCount = 5 → count mismatch
        let strokes = makeStrokes([(100, 200), (300, 400), (500, 600)])
        let bounds = NoteParser.gutterDetection(strokes: strokes, pageCount: 5)
        XCTAssertTrue(bounds.isEmpty, "need pageCount-1 gutters; 2 ≠ 4")
    }

    func testGutterDetection_returnsEmptyForZeroStrokes() {
        let bounds = NoteParser.gutterDetection(
            strokes: StrokeData.empty,
            pageCount: 3
        )
        XCTAssertTrue(bounds.isEmpty)
    }

    func testGutterDetection_returnsEmptyForSinglePage() {
        // pageCount=1 has no gutters to find by definition
        let strokes = makeStrokes([(100, 500)])
        let bounds = NoteParser.gutterDetection(strokes: strokes, pageCount: 1)
        XCTAssertTrue(bounds.isEmpty, "pageCount=1 returns empty immediately")
    }

    func testGutterDetection_narrowGutterDoesNotQualify() {
        // 10-pt gap between pages — below the default 40-pt minimum
        let strokes = makeStrokes([(100, 200), (210, 310)])
        let bounds = NoteParser.gutterDetection(strokes: strokes, pageCount: 2)
        XCTAssertTrue(
            bounds.isEmpty,
            "gutter narrower than minGutterHeight → disqualified → empty"
        )
    }

    // MARK: - evenSplitPageBounds

    func testEvenSplitPageBounds_populatesPageCountEntries() {
        let bounds = NoteParser.evenSplitPageBounds(
            pageYOffset: 100,
            pageHeight: 700,
            pageCount: 3
        )
        XCTAssertEqual(bounds.count, 3)
        XCTAssertEqual(bounds[0], PageBounds(yStart: 100, yEnd: 800, documentPageNumber: 1))
        XCTAssertEqual(bounds[1], PageBounds(yStart: 800, yEnd: 1500, documentPageNumber: 2))
        XCTAssertEqual(bounds[2], PageBounds(yStart: 1500, yEnd: 2200, documentPageNumber: 3))
    }

    func testEvenSplitPageBounds_returnsEmptyOnZeroPageCount() {
        let bounds = NoteParser.evenSplitPageBounds(
            pageYOffset: 0,
            pageHeight: 100,
            pageCount: 0
        )
        XCTAssertTrue(bounds.isEmpty)
    }

    func testEvenSplitPageBounds_returnsEmptyOnZeroPageHeight() {
        let bounds = NoteParser.evenSplitPageBounds(
            pageYOffset: 0,
            pageHeight: 0,
            pageCount: 3
        )
        XCTAssertTrue(bounds.isEmpty)
    }
}

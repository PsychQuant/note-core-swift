import Foundation

/// Decoded stroke data from a Notability handwriting overlay.
public struct StrokeData {
    public let curves: [Curve]
    public let totalPoints: Int
    public let bounds: StrokeBounds
    public let curveUUIDs: [Data]  // 16-byte UUID per curve, for timeline mapping

    public static let empty = StrokeData(curves: [], totalPoints: 0, bounds: StrokeBounds(minX: 0, minY: 0, maxX: 560, maxY: 730), curveUUIDs: [])
}

public struct StrokeBounds {
    public let minX: Float
    public let minY: Float
    public let maxX: Float
    public let maxY: Float
    public var width: Float { maxX - minX }
    public var height: Float { maxY - minY }
}

public struct Curve {
    public let points: [(x: Float, y: Float)]
    public let color: UInt32  // RGBA packed
    public let width: Float
    public let style: UInt8   // 0 = pen, etc.

    public var colorHex: String {
        let r = (color >> 0) & 0xFF
        let g = (color >> 8) & 0xFF
        let b = (color >> 16) & 0xFF
        let a = (color >> 24) & 0xFF
        if a == 255 {
            return String(format: "#%02x%02x%02x", r, g, b)
        }
        return String(format: "rgba(%d,%d,%d,%.2f)", r, g, b, Float(a) / 255.0)
    }

    public var colorAlpha: Float {
        Float((color >> 24) & 0xFF) / 255.0
    }
}

/// Decodes binary stroke buffers from Notability's plist format.
public struct StrokeDecoder {
    /// Decode stroke data from the Handwriting Overlay object.
    static func decode(from overlay: [String: Any], navigator: PlistNavigator) throws -> StrokeData {
        // Get numcurves
        let numCurves: Int
        if let numUID = navigator.uidValue(overlay["numcurves"]),
           let num = navigator.object(at: numUID) as? Int {
            numCurves = num
        } else if let num = overlay["numcurves"] as? Int {
            numCurves = num
        } else {
            return .empty
        }

        guard numCurves > 0 else { return .empty }

        // Extract raw Data buffers
        guard let pointsData = overlay["curvespoints"] as? Data,
              let numPointsData = overlay["curvesnumpoints"] as? Data,
              let colorsData = overlay["curvescolors"] as? Data,
              let widthData = overlay["curveswidth"] as? Data else {
            throw NoteError.invalidStrokeData("缺少必要的筆跡資料欄位")
        }

        let stylesData = overlay["curvesstyles"] as? Data

        // Decode typed arrays
        let points = decodeFloatArray(pointsData)       // x,y interleaved
        let numPoints = decodeUInt32Array(numPointsData) // points per curve
        let colors = decodeUInt32Array(colorsData)       // RGBA per curve
        let widths = decodeFloatArray(widthData)         // width per curve

        // Validate array counts
        guard numPoints.count >= numCurves,
              colors.count >= numCurves,
              widths.count >= numCurves else {
            throw NoteError.invalidStrokeData(
                "陣列長度不一致: numCurves=\(numCurves), numPoints=\(numPoints.count), colors=\(colors.count), widths=\(widths.count)"
            )
        }

        // Build curves
        var curves: [Curve] = []
        curves.reserveCapacity(numCurves)
        var pointOffset = 0

        for i in 0..<numCurves {
            let count = Int(numPoints[i])
            var curvePoints: [(x: Float, y: Float)] = []
            curvePoints.reserveCapacity(count)

            for j in 0..<count {
                let idx = (pointOffset + j) * 2
                guard idx + 1 < points.count else { break }
                curvePoints.append((x: points[idx], y: points[idx + 1]))
            }

            let style: UInt8
            if let stylesData = stylesData, i < stylesData.count {
                style = stylesData[i]
            } else {
                style = 0
            }

            curves.append(Curve(
                points: curvePoints,
                color: colors[i],
                width: widths[i],
                style: style
            ))

            pointOffset += count
        }

        // Compute bounds
        var bMinX: Float = .infinity, bMinY: Float = .infinity
        var bMaxX: Float = -.infinity, bMaxY: Float = -.infinity
        for curve in curves {
            for pt in curve.points {
                bMinX = min(bMinX, pt.x)
                bMinY = min(bMinY, pt.y)
                bMaxX = max(bMaxX, pt.x)
                bMaxY = max(bMaxY, pt.y)
            }
        }
        if curves.isEmpty {
            bMinX = 0; bMinY = 0; bMaxX = 560; bMaxY = 730
        }
        let bounds = StrokeBounds(minX: bMinX, minY: bMinY, maxX: bMaxX, maxY: bMaxY)

        // Extract curveUUIDs (16 bytes per UUID)
        var curveUUIDs: [Data] = []
        if let uuidData = overlay["curveUUIDs"] as? Data {
            let uuidSize = 16
            let uuidCount = uuidData.count / uuidSize
            for i in 0..<uuidCount {
                let start = i * uuidSize
                let end = start + uuidSize
                curveUUIDs.append(uuidData.subdata(in: start..<end))
            }
        }

        return StrokeData(curves: curves, totalPoints: pointOffset, bounds: bounds, curveUUIDs: curveUUIDs)
    }

    // MARK: - Binary Decoders

    private static func decodeFloatArray(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return [] }
            let floatBuffer = baseAddress.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: floatBuffer, count: count))
        }
    }

    private static func decodeUInt32Array(_ data: Data) -> [UInt32] {
        let count = data.count / MemoryLayout<UInt32>.size
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return [] }
            let buffer = baseAddress.assumingMemoryBound(to: UInt32.self)
            return Array(UnsafeBufferPointer(start: buffer, count: count))
        }
    }
}

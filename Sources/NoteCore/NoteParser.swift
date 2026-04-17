import Foundation
import ZIPFoundation

/// Parsed contents of a .note file.
public struct ParsedNote {
    public let strokes: StrokeData
    public let timeline: [TimelineEvent]
    public let recordings: [RecordingInfo]
    public let recordingData: [Int: Data]  // recording identifier → m4a data
    public let images: [NoteImage]
    public let handwritingIndex: [HandwritingEntry]?
    public let pageCount: Int
    public let title: String
    public let pageWidth: Float   // in note coordinates
    public let pageHeight: Float  // in note coordinates
}

public struct RecordingInfo {
    public let identifier: Int
    public let filename: String
    public let duration: Double
}

public struct NoteImage {
    public let filename: String
    public let data: Data
    // Position info from mediaObjects (if available)
    public let originX: Float?
    public let originY: Float?
    public let width: Float?
    public let height: Float?
}

public struct HandwritingEntry {
    public let text: String
    public let strokeRange: Range<Int>
}

/// Parses .note files (Notability ZIP bundles).
public struct NoteParser {
    public init() {}

    /// Paper aspect ratios (height / width in portrait orientation).
    /// Keys are normalized lowercase. Values match standard PDF dimensions at 72 DPI.
    /// Looked up by `documentPaperAttributes.paperSize` string from Session.plist.
    internal static let paperAspectRatios: [String: Float] = [
        "letter":  792.0 / 612.0,       // 8.5" × 11"
        "legal":   1008.0 / 612.0,      // 8.5" × 14"
        "a4":      841.68 / 595.2,      // ISO A4
        "a3":      1190.4 / 841.68,     // ISO A3
        "a5":      595.2 / 419.28,      // ISO A5
        "tabloid": 1224.0 / 792.0,      // 11" × 17"
        "b5":      708.48 / 498.96      // ISO B5
    ]

    /// Compute the logical page height in Notability's coordinate space, based on
    /// `documentPaperAttributes.paperSize` + `paperOrientation`.
    ///
    /// Notability stores stroke coordinates in iPad logical units (pageWidth ≈ 583.8 pt
    /// from `paperSizingBehavior: lockedWidth:583.8:iPad`), not PDF points.
    /// The logical page height is derived by applying the paper's aspect ratio to pageWidth.
    ///
    /// Returns `nil` when paperSize is unknown (e.g., "customWidth" or legacy values),
    /// so the caller can fallback to the stroke-bounds heuristic.
    internal static func logicalPageHeight(
        paperSize: String?,
        paperOrientation: String?,
        pageWidth: Float
    ) -> Float? {
        guard let size = paperSize?.lowercased(),
              let ratio = paperAspectRatios[size] else { return nil }
        let isLandscape = paperOrientation?.lowercased() == "landscape"
        return isLandscape ? pageWidth / ratio : pageWidth * ratio
    }

    public func parse(input: URL) throws -> ParsedNote {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Extract ZIP
        guard let archive = Archive(url: input, accessMode: .read) else {
            throw NoteError.invalidZIP(input.lastPathComponent)
        }
        for entry in archive {
            let destinationURL = tempDir.appendingPathComponent(entry.path)
            let parentDir = destinationURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parentDir.path) {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            if entry.type == .directory { continue }
            _ = try archive.extract(entry, to: destinationURL)
        }

        // Find the note directory (first subdirectory in temp)
        let contents = try FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        )
        guard let noteDir = contents.first(where: { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }) else {
            throw NoteError.missingSessionPlist
        }

        let title = noteDir.lastPathComponent

        // Parse Session.plist
        let sessionURL = noteDir.appendingPathComponent("Session.plist")
        guard FileManager.default.fileExists(atPath: sessionURL.path) else {
            throw NoteError.missingSessionPlist
        }
        let sessionData = try Data(contentsOf: sessionURL)
        let sessionPlist = try PropertyListSerialization.propertyList(
            from: sessionData, format: nil
        )
        guard let root = sessionPlist as? [String: Any],
              let objects = root["$objects"] as? [Any] else {
            throw NoteError.invalidPlistStructure("Session.plist")
        }

        let navigator = PlistNavigator(objects: objects)

        // Navigate to root object
        // GLKeyedArchiver uses "$0" key in $top (not "root" like NSKeyedArchiver)
        guard let topDict = root["$top"] as? [String: Any] else {
            throw NoteError.invalidPlistStructure("$top missing")
        }
        let rootValue = topDict["root"] ?? topDict["$0"]
        guard let rootUID = navigator.uidValue(rootValue),
              let rootObj = navigator.object(at: rootUID) as? [String: Any] else {
            throw NoteError.invalidPlistStructure("$top root")
        }

        // Get richText
        guard let richTextUID = navigator.uidValue(rootObj["richText"]),
              let richText = navigator.object(at: richTextUID) as? [String: Any] else {
            throw NoteError.invalidPlistStructure("richText")
        }

        // Parse strokes from Handwriting Overlay → SpatialHash
        let strokes: StrokeData
        if let overlayUID = navigator.uidValue(richText["Handwriting Overlay"]),
           let overlay = navigator.object(at: overlayUID) as? [String: Any],
           let spatialUID = navigator.uidValue(overlay["SpatialHash"]),
           let spatial = navigator.object(at: spatialUID) as? [String: Any] {
            strokes = try StrokeDecoder.decode(from: spatial, navigator: navigator)
        } else {
            strokes = StrokeData.empty
        }

        // Parse timeline from contentPlaybackEventManager (using curveUUIDs for mapping)
        let timeline: [TimelineEvent]
        if let managerUID = navigator.uidValue(rootObj["contentPlaybackEventManager"]),
           let manager = navigator.object(at: managerUID) as? [String: Any] {
            timeline = TimelineDecoder.decode(from: manager, curveUUIDs: strokes.curveUUIDs)
        } else {
            timeline = []
        }

        // Parse page count from pageLayoutArray
        let pageCount: Int
        if let layoutUID = navigator.uidValue(richText["pageLayoutArray"]),
           let layoutObj = navigator.object(at: layoutUID) as? [String: Any],
           let layoutObjects = layoutObj["NS.objects"] as? [Any] {
            pageCount = layoutObjects.count
        } else {
            pageCount = 1
        }

        // Parse paper width from NBNoteTakingSessionDocumentPaperLayoutModelKey
        var pageWidth: Float = 583.8  // default: Notability letter width
        if let paperLayoutUID = navigator.uidValue(rootObj["NBNoteTakingSessionDocumentPaperLayoutModelKey"]),
           let paperLayout = navigator.object(at: paperLayoutUID) as? [String: Any],
           let paperAttrsUID = navigator.uidValue(paperLayout["documentPaperAttributes"]),
           let paperAttrs = navigator.object(at: paperAttrsUID) as? [String: Any] {
            if let sizingUID = navigator.uidValue(paperAttrs["paperSizingBehavior"]),
               let sizingStr = navigator.object(at: sizingUID) as? String {
                let parts = sizingStr.split(separator: ":")
                if parts.count >= 2, let w = Float(parts[1]) {
                    pageWidth = w
                }
            }
        }
        // Page height = total content height / page count (includes inter-page gap)
        let pageHeight: Float
        if pageCount > 1 {
            pageHeight = (strokes.bounds.maxY + 20) / Float(pageCount)
        } else {
            pageHeight = strokes.bounds.maxY + 20
        }

        // Parse recordings
        let recordingsDir = noteDir.appendingPathComponent("Recordings")
        var recordings: [RecordingInfo] = []
        var recordingData: [Int: Data] = [:]
        let libraryURL = recordingsDir.appendingPathComponent("library.plist")
        if FileManager.default.fileExists(atPath: libraryURL.path) {
            let libData = try Data(contentsOf: libraryURL)
            if let libPlist = try PropertyListSerialization.propertyList(from: libData, format: nil) as? [String: Any],
               let recs = libPlist["recordings"] as? [String: Any] {
                for (_, value) in recs {
                    guard let recDict = value as? [String: Any],
                          let identifier = recDict["identifier"] as? Int,
                          let filename = recDict["filepath"] as? String,
                          let duration = recDict["duration"] as? Double else { continue }
                    recordings.append(RecordingInfo(
                        identifier: identifier, filename: filename, duration: duration
                    ))
                    let audioURL = recordingsDir.appendingPathComponent(filename)
                    if FileManager.default.fileExists(atPath: audioURL.path) {
                        recordingData[identifier] = try Data(contentsOf: audioURL)
                    }
                }
                recordings.sort { $0.identifier < $1.identifier }
            }
        }

        // Parse images with positions from mediaObjects
        let imagesDir = noteDir.appendingPathComponent("Images")
        var images: [NoteImage] = []

        // Extract media object positions (values are UIDs pointing to "{x, y}" strings)
        var mediaPositions: [(x: Float, y: Float, w: Float, h: Float)] = []
        if let mediaUID = navigator.uidValue(richText["mediaObjects"]),
           let mediaObj = navigator.object(at: mediaUID) as? [String: Any],
           let mediaItems = mediaObj["NS.objects"] as? [Any] {
            for item in mediaItems {
                guard let itemUID = navigator.uidValue(item),
                      let itemDict = navigator.object(at: itemUID) as? [String: Any] else { continue }
                // documentOrigin and unscaledContentSize are UIDs → string "{x, y}"
                let originStr: Any?
                if let originRefUID = navigator.uidValue(itemDict["documentOrigin"]) {
                    originStr = navigator.object(at: originRefUID)
                } else {
                    originStr = itemDict["documentOrigin"]
                }
                let sizeStr: Any?
                if let sizeRefUID = navigator.uidValue(itemDict["unscaledContentSize"]) {
                    sizeStr = navigator.object(at: sizeRefUID)
                } else {
                    sizeStr = itemDict["unscaledContentSize"]
                }
                let origin = parsePointString(originStr)
                let size = parseSizeString(sizeStr)
                mediaPositions.append((
                    x: origin?.x ?? 0,
                    y: origin?.y ?? 0,
                    w: size?.w ?? 0,
                    h: size?.h ?? 0
                ))
            }
        }

        if FileManager.default.fileExists(atPath: imagesDir.path) {
            let imageFiles = try FileManager.default.contentsOfDirectory(
                at: imagesDir, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for (idx, imageURL) in imageFiles.enumerated() {
                let data = try Data(contentsOf: imageURL)
                let pos = idx < mediaPositions.count ? mediaPositions[idx] : nil
                images.append(NoteImage(
                    filename: imageURL.lastPathComponent,
                    data: data,
                    originX: pos?.x,
                    originY: pos?.y,
                    width: pos?.w,
                    height: pos?.h
                ))
            }
        }

        // Parse handwriting index
        let indexURL = noteDir.appendingPathComponent("HandwritingIndex/index.plist")
        var handwritingIndex: [HandwritingEntry]? = nil
        if FileManager.default.fileExists(atPath: indexURL.path) {
            let indexData = try Data(contentsOf: indexURL)
            if let indexPlist = try PropertyListSerialization.propertyList(from: indexData, format: nil) as? [String: Any] {
                handwritingIndex = parseHandwritingIndex(indexPlist)
            }
        }

        return ParsedNote(
            strokes: strokes,
            timeline: timeline,
            recordings: recordings,
            recordingData: recordingData,
            images: images,
            handwritingIndex: handwritingIndex,
            pageCount: max(pageCount, 1),
            title: title,
            pageWidth: pageWidth,
            pageHeight: pageHeight
        )
    }

    /// Parse a CGPoint-like string "{x, y}" or a stringified value.
    private func parsePointString(_ value: Any?) -> (x: Float, y: Float)? {
        guard let str = value as? String else { return nil }
        let cleaned = str.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        let parts = cleaned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let x = Float(parts[0]),
              let y = Float(parts[1]) else { return nil }
        return (x: x, y: y)
    }

    /// Parse a CGSize-like string "{w, h}".
    private func parseSizeString(_ value: Any?) -> (w: Float, h: Float)? {
        guard let str = value as? String else { return nil }
        let cleaned = str.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        let parts = cleaned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let w = Float(parts[0]),
              let h = Float(parts[1]) else { return nil }
        return (w: w, h: h)
    }

    private func parseHandwritingIndex(_ plist: [String: Any]) -> [HandwritingEntry]? {
        // HandwritingIndex contains recognized text mapped to stroke ranges
        // Structure varies; extract what we can
        guard let entries = plist["entries"] as? [[String: Any]] else { return nil }
        var result: [HandwritingEntry] = []
        for entry in entries {
            guard let text = entry["text"] as? String,
                  let start = entry["startIndex"] as? Int,
                  let end = entry["endIndex"] as? Int else { continue }
            result.append(HandwritingEntry(text: text, strokeRange: start..<end))
        }
        return result.isEmpty ? nil : result
    }
}

// MARK: - Errors

public enum NoteError: LocalizedError {
    case invalidZIP(String)
    case missingSessionPlist
    case invalidPlistStructure(String)
    case invalidStrokeData(String)

    public var errorDescription: String? {
        switch self {
        case .invalidZIP(let name):
            return "無效的 .note 檔案（不是有效的 ZIP）: \(name)"
        case .missingSessionPlist:
            return "找不到 Session.plist，可能不是 Notability 筆記檔"
        case .invalidPlistStructure(let detail):
            return "Session.plist 結構無效: \(detail)"
        case .invalidStrokeData(let detail):
            return "筆跡資料解碼失敗: \(detail)"
        }
    }
}

// MARK: - Plist Navigator

/// Navigates NSKeyedArchiver/GLKeyedArchiver $objects arrays via UID references.
struct PlistNavigator {
    let objects: [Any]

    func object(at index: Int) -> Any? {
        guard index >= 0 && index < objects.count else { return nil }
        return objects[index]
    }

    func uidValue(_ value: Any?) -> Int? {
        guard let value = value else { return nil }
        // Direct integer
        if let val = value as? Int { return val }
        // Dictionary with CF$UID (XML plist format)
        if let uid = value as? [String: Any], let val = uid["CF$UID"] as? Int { return val }
        // CFKeyedArchiverUID (__NSCFType) — parse from description
        let desc = String(describing: value)
        if desc.contains("CFKeyedArchiverUID"),
           let range = desc.range(of: "value = "),
           let end = desc[range.upperBound...].firstIndex(of: "}") {
            return Int(desc[range.upperBound..<end].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

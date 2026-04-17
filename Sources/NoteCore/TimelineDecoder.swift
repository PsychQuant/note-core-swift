import Foundation

/// A single timeline event mapping an audio timestamp to a stroke.
public struct TimelineEvent {
    public let timestamp: Float     // seconds into recording
    public let duration: Float      // duration of this event
    public let recordingID: UInt16  // which recording segment
    public let curveIndex: Int      // index into curves array
}

/// Decodes NBCPEventManager timeline data.
public struct TimelineDecoder {
    /// Decode timeline events from the contentPlaybackEventManager object.
    /// - Parameters:
    ///   - manager: The NBCPEventManager dictionary
    ///   - curveUUIDs: UUIDs from the stroke data, used to map event UUIDs to curve indices
    static func decode(from manager: [String: Any], curveUUIDs: [Data]) -> [TimelineEvent] {
        guard let numEvents = manager["NBCPTimeManagerSOANumEventsKey"] as? Int,
              numEvents > 0 else {
            return []
        }

        guard let timestampsData = manager["NBCPTimeManagerSOATimestampsKey"] as? Data,
              let durationsData = manager["NBCPTimeManagerSOADurationsKey"] as? Data,
              let recordingIDsData = manager["NBCPTimeManagerSOARecordingIDsKey"] as? Data else {
            return []
        }

        let timestamps = decodeFloatArray(timestampsData)
        let durations = decodeFloatArray(durationsData)
        let recordingIDs = decodeUInt16Array(recordingIDsData)

        // Build UUID → curve index mapping
        var uuidToCurveIndex: [Data: Int] = [:]
        for (idx, uuid) in curveUUIDs.enumerated() {
            uuidToCurveIndex[uuid] = idx
        }

        // Parse event UUIDs (16 bytes each)
        let eventUUIDsData = manager["NBCPTimeManagerSOAEventUUIDsKey"] as? Data

        let count = min(numEvents, timestamps.count, durations.count, recordingIDs.count)
        var events: [TimelineEvent] = []
        events.reserveCapacity(count)

        for i in 0..<count {
            // Map event UUID to curve index
            let curveIndex: Int
            if let eventUUIDs = eventUUIDsData {
                let start = i * 16
                let end = start + 16
                if end <= eventUUIDs.count {
                    let eventUUID = eventUUIDs.subdata(in: start..<end)
                    curveIndex = uuidToCurveIndex[eventUUID] ?? -1
                } else {
                    curveIndex = -1
                }
            } else {
                curveIndex = i  // fallback: sequential
            }

            if curveIndex >= 0 {
                events.append(TimelineEvent(
                    timestamp: timestamps[i],
                    duration: durations[i],
                    recordingID: recordingIDs[i],
                    curveIndex: curveIndex
                ))
            }
        }

        return events
    }

    // MARK: - Binary Decoders

    private static func decodeFloatArray(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return [] }
            let buffer = baseAddress.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: buffer, count: count))
        }
    }

    private static func decodeUInt16Array(_ data: Data) -> [UInt16] {
        let count = data.count / MemoryLayout<UInt16>.size
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return [] }
            let buffer = baseAddress.assumingMemoryBound(to: UInt16.self)
            return Array(UnsafeBufferPointer(start: buffer, count: count))
        }
    }
}

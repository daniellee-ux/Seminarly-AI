import Foundation
import SwiftData

typealias Session = Meeting

@Model
final class Meeting {
    var title: String
    var date: Date
    var duration: TimeInterval
    var appSource: String?
    var appBundleID: String?

    @Relationship(deleteRule: .cascade) var transcript: Transcript?
    @Relationship(deleteRule: .cascade) var structuredNote: StructuredNote?

    var isProcessed: Bool {
        structuredNote != nil
    }

    init(
        title: String = "Untitled Session",
        date: Date = Date(),
        duration: TimeInterval = 0,
        appSource: String? = nil,
        appBundleID: String? = nil
    ) {
        self.title = title
        self.date = date
        self.duration = duration
        self.appSource = appSource
        self.appBundleID = appBundleID
    }

    // Paths to raw audio files (for legacy rediarization). Relative to audioDirectory.
    var systemAudioPath: String?
    var micAudioPath: String?

    // Speaker embeddings for lightweight re-clustering (~500KB vs ~115MB raw audio for 30min)
    var speakerEmbeddingsData: Data?

    // Initial FluidAudio diarization result (highest-quality, used for restore)
    var originalSpeakerCount: Int?
    var originalSegmentsData: Data?

    // Detected spoken language (e.g. "zh", "en") from WhisperKit acoustic analysis
    var detectedLanguage: String?

    // Raw text user typed in notepad during recording (nil = no notepad used)
    var userNotesText: String?

    // Timestamped note entries — each line with its recording-relative timestamp
    var timestampedNotesData: Data?

    var timestampedNotes: [TimestampedNote]? {
        get {
            guard let data = timestampedNotesData else { return nil }
            return try? JSONDecoder().decode([TimestampedNote].self, from: data)
        }
        set {
            timestampedNotesData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    var speakerEmbeddings: [SpeakerEmbedding]? {
        get {
            guard let data = speakerEmbeddingsData else { return nil }
            return try? JSONDecoder().decode([SpeakerEmbedding].self, from: data)
        }
        set {
            speakerEmbeddingsData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    var hasRediarizationData: Bool {
        speakerEmbeddingsData != nil || systemAudioPath != nil
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var hasAudioData: Bool {
        systemAudioPath != nil
    }

    static var audioDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Seminarly/Audio", isDirectory: true)
    }

    func saveAudio(systemSamples: [Float], micSamples: [Float]?) {
        let id = UUID().uuidString
        let dir = Self.audioDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let systemFile = "\(id).system.raw"
        let systemURL = dir.appendingPathComponent(systemFile)
        systemSamples.withUnsafeBufferPointer { ptr in
            let data = Data(buffer: ptr)
            try? data.write(to: systemURL)
        }
        self.systemAudioPath = systemFile

        if let micSamples, !micSamples.isEmpty {
            let micFile = "\(id).mic.raw"
            let micURL = dir.appendingPathComponent(micFile)
            micSamples.withUnsafeBufferPointer { ptr in
                let data = Data(buffer: ptr)
                try? data.write(to: micURL)
            }
            self.micAudioPath = micFile
        }
    }

    func loadAudio() -> (system: [Float], mic: [Float]?)? {
        guard let systemFile = systemAudioPath else { return nil }
        let dir = Self.audioDirectory
        guard let systemData = try? Data(contentsOf: dir.appendingPathComponent(systemFile)) else { return nil }
        let system = systemData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        var mic: [Float]?
        if let micFile = micAudioPath,
           let micData = try? Data(contentsOf: dir.appendingPathComponent(micFile)) {
            mic = micData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        return (system, mic)
    }

    func deleteAudioFiles() {
        let dir = Self.audioDirectory
        if let f = systemAudioPath { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        if let f = micAudioPath { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
    }
}

@Model
final class Transcript {
    var rawText: String
    var segmentsData: Data
    var meeting: Meeting?

    var segments: [TranscriptSegment] {
        get {
            (try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData)) ?? []
        }
        set {
            segmentsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    init(rawText: String = "", segments: [TranscriptSegment] = []) {
        self.rawText = rawText
        self.segmentsData = (try? JSONEncoder().encode(segments)) ?? Data()
    }

    var diarizedText: String {
        if segments.isEmpty { return rawText }
        return segments.map { segment in
            let timestamp = formatTimestamp(segment.startTime)
            let speaker = segment.speaker ?? "Speaker"
            return "[\(timestamp)] \(speaker): \(segment.text)"
        }.joined(separator: "\n")
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

struct TranscriptSegment: Codable, Hashable, Sendable {
    let startTime: Double
    let endTime: Double
    let text: String
    var speaker: String?
    var speakerConfidence: Double?
}

struct TimestampedNote: Codable, Hashable, Sendable {
    let timestamp: Double  // seconds since recording start
    let text: String

    var formattedTimestamp: String {
        let mins = Int(timestamp) / 60
        let secs = Int(timestamp) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    static func formatForPrompt(_ notes: [TimestampedNote]) -> String {
        notes.map { "[\($0.formattedTimestamp)] \($0.text)" }.joined(separator: "\n")
    }
}

@Model
final class StructuredNote {
    var summary: String
    var templateType: String
    var sectionsData: Data
    var meeting: Meeting?
    var generatedAt: Date

    // Storage code for the summary's target language. nil = matched the
    // transcript at generation time. See SummaryLanguage.storageCode.
    var language: String?

    var sections: [NoteSection] {
        get {
            (try? JSONDecoder().decode([NoteSection].self, from: sectionsData)) ?? []
        }
        set {
            sectionsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    init(
        summary: String = "",
        templateType: String = NoteTemplate.freeform.rawValue,
        sections: [NoteSection] = [],
        generatedAt: Date = Date(),
        language: String? = nil
    ) {
        self.summary = summary
        self.templateType = templateType
        self.sectionsData = (try? JSONEncoder().encode(sections)) ?? Data()
        self.generatedAt = generatedAt
        self.language = language
    }

    var resolvedTemplate: NoteTemplate {
        NoteTemplate(rawValue: templateType) ?? .freeform
    }
}

import Foundation

struct SectionDefinition: Codable, Hashable, Sendable {
    let key: String
    let title: String
    let icon: String
    let promptHint: String
}

/// A note item with optional source attribution (Granola-style: user = primary, AI = gray).
/// Decodes from either a plain string (legacy notes) or {"text", "source", "transcriptRef", "children"}.
/// `children` enables one level of sub-bullets used by the Freeform template.
struct NoteItem: Codable, Hashable, Sendable {
    let text: String
    let source: Source?
    let transcriptRef: String? // e.g. "03:45-04:12"
    let children: [NoteItem]?

    enum Source: String, Codable, Sendable {
        case user       // Derived from the user's manual notes
        case transcript // Added purely from transcript analysis
    }

    init(text: String, source: Source? = nil, transcriptRef: String? = nil, children: [NoteItem]? = nil) {
        self.text = text
        self.source = source
        self.transcriptRef = transcriptRef
        self.children = children
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let str = try? container.decode(String.self) {
            self.text = str
            self.source = nil
            self.transcriptRef = nil
            self.children = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decode(String.self, forKey: .text)
        self.source = try container.decodeIfPresent(Source.self, forKey: .source)
        self.transcriptRef = try container.decodeIfPresent(String.self, forKey: .transcriptRef)
        self.children = try container.decodeIfPresent([NoteItem].self, forKey: .children)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(transcriptRef, forKey: .transcriptRef)
        try container.encodeIfPresent(children, forKey: .children)
    }

    private enum CodingKeys: String, CodingKey {
        case text, source, transcriptRef, children
    }
}

struct NoteSection: Codable, Hashable, Sendable {
    let key: String
    let title: String
    let icon: String
    let items: [NoteItem]
}

enum NoteTemplate: String, Codable, CaseIterable, Identifiable, Sendable {
    case freeform
    case lecture
    case studyGuide
    case meeting
    case podcast
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .freeform: return "Freeform"
        case .lecture: return "Lecture Notes"
        case .studyGuide: return "Study Guide"
        case .meeting: return "Meeting Notes"
        case .podcast: return "Podcast Summary"
        case .custom: return "Custom"
        }
    }

    var icon: String {
        switch self {
        case .freeform: return "list.bullet.indent"
        case .lecture: return "graduationcap"
        case .studyGuide: return "book"
        case .meeting: return "person.3"
        case .podcast: return "headphones"
        case .custom: return "square.and.pencil"
        }
    }

    var description: String {
        switch self {
        case .freeform: return "Let the model group topics naturally with nested bullets"
        case .lecture: return "Extract key concepts, definitions, and examples from lectures"
        case .studyGuide: return "Generate study questions, topic summaries, and practice problems"
        case .meeting: return "Capture decisions, action items, and discussion points"
        case .podcast: return "Summarize themes, notable quotes, and takeaways"
        case .custom: return "Use your own instructions for note generation"
        }
    }

    var sectionDefinitions: [SectionDefinition] {
        switch self {
        case .freeform:
            return []
        case .lecture:
            return [
                SectionDefinition(key: "keyConcepts", title: "Key Concepts", icon: "lightbulb", promptHint: "Each concept as a clear statement with a one-sentence explanation of why it matters"),
                SectionDefinition(key: "definitions", title: "Definitions", icon: "text.book.closed", promptHint: "Term — plain-language definition, formatted as 'Term: definition'"),
                SectionDefinition(key: "examples", title: "Examples", icon: "list.number", promptHint: "Concrete examples or analogies used, noting which concept each illustrates"),
                SectionDefinition(key: "connections", title: "Connections & Applications", icon: "arrow.triangle.branch", promptHint: "Links to related concepts, real-world applications, or prior material referenced"),
                SectionDefinition(key: "keyTakeaways", title: "Key Takeaways", icon: "star", promptHint: "The most exam-worthy or review-worthy points, each self-contained enough to understand without context"),
                SectionDefinition(key: "questionsRaised", title: "Review Questions", icon: "questionmark.circle", promptHint: "Questions to test understanding — both from the lecture and self-test prompts a student should ask"),
            ]
        case .studyGuide:
            return [
                SectionDefinition(key: "topics", title: "Topics Covered", icon: "list.bullet.rectangle", promptHint: "Main topics with subtopics indented using →, e.g. 'Machine Learning → Supervised Learning → Regression'"),
                SectionDefinition(key: "keyPoints", title: "Key Points", icon: "star", promptHint: "Clear factual statements, each containing at least one specific name, number, or concrete detail"),
                SectionDefinition(key: "questionsAndAnswers", title: "Q&A Review", icon: "bubble.left.and.bubble.right", promptHint: "Exam-style questions with concise answers, formatted as 'Q: question A: answer'"),
                SectionDefinition(key: "practiceProblems", title: "Practice Problems", icon: "pencil.and.list.clipboard", promptHint: "Specific problems answerable from the content, with difficulty ranging from recall to application"),
                SectionDefinition(key: "memoryAids", title: "Memory Aids", icon: "brain.head.profile", promptHint: "Mnemonics, acronyms, analogies, or mental models to help remember key concepts"),
                SectionDefinition(key: "furtherStudy", title: "Further Study", icon: "arrow.right.circle", promptHint: "Gaps in coverage or areas that need deeper review, with specific what-to-look-up suggestions"),
            ]
        case .meeting:
            return [
                SectionDefinition(key: "discussionPoints", title: "Discussion Points", icon: "list.bullet", promptHint: "Key topics discussed — attribute to speakers, note disagreements and resolutions"),
                SectionDefinition(key: "decisions", title: "Decisions", icon: "checkmark.seal", promptHint: "Decisions explicitly agreed upon, with who decided and the rationale if stated"),
                SectionDefinition(key: "actionItems", title: "Action Items", icon: "checklist", promptHint: "Specific tasks formatted as 'Task — Owner (deadline if mentioned)'"),
                SectionDefinition(key: "openQuestions", title: "Open Questions", icon: "questionmark.circle", promptHint: "Unresolved questions, parking lot items, or topics deferred to a future meeting"),
            ]
        case .podcast:
            return [
                SectionDefinition(key: "guestBackground", title: "Speaker Background", icon: "person.text.rectangle", promptHint: "Brief context on each speaker — credentials, role, or expertise mentioned in the episode"),
                SectionDefinition(key: "themes", title: "Themes", icon: "tag", promptHint: "Main threads of conversation, each as a topic sentence capturing the core argument"),
                SectionDefinition(key: "keyInsights", title: "Key Insights", icon: "lightbulb", promptHint: "Novel or particularly well-articulated points — ideas you'd share with a friend"),
                SectionDefinition(key: "notableQuotes", title: "Notable Quotes", icon: "quote.bubble", promptHint: "Memorable statements attributed to the speaker, close paraphrases in quotation marks"),
                SectionDefinition(key: "references", title: "References", icon: "link", promptHint: "Books, articles, tools, people, or resources mentioned with enough context to find them"),
                SectionDefinition(key: "takeaways", title: "Takeaways", icon: "arrow.right.circle", promptHint: "Actionable conclusions — what the listener should do, think about, or explore next"),
            ]
        case .custom:
            return []
        }
    }
}

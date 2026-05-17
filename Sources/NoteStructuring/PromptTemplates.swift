import Foundation

enum PromptTemplates {
    // MARK: - System Prompts

    static func systemPrompt(
        for template: NoteTemplate,
        summaryLanguage: SummaryLanguage = .matchTranscript
    ) -> String {
        let persona = templatePersona(for: template)
        let toneRules = """
        Write in a natural, professional tone. Use contractions (it's, they'll, we're). \
        Vary sentence length — mix short punchy statements with longer explanations. \
        Every bullet point must contain at least one specific fact, name, or concrete detail \
        from the transcript. Avoid filler phrases like "it's worth noting", "importantly", \
        "as previously mentioned", or "in conclusion". Write as a skilled human notetaker would.
        """

        let speakerRules = """
        The transcript may include speaker labels (e.g., "Speaker 1:", "Speaker 2:"). \
        When speakers are identified, attribute key statements, decisions, and commitments \
        to specific speakers. Note disagreements and capture both perspectives. \
        If speakers are not labeled, focus on the content without fabricating attribution.
        """

        var prompt = """
        \(persona)

        \(toneRules)

        \(speakerRules)

        Respond with ONLY valid JSON (no markdown fences, no commentary). Use the exact schema \
        provided in the user message.

        JSON SAFETY (critical — malformed JSON breaks the app):
        - Inside string values, every ASCII double quote (") MUST be escaped as \\\".
        - When quoting CJK speech (Chinese, Japanese, Korean), prefer typographic quotes — \
        Chinese 「…」, 『…』, or U+201C/U+201D — over ASCII ". Typographic quotes do not need escaping.
        - Escape any backslash inside a string as \\\\.
        - Do not include literal control characters (newlines, tabs) inside string values; \
        write \\n / \\t instead.
        """

        if let directive = languageSystemDirective(summaryLanguage) {
            prompt += "\n\n\(directive)"
        }

        return prompt
    }

    // MARK: - Language Directives

    /// Sentence appended to the system prompt when a target language is set.
    /// Returns nil for `.matchTranscript` so existing behavior is preserved.
    static func languageSystemDirective(_ language: SummaryLanguage) -> String? {
        guard let name = language.promptLanguageName else { return nil }
        return """
        OUTPUT LANGUAGE: Write all output content — including the title, every section heading, \
        every bullet, and the summary — in \(name). Section keys in the JSON schema (e.g., \
        "title", "summary", "topics") MUST stay in English exactly as specified, but their \
        VALUES must be in \(name). Do not translate proper nouns, brand names, or directly \
        quoted speech.
        """
    }

    /// Single-line rule appended to the rules block (recency reinforcement).
    static func languageRule(_ language: SummaryLanguage) -> String? {
        guard let name = language.promptLanguageName else { return nil }
        return "- All values (title, summary, headings, bullets) MUST be written in \(name). Keep JSON keys in English."
    }

    private static func templatePersona(for template: NoteTemplate) -> String {
        switch template {
        case .freeform:
            return """
            You are a skilled notetaker who identifies the natural topic structure of a \
            conversation. You group related points together under descriptive topic headers \
            and capture hierarchy with nested bullets. You write notes that read like a \
            well-organized mind map — flexible but clear, with no forced structure.
            """
        case .lecture:
            return """
            You are an experienced teaching assistant who has helped hundreds of students \
            ace their exams. You analyze lecture transcripts and produce notes optimized for \
            understanding and retention. You focus on what students actually need to know: \
            the core concepts, precise definitions, concrete examples, and connections between \
            ideas. You write notes that make sense weeks later without re-watching the lecture.
            """
        case .studyGuide:
            return """
            You are an expert academic tutor who creates study materials grounded in learning \
            science. You use active recall (self-test questions), elaborative interrogation \
            (why/how prompts), and spaced repetition principles. You produce study guides that \
            don't just list facts — they help students test themselves, build mental models, \
            and identify what they still need to learn.
            """
        case .meeting:
            return """
            You are a senior executive assistant who has distilled thousands of meetings into \
            actionable notes. You cut through discussion to capture what actually matters: who \
            committed to what, what was decided and why, and what's still unresolved. You write \
            notes people can scan in 30 seconds and know exactly what they need to do next.
            """
        case .podcast:
            return """
            You are a skilled journalist and podcast reviewer. You capture the essence of \
            conversations — the surprising insights, the memorable turns of phrase, and the \
            practical takeaways. You write summaries that make someone who hasn't listened feel \
            like they caught the best parts, while giving listeners a reference to revisit key \
            moments.
            """
        case .custom:
            return """
            You are a versatile note-taking assistant. You analyze transcripts and produce \
            structured notes tailored to the user's specific instructions. Adapt your style and \
            focus to match what the user asks for.
            """
        }
    }

    // MARK: - User Prompt

    static func structureNotes(
        transcript: String,
        template: NoteTemplate,
        customInstructions: String? = nil,
        summaryLanguage: SummaryLanguage = .matchTranscript
    ) -> String {
        if template == .freeform {
            return freeformStructurePrompt(
                transcript: transcript,
                customInstructions: customInstructions,
                summaryLanguage: summaryLanguage
            )
        }

        let contentTypeName = template.displayName.lowercased()

        // Build JSON schema dynamically from section definitions
        var jsonFields = """
                "title": "Brief descriptive title based on content",
                "summary": "2-3 sentence summary"
        """
        for def in template.sectionDefinitions {
            jsonFields += ",\n        \"\(def.key)\": [\n            \"\(def.promptHint)\"\n        ]"
        }

        var rules = templateSpecificRules(for: template)

        if let custom = customInstructions, !custom.isEmpty {
            rules += "\n- Additional instructions: \(custom)"
        }

        if let langRule = languageRule(summaryLanguage) {
            rules += "\n\(langRule)"
        }

        return """
        Analyze this transcript and produce structured \(contentTypeName) in JSON format.

        First, mentally identify the major themes and topics in the transcript. Then, for each \
        section below, extract the most relevant information. Prioritize substance over coverage — \
        fewer high-quality items beat many shallow ones.

        Transcript:
        ---
        \(transcript)
        ---

        Respond with ONLY a JSON object (no markdown fences) in this exact format:
        {
            \(jsonFields)
        }

        Rules:
        \(rules)
        - If the transcript is very short or unclear, do your best with available info
        - Omit sections that have no relevant content (use an empty array [])
        """
    }

    // MARK: - Freeform Prompts

    private static func freeformStructurePrompt(
        transcript: String,
        customInstructions: String?,
        summaryLanguage: SummaryLanguage = .matchTranscript
    ) -> String {
        var rules = templateSpecificRules(for: .freeform)
        if let custom = customInstructions, !custom.isEmpty {
            rules += "\n- Additional instructions: \(custom)"
        }
        if let langRule = languageRule(summaryLanguage) {
            rules += "\n\(langRule)"
        }

        return """
        Analyze this transcript and produce freeform notes grouped by topic in JSON format.

        Identify the natural topic groupings — don't force content into predefined buckets. \
        For each topic, write main bullets. Add children only when a point has genuinely \
        subordinate details.

        Transcript:
        ---
        \(transcript)
        ---

        Respond with ONLY a JSON object (no markdown fences) in this exact format:
        {
            "title": "Brief descriptive title based on content",
            "summary": "2-3 sentence summary",
            "topics": [
                {
                    "title": "Topic name derived from content",
                    "items": [
                        {
                            "text": "Main point with a concrete detail",
                            "source": "transcript",
                            "transcriptRef": "MM:SS-MM:SS",
                            "children": [
                                {"text": "Sub-point or supporting detail", "source": "transcript", "transcriptRef": "MM:SS-MM:SS"}
                            ]
                        }
                    ]
                }
            ]
        }

        Rules:
        \(rules)
        - Every item must be an object with "text" and "source". "transcriptRef" and "children" are optional
        - Omit "children" (or use []) when a main point has no meaningful sub-points
        - Omit "transcriptRef" on a child when it matches its parent's timestamp
        - If the transcript is very short or unclear, do your best with available info
        """
    }

    private static func freeformEnhancePrompt(
        userNotes: String,
        transcript: String,
        customInstructions: String?,
        summaryLanguage: SummaryLanguage = .matchTranscript
    ) -> String {
        var rules = templateSpecificRules(for: .freeform)
        if let custom = customInstructions, !custom.isEmpty {
            rules += "\n- Additional instructions: \(custom)"
        }
        if let langRule = languageRule(summaryLanguage) {
            rules += "\n\(langRule)"
        }

        return """
        The user took notes during this session. Enhance them with context from the transcript \
        and produce freeform notes grouped by topic.

        User's notes:
        ---
        \(userNotes)
        ---

        Full transcript:
        ---
        \(transcript)
        ---

        Identify the natural topic groupings the user's notes suggest, then enrich each topic \
        with relevant context from the transcript. Add important topics the user didn't cover.

        Each item MUST be an object with "text" and "source" ("user" if derived from the user's \
        notes, "transcript" if added from transcript analysis). Use "transcriptRef" for timestamp \
        ranges when clear. Use "children" for sub-points only when meaningfully subordinate.

        Respond with ONLY a JSON object (no markdown fences) in this exact format:
        {
            "title": "Brief descriptive title based on content",
            "summary": "2-3 sentence summary",
            "topics": [
                {
                    "title": "Topic name derived from content",
                    "items": [
                        {
                            "text": "Main point",
                            "source": "user",
                            "transcriptRef": "MM:SS-MM:SS",
                            "children": [
                                {"text": "Supporting detail", "source": "transcript", "transcriptRef": "MM:SS-MM:SS"}
                            ]
                        }
                    ]
                }
            ]
        }

        Rules:
        \(rules)
        - Prioritize topics the user noted — they signal what matters most
        - Every user note must appear in some topic, expanded with transcript context
        - Omit "children" (or use []) when a main point has no meaningful sub-points
        - Omit "transcriptRef" on a child when it matches its parent's timestamp
        - If the transcript is very short or unclear, do your best with available info
        """
    }

    // MARK: - Enhancement Prompt (User Notes + Transcript)

    static func enhanceSystemPrompt(
        for template: NoteTemplate,
        summaryLanguage: SummaryLanguage = .matchTranscript
    ) -> String {
        let base = systemPrompt(for: template, summaryLanguage: summaryLanguage)

        let enhancementRules = """

        The user took handwritten notes during this session. These notes are their \
        personal signal of what matters most. Treat them as the backbone of your output:
        - Every user note must appear in your response, expanded with transcript context
        - Topics the user highlighted should receive the most detailed treatment
        - Fix typos and complete abbreviations, but preserve the user's meaning
        - If the user wrote headings (lines starting with #), use them as section signals
        - Also include important points from the transcript that the user didn't note
        - If user notes include timestamps like [MM:SS], cross-reference with the transcript \
        timeline — a note at [03:45] relates to what was being discussed around that time

        SOURCE ATTRIBUTION (critical):
        Each item in your JSON arrays MUST be an object with these fields:
        - "text": the note content (string)
        - "source": either "user" (derived from or expanding on the user's notes) or \
        "transcript" (added purely from transcript analysis, not related to any user note)
        - "transcriptRef": approximate timestamp range from the transcript, e.g. "03:45-04:12" \
        (omit if no clear timestamp match)

        Be honest about attribution. If an item directly corresponds to or expands on something \
        the user wrote, mark it "user". If it's something the user didn't note at all that you \
        found in the transcript, mark it "transcript".
        """

        return base + enhancementRules
    }

    static func enhanceWithUserNotes(
        userNotes: String,
        transcript: String,
        template: NoteTemplate,
        customInstructions: String? = nil,
        summaryLanguage: SummaryLanguage = .matchTranscript
    ) -> String {
        if template == .freeform {
            return freeformEnhancePrompt(
                userNotes: userNotes,
                transcript: transcript,
                customInstructions: customInstructions,
                summaryLanguage: summaryLanguage
            )
        }

        let contentTypeName = template.displayName.lowercased()

        // Build JSON schema with object items for source attribution
        var jsonFields = """
                "title": "Brief descriptive title based on content",
                "summary": "2-3 sentence summary"
        """
        for def in template.sectionDefinitions {
            jsonFields += """
            ,
                    \"\(def.key)\": [
                        {"text": "\(def.promptHint)", "source": "user", "transcriptRef": "MM:SS-MM:SS"}
                    ]
            """
        }

        var rules = templateSpecificRules(for: template)

        if let custom = customInstructions, !custom.isEmpty {
            rules += "\n- Additional instructions: \(custom)"
        }

        if let langRule = languageRule(summaryLanguage) {
            rules += "\n\(langRule)"
        }

        return """
        The user took notes during this session. Enhance them with context from the transcript.

        User's notes:
        ---
        \(userNotes)
        ---

        Full transcript:
        ---
        \(transcript)
        ---

        Produce structured \(contentTypeName) in JSON format that preserves and enriches the \
        user's notes with details from the transcript. Add important points the user didn't \
        write about.

        Each array item MUST be an object with "text", "source", and optionally "transcriptRef":
        - "source": "user" if derived from the user's notes, "transcript" if from transcript only
        - "transcriptRef": approximate timestamp range, e.g. "03:45-04:12" (omit if unclear)

        Respond with ONLY a JSON object (no markdown fences) in this exact format:
        {
            \(jsonFields)
        }

        Rules:
        \(rules)
        - Prioritize topics the user noted — they signal what matters most
        - If the transcript is very short or unclear, do your best with available info
        - Omit sections that have no relevant content (use an empty array [])
        """
    }

    // MARK: - Template-Specific Rules

    private static func templateSpecificRules(for template: NoteTemplate) -> String {
        switch template {
        case .freeform:
            return """
            - Summary: 2-3 sentences capturing the overall content and what was covered
            - Topics: identify 3-7 natural topic groupings from the content — use the speakers' \
            own framing when possible, not generic labels. Each topic title should be a descriptive \
            phrase (e.g. "Trade-offs of remote work" not just "Remote work")
            - Within each topic, write main bullets that each contain a specific fact, name, or \
            concrete detail — no filler or vague generalizations
            - Use children (sub-bullets) ONLY when a point has genuinely subordinate details that \
            clarify or expand on the main bullet. Do not force nesting — many main bullets will \
            have no children, and that is correct
            - Keep nesting to one level deep (main bullet → children only, no grandchildren)
            - Order topics by how they appeared in the conversation, or by importance if the \
            conversation jumped around
            """
        case .lecture:
            return """
            - Summary: 2-3 sentences capturing the lecture's main thesis and scope
            - Each key concept should be a self-contained statement a student can understand \
            without reading the full transcript
            - Definitions: pair each term with a plain-language explanation, formatted as \
            "Term: definition" — use the lecturer's own words when they gave a clear definition
            - Examples: note which concept each example illustrates, e.g. "Gradient descent — \
            the ball rolling downhill analogy shows how the algorithm finds minimums"
            - Connections: link concepts to related ideas, prior lectures referenced, or \
            real-world applications mentioned — these help students build a mental map
            - Key takeaways: the points most likely to appear on an exam or that a student \
            would regret not knowing — make each one standalone
            - Review questions: include questions the lecturer posed, plus 2-3 self-test \
            questions a student should be able to answer after this lecture
            """
        case .studyGuide:
            return """
            - Summary: 2-3 sentences describing the scope of material covered
            - Topics: organize hierarchically using → for nesting, e.g. "Biology → Cell Division → Mitosis"
            - Key points: each must contain a specific fact, number, or name — no vague statements \
            like "this topic is important"
            - Q&A: write exam-realistic questions ranging from recall ("What is X?") to \
            application ("How would you use X to solve Y?"), each formatted as "Q: ... A: ..."
            - Practice problems: specific, answerable from the content, ranging in difficulty — \
            include at least one that requires connecting two or more concepts
            - Memory aids: create mnemonics, acronyms, analogies, or "think of it like..." \
            mental models for the hardest concepts
            - Further study: identify specific gaps ("The lecture mentioned X but didn't explain \
            how it relates to Y — review chapter 5")
            """
        case .meeting:
            return """
            - Summary: 2-3 sentences with the meeting's purpose and primary outcome — lead with \
            the most important decision or result
            - Discussion points: attribute to speakers when possible, capture the substance of \
            debates (e.g. "Sarah argued for X because of Y; Mike preferred Z due to budget")
            - Decisions: only include what was explicitly agreed upon — state the decision, who \
            made it, and the rationale if given
            - Action items: format as "Task — Owner (deadline)" — be specific enough that the \
            owner can act without re-reading the transcript. If no owner was stated, note it as \
            "unassigned"
            - Open questions: capture unresolved items, deferred topics, and anything someone said \
            they'd "look into" or "get back to the group on"
            """
        case .podcast:
            return """
            - Summary: 2-3 sentences capturing the episode's main theme and why it matters
            - Speaker background: brief context on each speaker's expertise or role as mentioned \
            in the episode — skip if no background info was shared
            - Themes: each should be a topic sentence that captures the core argument, not just a \
            topic label (e.g. "Remote work increases deep work hours but erodes team trust" not \
            just "Remote work")
            - Key insights: focus on ideas that are novel, counterintuitive, or particularly \
            well-argued — the things you'd text to a friend
            - Notable quotes: close paraphrases in quotation marks, attributed to the speaker — \
            pick statements that are memorable, surprising, or perfectly phrased
            - References: include enough context to find each resource (e.g. "Thinking, Fast and \
            Slow by Daniel Kahneman" not just "a book about thinking")
            - Takeaways: frame as actions ("Try X this week") or provocations ("Consider whether \
            your team actually needs Y") — make them specific and useful
            """
        case .custom:
            return """
            - Summary: 2-3 sentences capturing the main content
            - Follow the user's specific instructions above
            - Organize information with concrete details — names, numbers, and specifics over \
            vague generalizations
            """
        }
    }
}

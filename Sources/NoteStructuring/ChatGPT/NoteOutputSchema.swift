import Foundation

enum NoteOutputSchema {
    static func make(for template: NoteTemplate) -> CodexJSON {
        let text: CodexJSON = .object(["type": .string("string")])
        let leaf = object([
            "text": text,
            "source": .object(["type": .string("string"), "enum": .array([.string("user"), .string("transcript")])]),
            "transcriptRef": .object(["type": .array([.string("string"), .string("null")])]),
        ])
        var itemProperties = leaf["properties"]
        if case .object(var fields) = itemProperties {
            fields["children"] = array(leaf)
            itemProperties = object(fields)
        }
        var fields = ["title": text, "summary": text]
        if template == .freeform {
            fields["topics"] = array(object(["title": text, "items": array(itemProperties)]))
        } else {
            for section in template.sectionDefinitions { fields[section.key] = array(itemProperties) }
        }
        return object(fields)
    }

    private static func object(_ fields: [String: CodexJSON]) -> CodexJSON {
        .object(["type": .string("object"), "properties": .object(fields),
                 "required": .array(fields.keys.sorted().map(CodexJSON.string)), "additionalProperties": .bool(false)])
    }

    private static func array(_ item: CodexJSON) -> CodexJSON {
        .object(["type": .string("array"), "items": item])
    }
}

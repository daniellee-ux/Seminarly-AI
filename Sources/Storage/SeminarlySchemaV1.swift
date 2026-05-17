@preconcurrency import SwiftData

enum SeminarlySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Meeting.self, Transcript.self, StructuredNote.self]
    }
}

enum SeminarlyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SeminarlySchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

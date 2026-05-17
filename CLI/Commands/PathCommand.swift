import ArgumentParser
import Foundation

struct PathCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Print the local SwiftData store path. Useful for debugging."
    )

    @MainActor
    func run() async throws {
        print(DatabaseStore.storeURL.path)
    }
}

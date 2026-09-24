import Foundation
import Darwin

enum ReleaseArchitecture: Equatable, Sendable {
    case appleSilicon, intel

    var assetName: String {
        switch self {
        case .appleSilicon: "Seminarly-AppleSilicon.dmg"
        case .intel: "Seminarly-Intel.dmg"
        }
    }

    static func detect(isARMProcess: Bool, isTranslated: Bool) -> Self {
        isARMProcess || isTranslated ? .appleSilicon : .intel
    }

    static var current: Self {
        #if arch(arm64)
        return .appleSilicon
        #else
        // Intel builds running under Rosetta use native ARM components and updates.
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
        return detect(isARMProcess: false, isTranslated: result == 0 && translated == 1)
        #endif
    }
}

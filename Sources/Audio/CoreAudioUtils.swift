import AudioToolbox
import AppKit
import Foundation

struct AudioProcess: Identifiable, Sendable {
    let id: pid_t
    let name: String
    let bundleID: String?
    let objectID: AudioObjectID
    var isRunningOutput: Bool

    var icon: NSImage? {
        NSRunningApplication(processIdentifier: id)?.icon
    }
}

// Custom Hashable/Equatable based on objectID only, so that the SwiftUI Picker
// tag still matches after refreshProcessList() updates isRunningOutput.
extension AudioProcess: Hashable {
    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        lhs.objectID == rhs.objectID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(objectID)
    }
}

enum CoreAudioError: LocalizedError {
    case osStatus(OSStatus, String)
    case noData(String)

    var errorDescription: String? {
        switch self {
        case .osStatus(let status, let context):
            return "\(context): OSStatus \(status)"
        case .noData(let context):
            return "\(context): no data returned"
        }
    }
}

enum CoreAudioUtils {
    static func getProcessList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let err = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard err == noErr else {
            throw CoreAudioError.osStatus(err, "getProcessList size")
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let err2 = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &objectIDs
        )
        guard err2 == noErr else {
            throw CoreAudioError.osStatus(err2, "getProcessList data")
        }

        return objectIDs
    }

    static func getProcessPID(objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let err = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid)
        return err == noErr ? pid : nil
    }

    static func isProcessRunningOutput(objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &isRunning)
        return err == noErr && isRunning == 1
    }

    static func getProcessBundleID(objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleID: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &bundleID)
        return err == noErr ? (bundleID as String) : nil
    }

    static func translatePIDToProcessObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processObject: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var mutablePid = pid
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &mutablePid,
            &size, &processObject
        )
        guard err == noErr, processObject != kAudioObjectUnknown else { return nil }
        return processObject
    }

    static func listAudioProcesses() throws -> [AudioProcess] {
        let objectIDs = try getProcessList()
        return objectIDs.compactMap { objectID in
            guard let pid = getProcessPID(objectID: objectID), pid > 0 else { return nil }
            let bundleID = getProcessBundleID(objectID: objectID)
            let active = isProcessRunningOutput(objectID: objectID)
            let app = NSRunningApplication(processIdentifier: pid)
            let name = app?.localizedName ?? bundleID ?? "PID \(pid)"
            return AudioProcess(
                id: pid,
                name: name,
                bundleID: bundleID,
                objectID: objectID,
                isRunningOutput: active
            )
        }
    }

    static func getDefaultOutputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard err == noErr else {
            throw CoreAudioError.osStatus(err, "getDefaultOutputDevice")
        }
        return deviceID
    }

    /// Returns true if the default output device is the built-in speaker
    /// (i.e. not headphones, AirPods, external speakers, etc.).
    static func isOutputBuiltInSpeaker() -> Bool {
        guard let deviceID = try? getDefaultOutputDeviceID() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        guard err == noErr else { return false }
        return transportType == kAudioDeviceTransportTypeBuiltIn
    }

    static func getDeviceUID(deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard err == noErr else {
            throw CoreAudioError.osStatus(err, "getDeviceUID")
        }
        return uid as String
    }
}

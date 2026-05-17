import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

final class ProcessTapManager: @unchecked Sendable {
    private var processTapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var deviceProcID: AudioDeviceIOProcID?
    private(set) var tapStreamDescription: AudioStreamBasicDescription?
    private let lock = NSLock()

    var audioBufferCallback: (@Sendable (AVAudioPCMBuffer) -> Void)?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return aggregateDeviceID != kAudioObjectUnknown && deviceProcID != nil
    }

    func start(processObjectID: AudioObjectID, mute: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }

        // Check inline to avoid deadlock — isRunning also acquires the lock,
        // and NSLock is not reentrant.
        guard aggregateDeviceID == kAudioObjectUnknown || deviceProcID == nil else { return }

        // 1. Create tap description
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = mute ? .mutedWhenTapped : .unmuted

        // 2. Create process tap
        var tapID: AudioObjectID = kAudioObjectUnknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard err == noErr else {
            throw CoreAudioError.osStatus(err, "AudioHardwareCreateProcessTap")
        }
        self.processTapID = tapID

        // 3. Read the tap's audio format
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamDesc = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
        err = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &streamDesc)
        guard err == noErr else {
            cleanup()
            throw CoreAudioError.osStatus(err, "Read tap format")
        }
        self.tapStreamDescription = streamDesc

        // 4. Get default output device UID
        let outputDeviceID = try CoreAudioUtils.getDefaultOutputDeviceID()
        let outputUID = try CoreAudioUtils.getDeviceUID(deviceID: outputDeviceID)

        // 5. Create aggregate device with tap
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Seminarly-Tap-\(processObjectID)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var aggDeviceID: AudioObjectID = kAudioObjectUnknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggDeviceID)
        guard err == noErr else {
            cleanup()
            throw CoreAudioError.osStatus(err, "AudioHardwareCreateAggregateDevice")
        }
        self.aggregateDeviceID = aggDeviceID

        // 6. Create AVAudioFormat
        guard let format = AVAudioFormat(streamDescription: &streamDesc) else {
            cleanup()
            throw CoreAudioError.noData("AVAudioFormat creation")
        }

        // 7. Create IO proc and start
        let queue = DispatchQueue(label: "com.seminarly.audiotap", qos: .userInteractive)
        let callback = self.audioBufferCallback

        err = AudioDeviceCreateIOProcIDWithBlock(
            &deviceProcID,
            aggregateDeviceID,
            queue
        ) { inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ) else { return }

            callback?(buffer)
        }
        guard err == noErr else {
            cleanup()
            throw CoreAudioError.osStatus(err, "AudioDeviceCreateIOProcIDWithBlock")
        }

        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else {
            cleanup()
            throw CoreAudioError.osStatus(err, "AudioDeviceStart")
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        cleanup()
    }

    private func cleanup() {
        if aggregateDeviceID != kAudioObjectUnknown {
            if let procID = deviceProcID {
                AudioDeviceStop(aggregateDeviceID, procID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
                deviceProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if processTapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = kAudioObjectUnknown
        }
        tapStreamDescription = nil
    }

    deinit {
        stop()
    }
}

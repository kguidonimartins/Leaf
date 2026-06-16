import CoreAudio
import Foundation

/// Abstraction over the source of "which processes are currently playing audio",
/// so the tracking logic can be tested with an injected fake.
protocol AudioActivityProviding {
    /// PIDs of processes with an active audio *output* stream right now.
    func activeOutputPIDs() -> Set<Int32>
}

/// Reports which processes are currently producing audio output by querying the
/// Core Audio HAL process list. Output (not input) is the signal we care about:
/// a meeting where the user is only listening still plays audio, so we keep that
/// app alive even when it sits in the background.
///
/// Requires macOS 14.2+ for the process-object properties; the app already
/// targets 14.6, so no availability branching is needed. Any HAL failure is
/// swallowed and reported as "no active audio", letting the caller fall back to
/// other activity signals.
final class AudioActivityMonitor: AudioActivityProviding {

    private let selfPID = ProcessInfo.processInfo.processIdentifier

    func activeOutputPIDs() -> Set<Int32> {
        guard let processObjects = processObjectList() else { return [] }

        var pids = Set<Int32>()
        for object in processObjects {
            guard isRunningOutput(object), let pid = pid(for: object) else { continue }
            if pid == selfPID { continue }
            pids.insert(pid)
        }
        return pids
    }

    // MARK: - HAL queries

    private func processObjectList() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &objects
        )
        guard status == noErr else { return nil }
        return objects
    }

    private func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private func pid(for object: AudioObjectID) -> Int32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid)
        guard status == noErr else { return nil }
        return pid
    }
}

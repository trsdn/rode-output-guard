// rode-output-guard
//
// Listens for changes to the macOS default output AND input devices.
// When RØDE Connect hijacks the default to one of its own virtual devices
// you don't want, we snap the property back to whatever was active before.
// If the user manually picks something else, we respect it and remember it
// as the new "last good" device for that property.
//
// The output side rejects *all* RØDE Connect virtual devices — they're never
// what you want as a physical output.
// The input side rejects only the mixed-in RØDE devices ("System", "Virtual")
// because "RØDE Connect Stream" is the clean processed-mic channel you
// actually want as your input — so we leave that alone.
//
// Runs as a LaunchAgent. Event-driven (no polling) via
// `AudioObjectAddPropertyListenerBlock`.

import CoreAudio
import Foundation

// UIDs that RØDE Connect tries to force as the system default OUTPUT. All
// three are "system audio going through RØDE" — never what you want as a
// physical output.
let outputHijackedDeviceUIDs: Set<String> = [
    "RodeConnectAudioDevice_UID",    // RØDE Connect System
    "RodeConnectAudioDevice_UID_2",  // RØDE Connect Virtual
    "RodeConnectAudioDevice_UID_3"   // RØDE Connect Stream
]

// UIDs that RØDE Connect tries to force as the system default INPUT. Only
// the mixed buses are rejected — "RØDE Connect Stream" (UID_3) is the
// processed-mic output you typically *want* as your input, so it is NOT
// in the hijack list.
let inputHijackedDeviceUIDs: Set<String> = [
    "RodeConnectAudioDevice_UID",    // RØDE Connect System (mic + everything mixed)
    "RodeConnectAudioDevice_UID_2"   // RØDE Connect Virtual
]

// MARK: - CoreAudio helpers

enum AudioScope {
    case output
    case input

    var defaultDeviceSelector: AudioObjectPropertySelector {
        switch self {
        case .output: kAudioHardwarePropertyDefaultOutputDevice
        case .input:  kAudioHardwarePropertyDefaultInputDevice
        }
    }
}

func getDefaultDeviceID(_ scope: AudioScope) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: scope.defaultDeviceSelector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var id: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &addr, 0, nil, &size, &id
    )
    return status == noErr ? id : nil
}

func setDefaultDeviceID(_ scope: AudioScope, _ id: AudioDeviceID) -> OSStatus {
    var addr = AudioObjectPropertyAddress(
        mSelector: scope.defaultDeviceSelector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var devID = id
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    return AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &addr, 0, nil, size, &devID
    )
}

func cfStringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
    guard status == noErr, let v = value else { return nil }
    return v.takeRetainedValue() as String
}

func getDeviceUID(_ id: AudioDeviceID) -> String? {
    cfStringProperty(id, selector: kAudioDevicePropertyDeviceUID)
}

func getDeviceName(_ id: AudioDeviceID) -> String? {
    cfStringProperty(id, selector: kAudioDevicePropertyDeviceNameCFString)
}

// MARK: - Logging

let logDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

func log(_ message: String) {
    let line = "[\(logDateFormatter.string(from: Date()))] \(message)\n"
    FileHandle.standardOutput.write(Data(line.utf8))
}

// MARK: - Per-property guard

/// Encapsulates the last-good tracking and hijack-revert logic for one
/// side (input or output). The two sides are independent — each has its
/// own listener, its own hijack-UID set, and its own remembered last-good.
final class DefaultDeviceGuard: @unchecked Sendable {
    let scope: AudioScope
    let label: String
    let hijackedUIDs: Set<String>
    let stateQueue: DispatchQueue
    let listenerQueue: DispatchQueue

    // Protected by stateQueue.
    var lastGoodDeviceID: AudioDeviceID = 0

    init(scope: AudioScope, label: String, hijackedUIDs: Set<String>) {
        self.scope = scope
        self.label = label
        self.hijackedUIDs = hijackedUIDs
        self.stateQueue = DispatchQueue(label: "rode-output-guard.\(label).state")
        self.listenerQueue = DispatchQueue(label: "rode-output-guard.\(label).listener")
    }

    func start() -> Bool {
        // Initialise from the current default, if it's already safe.
        if let current = getDefaultDeviceID(scope),
           let uid = getDeviceUID(current),
           !hijackedUIDs.contains(uid) {
            lastGoodDeviceID = current
            log("[\(label)] startup: current default is '\(getDeviceName(current) ?? "?")' (UID \(uid)) — remembered as last-good")
        } else if let current = getDefaultDeviceID(scope) {
            log("[\(label)] startup: current default is hijacked ('\(getDeviceName(current) ?? "?")') — waiting for a non-hijacked change before we have a last-good")
        } else {
            log("[\(label)] startup: could not read default — skipping this scope")
            return false
        }

        var watchAddr = AudioObjectPropertyAddress(
            mSelector: scope.defaultDeviceSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleChange()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &watchAddr,
            listenerQueue,
            listener
        )

        guard status == noErr else {
            log("[\(label)] failed to install property listener: OSStatus \(status)")
            return false
        }

        log("[\(label)] listening (guarded UIDs: \(hijackedUIDs.sorted().joined(separator: ", ")))")
        return true
    }

    private func handleChange() {
        guard let current = getDefaultDeviceID(scope) else { return }
        let name = getDeviceName(current) ?? "?"
        let uid = getDeviceUID(current) ?? ""

        stateQueue.sync {
            if hijackedUIDs.contains(uid) {
                guard lastGoodDeviceID != 0, lastGoodDeviceID != current else {
                    log("[\(label)] hijack detected (now '\(name)') but no safe last-good to revert to yet")
                    return
                }
                let revertName = getDeviceName(lastGoodDeviceID) ?? "?"
                let setStatus = setDefaultDeviceID(scope, lastGoodDeviceID)
                if setStatus == noErr {
                    log("[\(label)] blocked hijack: '\(name)' → reverted to '\(revertName)'")
                } else {
                    log("[\(label)] blocked hijack: '\(name)' → revert to '\(revertName)' FAILED (OSStatus \(setStatus))")
                }
            } else {
                if lastGoodDeviceID != current {
                    lastGoodDeviceID = current
                    log("[\(label)] accepted user change: new last-good = '\(name)' (UID \(uid))")
                }
            }
        }
    }
}

// MARK: - Boot

let outputGuard = DefaultDeviceGuard(
    scope: .output,
    label: "output",
    hijackedUIDs: outputHijackedDeviceUIDs
)
let inputGuard = DefaultDeviceGuard(
    scope: .input,
    label: "input",
    hijackedUIDs: inputHijackedDeviceUIDs
)

let outputStarted = outputGuard.start()
let inputStarted = inputGuard.start()

guard outputStarted || inputStarted else {
    log("no guards installed — exiting")
    exit(1)
}

// Keep the process alive. Listeners run on their own dispatch queues.
RunLoop.current.run()

// rode-output-guard
//
// Listens for changes to the macOS default output device. When RØDE Connect
// hijacks the default to one of its own virtual devices, we snap the default
// back to whatever non-RØDE device was active previously. If the user
// manually picks something else (AirPods, external speakers, whatever), we
// respect that and remember it as the new "last good" device.
//
// Runs as a LaunchAgent. Event-driven (no polling) via
// `AudioObjectAddPropertyListenerBlock`.

import CoreAudio
import Foundation

// UIDs of RØDE Connect's virtual output devices. These are what the RØDE
// Connect app tries to force as the system default on every launch. Add
// more here if you see RØDE set something else.
let rodeHijackedDeviceUIDs: Set<String> = [
    "RodeConnectAudioDevice_UID",    // RØDE Connect System
    "RodeConnectAudioDevice_UID_2",  // RØDE Connect Virtual
    "RodeConnectAudioDevice_UID_3"   // RØDE Connect Stream
]

// MARK: - CoreAudio helpers

func getDefaultOutputDeviceID() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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

func setDefaultOutputDeviceID(_ id: AudioDeviceID) -> OSStatus {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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

// MARK: - State

// The last non-RØDE device we saw as the default. When RØDE hijacks, we
// restore this. `0` means we haven't observed a safe default yet.
var lastGoodDeviceID: AudioDeviceID = 0
let stateQueue = DispatchQueue(label: "rode-output-guard.state")

// Initialise: if the current default is already safe (not RØDE), remember it.
if let current = getDefaultOutputDeviceID(),
   let uid = getDeviceUID(current),
   !rodeHijackedDeviceUIDs.contains(uid) {
    lastGoodDeviceID = current
    log("startup: current default is '\(getDeviceName(current) ?? "?")' (UID \(uid)) — remembered as last-good")
} else if let current = getDefaultOutputDeviceID() {
    log("startup: current default is RØDE-hijacked ('\(getDeviceName(current) ?? "?")') — waiting for a non-RØDE change before we have a last-good")
} else {
    log("startup: could not read default output — exiting")
    exit(1)
}

// MARK: - Listener

var watchAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

let listenerQueue = DispatchQueue(label: "rode-output-guard.listener")

let listener: AudioObjectPropertyListenerBlock = { _, _ in
    guard let current = getDefaultOutputDeviceID() else { return }
    let name = getDeviceName(current) ?? "?"
    let uid = getDeviceUID(current) ?? ""

    stateQueue.sync {
        if rodeHijackedDeviceUIDs.contains(uid) {
            // Hijack detected.
            guard lastGoodDeviceID != 0, lastGoodDeviceID != current else {
                log("hijack detected (now '\(name)') but no safe last-good to revert to yet")
                return
            }
            let revertName = getDeviceName(lastGoodDeviceID) ?? "?"
            let status = setDefaultOutputDeviceID(lastGoodDeviceID)
            if status == noErr {
                log("blocked RØDE hijack: '\(name)' → reverted to '\(revertName)'")
            } else {
                log("blocked RØDE hijack: '\(name)' → revert to '\(revertName)' FAILED (OSStatus \(status))")
            }
        } else {
            // User (or another app) picked a non-RØDE device — accept it.
            if lastGoodDeviceID != current {
                lastGoodDeviceID = current
                log("accepted user change: new last-good = '\(name)' (UID \(uid))")
            }
        }
    }
}

let installStatus = AudioObjectAddPropertyListenerBlock(
    AudioObjectID(kAudioObjectSystemObject),
    &watchAddr,
    listenerQueue,
    listener
)

guard installStatus == noErr else {
    log("failed to install property listener: OSStatus \(installStatus) — exiting")
    exit(1)
}

log("listening on kAudioHardwarePropertyDefaultOutputDevice (guarded UIDs: \(rodeHijackedDeviceUIDs.sorted().joined(separator: ", ")))")

// Keep the process alive. The listener runs on its own dispatch queue; the
// main run loop just needs to not exit.
RunLoop.current.run()

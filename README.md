# rode-output-guard

A tiny macOS LaunchAgent that stops RØDE Connect from hijacking your system audio **output and input** devices.

## The problem

Every time RØDE Connect launches, it forces the macOS default output *and* input to one of its virtual devices. Whatever you had selected before — headphones, external speakers, AirPods on the output, or a specific RØDE processed-mic channel on the input — gets overridden. There's no opt-out in RØDE Connect 1.3.x's UI.

## What it does

Two independent guards, each event-driven (no polling) via `AudioObjectAddPropertyListenerBlock`.

**Output guard** — watches `kAudioHardwarePropertyDefaultOutputDevice`. Rejects all three RØDE Connect virtual devices (`System`, `Virtual`, `Stream`) — none of them is ever what you want as a physical output.

**Input guard** — watches `kAudioHardwarePropertyDefaultInputDevice`. Rejects only the mixed-in RØDE buses (`System`, `Virtual`). Leaves `RØDE Connect Stream` alone because that *is* the clean processed-mic channel you typically want.

For both guards: when **you** manually pick a non-hijacked device, it's remembered as the new "last good". When RØDE Connect (or anything else) flips the default to a hijacked UID, the guard reverts to the last-good immediately.

Net effect: RØDE Connect can launch whenever it wants, your chosen output and input stick.

## Install

```sh
./install.sh
```

This:
1. Compiles the Swift source into a standalone arm64 binary.
2. Copies it to `~/.local/bin/rode-output-guard`.
3. Writes a LaunchAgent to `~/Library/LaunchAgents/rode-output-guard.plist`.
4. Loads the agent so it starts at login and after every logout.

## Logs

```
tail -f ~/Library/Logs/rode-output-guard.log
```

Expected lines (device names below are placeholders):

```
[...] [output] startup: current default is '<YourOutput>' (UID <uid>) — remembered as last-good
[...] [output] listening (guarded UIDs: RodeConnectAudioDevice_UID, RodeConnectAudioDevice_UID_2, RodeConnectAudioDevice_UID_3)
[...] [input] startup: current default is 'RØDE Connect Stream' (UID RodeConnectAudioDevice_UID_3) — remembered as last-good
[...] [input] listening (guarded UIDs: RodeConnectAudioDevice_UID, RodeConnectAudioDevice_UID_2)
[...] [output] blocked hijack: 'RØDE Connect System' → reverted to '<YourOutput>'
[...] [input] blocked hijack: 'RØDE Connect System' → reverted to 'RØDE Connect Stream'
[...] [output] accepted user change: new last-good = '<AnotherOutput>'
```

## Uninstall

```sh
launchctl unload ~/Library/LaunchAgents/rode-output-guard.plist
rm ~/Library/LaunchAgents/rode-output-guard.plist
rm ~/.local/bin/rode-output-guard
```

## Extending

Two separate sets in `main.swift` control the guard behavior:

- `outputHijackedDeviceUIDs` — UIDs that should never be accepted as the default **output**.
- `inputHijackedDeviceUIDs` — UIDs that should never be accepted as the default **input**. Deliberately a subset of the output list (e.g. `RØDE Connect Stream` is allowed here because it's the usable processed-mic channel).

If RØDE ships new virtual-device UIDs, or you want to guard against a different audio-hijacker entirely, just add its UIDs to the appropriate set. The same pattern works for any app that keeps forcing the default on you — swap in whatever UIDs it uses.

## Why an event listener, not polling

A polling loop fights RØDE in a tight ping-pong: RØDE sets, you revert, RØDE sets again. The listener fires once per actual change, so recovery is deterministic and audio doesn't get chopped up.

## Requirements

- macOS 12+
- Swift toolchain (comes with Xcode Command Line Tools)

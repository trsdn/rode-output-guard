# rode-output-guard

A tiny macOS LaunchAgent that stops RØDE Connect from hijacking your system audio output.

## The problem

Every time RØDE Connect launches, it forces the macOS default output to one of its virtual devices (`RØDE Connect System` / `Virtual` / `Stream`). Whatever you had selected before — headphones, external speakers, AirPods — gets overridden. There's no opt-out in RØDE Connect 1.3.x's UI.

## What it does

- Listens event-driven (no polling) on `kAudioHardwarePropertyDefaultOutputDevice` via `AudioObjectAddPropertyListenerBlock`.
- When the default flips to a RØDE Connect virtual device, it snaps back to the last non-RØDE device it saw.
- When **you** pick a different output manually (AirPods, external DAC, anything non-RØDE), it remembers the new choice as the "last good" device and lets it stand.
- Net effect: RØDE Connect can launch whenever it wants, your physical output choice sticks.

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
[...] startup: current default is '<YourOutput>' (UID <uid>) — remembered as last-good
[...] listening on kAudioHardwarePropertyDefaultOutputDevice …
[...] blocked RØDE hijack: 'RØDE Connect System' → reverted to '<YourOutput>'
[...] accepted user change: new last-good = '<AnotherOutput>'
```

## Uninstall

```sh
launchctl unload ~/Library/LaunchAgents/rode-output-guard.plist
rm ~/Library/LaunchAgents/rode-output-guard.plist
rm ~/.local/bin/rode-output-guard
```

## Extending

If RØDE ships new virtual-device UIDs, add them to `rodeHijackedDeviceUIDs` in `main.swift`. The same pattern works for any other app that keeps forcing the default output on you — just swap in its device UIDs.

## Why an event listener, not polling

A polling loop fights RØDE in a tight ping-pong: RØDE sets, you revert, RØDE sets again. The listener fires once per actual change, so recovery is deterministic and audio doesn't get chopped up.

## Requirements

- macOS 12+
- Swift toolchain (comes with Xcode Command Line Tools)

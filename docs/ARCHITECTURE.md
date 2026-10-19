# Architecture

How Audio Capture records, for anyone reading or building the code.<br>It's a Swift package with no dependencies.

| Part | What it holds |
|---|---|
| `EngineSync` | Lets the recording threads share values without waiting, on macOS 14. |
| `AudioCaptureKit` | The engine: capture, files and your voice. |
| `AudioCapture` | The app: the window, the Dock and the menus. |
| `IconTool` | Draws the app icon during the build. |

## How it records

1. **The tap.**<br>Audio Capture asks Core Audio for a process tap: a stereo mix of the chosen apps, or of every app except itself.<br>The tap is private and unmuted, so what you hear never changes.
2. **The device.**<br>The tap sits alone in a private aggregate device.<br>The volume and changes of output device never reach the file.
3. **Real time.**<br>The audio callback copies each buffer into a lock‑free ring.<br>It never allocates memory and never waits.
4. **The writer.**<br>A separate thread writes the ring into the file.<br>Real gaps are written as silence, so the file keeps wall‑clock time.
5. **Your voice.**<br>When it's included, the microphone runs on its own callback.<br>It's aligned to the app by time, then mixed in.

## Files

| Format | Detail |
|---|---|
| AAC | `.m4a`, 256 kbit/s stereo, written in 1-second fragments |
| Lossless | `.m4a`, Apple Lossless, written in 1-second fragments |
| WAV | `.wav`, 32-bit float, with its size header kept current;<br>past 4 GB it becomes RF64 |

While recording, the file has a hidden name beside its final place.<br>It's renamed when the recording stops.<br>If the app doesn't stop cleanly, the next launch finishes the rename.<br>If the drive was unplugged, the rename waits for it to come back.

## Permissions and network

For the System Audio Recording permission, macOS has no public way to check or ask.<br>Audio Capture uses the private TCC calls for it, loaded at run time.<br>A private call also tells which app a helper process belongs to, such as Safari's web content.

The microphone is asked for only when someone turns on Include my voice.

One network request exists, when Settings opens, at most once an hour while the app is open:

```
GET https://api.github.com/repos/lexreman/AudioCapture/releases/latest
```

It uses an ephemeral session: no cookies, no cache.

## Building

```bash
cd app
./build.sh      # builds, signs and installs in /Applications
./release.sh    # builds ad hoc and makes build/Audio-Capture.zip for a release
```

`build.sh` signs with your Apple Development certificate if you have one, so permissions survive rebuilds.<br>Without one, it signs ad hoc and resets the microphone permission, which an ad hoc signature can't keep.<br>A running copy is quit and reopened;<br>one that is recording is never touched.

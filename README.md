<p align="center">
  <img src="docs/images/icon-light.png#gh-light-mode-only" width="128" height="128" alt="">
  <img src="docs/images/icon-dark.png#gh-dark-mode-only" width="128" height="128" alt="">
</p>

<h1 align="center">Audio Capture</h1>

<p align="center"><b>Record the sound of any app on your Mac.</b></p>

<p align="center">
  <img src="docs/images/window-light.png#gh-light-mode-only" width="340" alt="Audio Capture recording Safari. The Safari row has turned into a live level meter, and the elapsed time shows beside the stop button.">
  <img src="docs/images/window-dark.png#gh-dark-mode-only" width="340" alt="Audio Capture recording Safari. The Safari row has turned into a live level meter, and the elapsed time shows beside the stop button.">
</p>

<p align="center">
  Choose an app and click the red button.<br>
  What it plays is saved as an audio file, with nothing else from your Mac in it: a call, a song, a video in your browser, a game.<br>
  Add your own voice when you need both sides of a conversation.
</p>

<p align="center">
  <a href="https://github.com/lexreman/AudioCapture/releases/latest/download/Audio-Capture.zip"><b>Download for Mac</b></a>
</p>

<p align="center">
  Requires macOS 14.4 or later, on a Mac with Apple silicon.<br>
  Built and tested on macOS 27.<br>
  In English, French, German, Italian, Spanish, Brazilian Portuguese, Japanese, Korean and Simplified Chinese.
</p>

## How to use

1. Choose an app in the list.<br>Apps that are playing show small moving bars.<br>To record several apps, Command‑click or Shift‑click them;<br>to record everything, choose Everything.
2. Click the red button, or press Space.<br>The app's row becomes a live level meter.
3. Click it again to stop.<br>The file is already in your folder, named after the app and the time.<br>Drag it anywhere, or choose Edit > Copy.

The [manual](docs/MANUAL.md) covers everything else: what happens when an app quits during a recording, keeping the window on top, recording with the window closed, and every message the app can show.

## Your voice

Right‑click an app and choose Include my voice.<br>Your microphone joins the recording, in sync with the app, so both sides of a call end up in one file.<br>A microphone badge on its icon shows it's on;<br>click the badge during a recording to cut your voice and click again to bring it back.

It listens through the microphone the app uses, and only while the app is using it.<br>For Everything, it uses your Mac's input.<br>On speakers instead of headphones, it tells you when your microphone hears the call.

<p align="center">
  <img src="docs/images/voice-loupe-light.png#gh-light-mode-only" width="550" alt="Audio Capture recording Discord with your voice. A magnifying lens over the Discord icon shows the small microphone badge.">
  <img src="docs/images/voice-loupe-dark.png#gh-dark-mode-only" width="550" alt="Audio Capture recording Discord with your voice. A magnifying lens over the Discord icon shows the small microphone badge.">
</p>

## Privacy

Audio Capture asks macOS for two permissions, each the first time it's needed:<br>to record the sound apps play, when you first open it,<br>and to use the microphone, when you first turn on Include my voice.<br>It uses the microphone only for the apps you choose.

- It never changes what you hear.<br>Volume, output device and other apps' sound stay as they are.
- Recordings go to the folder you choose, and nowhere else.
- It connects to the internet for one thing: when you open Settings, it asks GitHub whether a newer version exists.

## Formats

| Format | File | Size per hour | For |
|---|---|---|---|
| AAC (default) | `.m4a`, 256 kbit/s | about 115 MB | Listening and sharing |
| Lossless | `.m4a`, Apple Lossless | 0.4 to 0.7 GB | Full quality |
| WAV | `.wav`, 32-bit float | about 1.4 GB | Audio editors |

Stereo, at the sample rate of your Mac's sound output, the one Audio MIDI Setup shows.<br>Files are saved in Music > Audio Capture until you choose another folder in Settings.

## Questions

**What if macOS says “Audio Capture” Not Opened?**<br>
Apple can't check it for malware, because it isn't notarized.<br>The first time you open it, choose Apple menu > System Settings > Privacy & Security, scroll to Security, then click Open Anyway.<br>After that it opens normally.

**My recording is silent.**<br>
Some streaming services protect their sound, and it records as silence.<br>Audio Capture says "No sound yet" when it hears nothing.<br>If it says "No audio access", allow it in System Settings > Privacy & Security.

**What happens if the Mac goes to sleep, or the app quits?**<br>
The file is written as you record.<br>While you record, your Mac doesn't go to sleep on its own;<br>if it sleeps anyway, the recording is saved first, and the window tells you why when your Mac wakes.<br>If the recorded app quits, recording pauses;<br>click Save to finish the file, or click the red button to continue once the app is back.<br>After a crash, the file is recovered the next time Audio Capture opens.

**Does it update itself?**<br>
No.<br>When a new version is out, Settings shows it, with a button to get it.<br>After you install it, Include my voice starts off;<br>turn it on again, and macOS asks for the microphone again.

## How it works

Audio Capture records each app through a Core Audio process tap, so the file holds exactly what the app played.<br>[ARCHITECTURE.md](docs/ARCHITECTURE.md) explains the rest.

## Build from source

```bash
git clone https://github.com/lexreman/AudioCapture.git
cd AudioCapture/app
./build.sh
```

Needs Xcode 27 or later.<br>`build.sh` builds, signs and installs the app in your Applications folder.<br>`release.sh` makes the zip for a release instead.

## License

MIT.<br>See [LICENSE](LICENSE).

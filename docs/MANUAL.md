# Audio Capture manual

Everything Audio Capture does, including the parts with no button.

## First launch

The first time Audio Capture opens, the window says what it records.<br>Click Continue, and macOS asks once for permission to record the sound apps play.

## The window

The list shows every open app that uses sound and has a Dock icon.<br>Apps that live only in the menu bar aren't listed;<br>choose Everything to record them.<br>Apps playing right now come first, in the order they started, then apps that played in the last minute, then the rest.<br>The order holds still while the pointer is over the list, so a row never moves under your click.

- **Everything**, at the top, records all the sound your Mac plays, except Audio Capture's own.
- Small moving bars at the end of a row mean that app is playing.
- To see more apps at once, drag the bottom edge of the window.<br>It grows a whole row at a time and remembers its height.

## Choose what to record

- Click an app to record it alone.
- Command‑click to add an app, or to remove one.
- Shift‑click to choose every app between the last one you clicked and this one.
- A browser is recorded whole: every tab that plays is in the file.

The bottom of the window shows what you've chosen and where the file will be saved.<br>Click the folder to open it in Finder.

If the app you chose isn't open, the window says so and the record button waits until it is.

## Record

Click the red button.<br>The row of the app you're recording becomes a live level meter, and the elapsed time and file size appear beside the button.<br>While you record, the list is locked.

Click it again to stop.<br>The file is already complete in your folder.<br>It also appears in the window for a few seconds:

- Click it to show it in Finder.
- Drag it into another app or a folder to use it there.
- Choose Edit > Copy, or press Command‑C, to copy it.
- Point at it to show its buttons: Show in Finder, and Move to Trash.

You can also start and stop a recording from the Dock: right‑click the Audio Capture icon.<br>While a recording runs, the Dock icon shows the elapsed time.

## When an app quits during a recording

Recording pauses, and the window says the app closed.<br>Nothing is written while it's paused.<br>Click Save at any time to finish the file.<br>When the app is back, the window says it reopened: click the red button to continue the file.

If you're recording several apps, recording continues while one of them is still open.

## Your voice

Right‑click an app, or Everything, and choose Include my voice.<br>The first time, macOS asks for permission to use the microphone.<br>The choice is remembered for that app, and can't be changed during a recording.

While you record, your voice is mixed into the same file, in time with the app:

- It uses the microphone the app uses, and only while the app is using it.<br>For Everything, it uses your Mac's input;<br>if that's a Bluetooth headset, macOS switches it to call quality until you stop.
- Your voice is recorded as it is, with no effects.<br>When the recording nears full level, a gentle limit keeps it from clipping.<br>To make it louder or quieter in your files, use Microphone in Settings.
- A small microphone badge on the app's icon shows that your voice is included.<br>Click it during a recording to cut your voice;<br>click again to bring it back.
- If your microphone hears the call through your speakers, the window says "Mic hears the call. Use headphones."<br>It goes away when the echo stops.

## Settings

<img src="images/settings-light.png#gh-light-mode-only" width="500" alt="Audio Capture Settings: Save to, with the Audio Capture folder, and Format, with AAC chosen, and Microphone, in the middle. 115 MB per hour.">
<img src="images/settings-dark.png#gh-dark-mode-only" width="500" alt="Audio Capture Settings: Save to, with the Audio Capture folder, and Format, with AAC chosen, and Microphone, in the middle. 115 MB per hour.">

Choose Audio Capture > Settings, or press Command‑Comma.

- **Save to:** click the folder to choose another one.<br>New recordings go to Music > Audio Capture until you do.
- If macOS hasn't allowed Audio Capture to record yet, Settings shows a button to allow it.
- **Format:** AAC, Lossless or WAV.<br>The line below shows how much space an hour takes.
- **Microphone:** how loud your microphone is in your recordings, from Quieter to Louder.<br>The middle keeps it as recorded.<br>Nothing changes in other apps.
- When a new version of Audio Capture is out, Settings shows it, with a button to its download page.

## Files

Each file is named after what you recorded and when, for example:<br>`Safari - 17-10-2026, 21.04.m4a`<br>The time follows your Mac's 12- or 24-hour setting.<br>Several apps are joined with a plus sign, and Everything is named Audio Capture.<br>A name that already exists gets a number.

The file is written as you record.<br>Until you stop, it stays hidden in its folder.

| Format | File | Size per hour |
|---|---|---|
| AAC | `.m4a`, 256 kbit/s | about 115 MB |
| Lossless | `.m4a`, Apple Lossless | 0.4 to 0.7 GB, depending on the sound |
| WAV | `.wav`, 32-bit float | about 1.4 GB |

## Keep the window on top

Click the pin in the top‑right corner of the window.<br>The window then stays above other windows, on every desktop.<br>Click the pin again to release it.

## Record with the window closed

Close the window while recording, and the recording carries on out of sight: Audio Capture leaves the Dock and the app switcher.<br>Open Audio Capture again to bring the window back, or to stop.<br>When nothing is recording, closing the window quits the app.

## Sleep, quitting and the unexpected

In every case the file keeps its usual name;<br>the note appears only in the window.

- **Sleep:** while you record, your Mac doesn't go to sleep on its own.<br>If it sleeps anyway, because you close the lid or choose Sleep, the recording is saved first.<br>When it wakes, the recording appears in the window, noted "Saved at sleep".
- **Quit:** quitting while recording saves the file first.
- **Disk almost full:** recording stops and saves when less than 500 MB is left.<br>The recording appears in the window, noted "Stopped, disk almost full".
- **Write error:** if the file can no longer be written, recording stops and the file keeps what was written, noted "Stopped, write error".
- **Crash or power loss:** the next time Audio Capture opens, the interrupted file is recovered and appears in the window, noted "Recovered".<br>It plays up to the last second written.

## Messages

| Message | What it means |
|---|---|
| No audio access | macOS hasn't given Audio Capture access yet.<br>Click Allow, or turn it on in System Settings > Privacy & Security. |
| No sound yet | Nothing has been heard for 10 seconds since you started.<br>The app may be muted or paused, or its sound may be protected. |
| No sound for 1 min | The sound stopped a minute ago.<br>The recording continues. |
| Mic hears the call.<br>Use headphones. | The call plays through your speakers, and your microphone picks it up. |
| _App_ isn't open<br>The apps aren't open | The app you chose isn't running;<br>with several apps, none of them is. |
| _App_ closed<br>The apps closed | The app you're recording quit;<br>with several apps, all of them did.<br>Recording is paused: click Save to finish the file. |
| _App_ reopened | It's back: click the red button to continue. |
| The file couldn't be saved | The recording stopped, but its folder couldn't be reached, for example on a drive that was unplugged.<br>Plug the drive back in: the file is saved then, or when Audio Capture next opens, noted “Recovered”. |

## Accessibility

- VoiceOver reads every row, button and file, including whether an app is playing and the elapsed time.
- With Reduce Motion on, nothing slides or pulses;<br>changes appear at once.
- With Increase Contrast on, every tile gets an outline and dimmed rows stay readable.
- App icons follow your icon style in System Settings > Appearance, as in the Dock.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| Space | Start, stop or continue a recording |
| Up Arrow, Down Arrow | Choose the app above or below |
| Command‑C | Copy the last recording |
| Command‑Comma | Open Settings |
| Command‑W | Close the window: a recording continues out of sight;<br>otherwise Audio Capture quits |
| Command‑Q | Quit (a recording is saved first) |

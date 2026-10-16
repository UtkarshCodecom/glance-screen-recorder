# Manual integration testing

Automated tests can't grant macOS privacy permissions or use real cameras, so run these checks on a
real Mac after building. Each recording can be inspected with:

```bash
swift scripts/verify-recording.swift ~/Movies/Glance/"Glance Recording ….mp4"
```

which prints duration, every track (codec, size, fps, sample rate, enabled flag) and `OK`/`FAIL`.

## 1. Permissions

1. Reset Glance's grants to simulate a first launch:
   `tccutil reset ScreenCapture dev.utkarsh.Glance; tccutil reset Camera dev.utkarsh.Glance; tccutil reset Microphone dev.utkarsh.Glance`
2. Launch Glance. The Record page shows the "A few permissions first" card, and **no system prompt
   appears until you click Allow…**.
3. Click *Allow…* for Camera and Microphone and approve. The camera bubble preview and the level
   meter come alive.
4. Click *Allow…* for Screen & System Audio. macOS opens System Settings. Enable Glance, then use
   *Relaunch*. The stage shows a live thumbnail of your display.
5. Deny the camera in System Settings and press Record. The recording works, the control bar says the
   camera is off, and the MP4 has no bubble.

## 2. Screen capture + system audio

1. Turn the camera and microphone off, keep System audio on. Play a video in a browser and record 10 s.
2. `verify-recording.swift` shows one video track and one audio track (`aac`, 48000 Hz, 2 ch), and a
   duration of about 10 s.
3. Play the file. The audio is in sync with the on-screen video.
4. Repeat with **Window** mode. Move the window while recording. The window stays framed and nothing
   else is captured.

## 3. Microphone + webcam, sync

1. Enable camera, mic and system audio. Record a clap: clap your hands in view of the camera.
2. In the MP4, the clap sound and the camera frame where your hands meet line up (within about one frame).
3. There's exactly **one enabled audio track** containing both your voice and the system sound.
   Change the volumes in Settings › Audio and confirm the balance changes in a new recording.
4. Enable *Also keep separate microphone and system tracks*. The file then has 3 audio tracks, and only
   the first is enabled.

## 4. Camera bubble & composition

1. On the stage, drag the bubble to the top-left, choose *Landscape* and a large size. Record 5 s.
   The video shows exactly that layout.
2. While recording, drag the floating bubble across the screen. The bubble in the video follows.
   Hover the bubble, use −/+/shape, and the video updates.
3. Click the eye button on the control bar. The floating preview hides, but the camera **is still in the
   video**. Click the camera button. The bubble disappears from the video while the preview remains.
4. Confirm there is only **one** bubble in the video (the floating window is never captured).
5. Unplug an external camera mid-recording. The recording continues screen-only with a warning.

## 5. Pause/resume, countdown, shortcuts

1. Countdown 3 s → Start → Esc during countdown cancels with nothing recorded.
2. Record about 5 s, pause about 5 s (⌥⇧⌘P from another app), resume, record about 5 s, stop (⌥⇧⌘R).
   The file is about 10 s with no frozen section, and the audio is continuous at the cut.
3. Menu-bar item: shows the elapsed time, and its Pause/Stop items work.
4. Close the main window. Glance stays in the menu bar, and ⌥⇧⌘R still records.

## 6. Failure handling

1. **Display removal:** record an external display and unplug it. Recording stops and saves what was
   captured, with an explanation.
2. **macOS "Stop Sharing":** stop via the system screen-recording menu-bar indicator. Same as above.
3. **Sleep:** start recording, then sleep the Mac (Apple menu › Sleep). After wake it's paused with a note.
4. **Disk space:** choose a nearly full volume (for example a small disk image) as the recordings
   folder. Glance refuses to start under 1 GB, or stops and saves under 400 MB.
5. **Crash recovery:** start recording, then `kill -9` Glance. Relaunch → Library shows
   "1 unfinished recording found" → *Recover* produces a playable MP4 of everything up to the last few seconds.
6. **Quit while recording:** ⌘Q during a recording finishes and saves before quitting.

## 7. Playback & library

1. The new recording appears first, with a thumbnail and duration. Play opens the in-app player.
2. Rename it (try "/" to see validation). Show in Finder. Move to Trash, and the file is in the Trash.
3. Open the MP4 in QuickTime Player, Safari/Chrome (drag the file in) and VLC. It plays with sound
   everywhere.

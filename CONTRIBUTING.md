# Contributing to Glance

Thanks for helping make Glance a great open-source screen recorder for macOS!

## Getting started

1. Fork and clone the repository, then open `Glance.xcodeproj` in Xcode 16 or later.
2. Build and run the **Glance** scheme (⌘R), and run the tests (⌘U) before and after your change.
3. Grant Screen Recording, Camera and Microphone permissions when asked. Ad-hoc builds may need permissions again
   after a rebuild. Set your own team under *Signing & Capabilities* to avoid that (don't commit the team change).

## Guidelines

- **Keep it native.** Use Apple frameworks only (Swift, SwiftUI, ScreenCaptureKit, AVFoundation, Core Image).
  Discuss any new dependency in an issue first.
- **Never block the main thread** with capture, encoding or file I/O. The engine's concurrency model is described at
  the top of `Glance/Recording/RecordingEngine.swift`.
- **Test what you can.** Pure logic belongs in `Glance/Models` with unit tests in `GlanceTests`. Media changes should
  extend `PipelineIntegrationTests`, which run the real encoder with synthetic frames and audio.
- **Check real hardware.** For capture, permission or device changes, run the relevant steps in
  [Docs/TESTING.md](Docs/TESTING.md) and use `swift scripts/verify-recording.swift <file.mp4>` to inspect the output.
- Match the existing style: small focused types, explicit errors (`RecorderError`), no warnings.

## Reporting bugs

Open an issue with your macOS version, Mac model, the audio/video settings you used, what you expected and what
happened. For capture bugs, attach the log from right after the recording:

```bash
log show --last 10m --info --predicate 'subsystem == "dev.utkarsh.Glance"'
```

The log contains per-source audio statistics (buffers received/written and peak level), which helps a lot with
audio issues. Please don't attach recordings that contain private information.

## Pull requests

- One focused change per PR, with a short description of what changed and how you tested it.
- Make sure `xcodebuild -project Glance.xcodeproj -scheme Glance test` passes. CI runs the same command.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE) and that you'll
follow our [Code of Conduct](CODE_OF_CONDUCT.md).

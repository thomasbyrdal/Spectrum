# Spectrum

Native macOS real-time spectrum analyzer. Open `Spectrum.xcodeproj` and run the **Spectrum** scheme (bundle ID `dk.byrdal.Spectrum`).

The app listens to a selectable source and draws a live logarithmic spectrum. It does not record audio to disk and does not capture the screen. System and per-app capture use Core Audio Taps; macOS exposes that as Screen Recording permission.

| | |
| --- | --- |
| Language | Swift 6 |
| UI | SwiftUI + AppKit |
| DSP | Accelerate `vDSP_fft_zrip` |
| Deployment | macOS 15+ |
| Bundle ID | `dk.byrdal.Spectrum` |
| Sandbox | **Off** (required for Core Audio Taps) |

## Build and test

```bash
xcodebuild -project Spectrum.xcodeproj -scheme Spectrum \
  -destination 'platform=macOS' test
```

The scheme launches on **Test Signal → Sine 1 kHz** so the plot and DSP work immediately, without Microphone or Screen Recording permission.

## Architecture

One producer writes PCM. DSP never runs on the HAL I/O thread.

```
Input menu
    → SpectrumViewModel.select
    → AudioEngineManager.start   (serialized by AsyncStartLock)
    → stop every capture + DSP, reset the ring buffer
    → start exactly one of:
          TestSignalCapture
          PhysicalAudioCapture     (HAL IOProc)
          SystemAudioCapture       (Core Audio Tap → private aggregate → HAL IOProc)
    → AudioRingBuffer              (SPSC, Float32 mono)
    → DSP timer on dk.byrdal.Spectrum.dsp
    → FFT → log-frequency bars → dBFS → attack/release + peak hold
    → SpectrumData (stamped with a generation)
    → SwiftUI Canvas               (drops frames from a superseded source)
```

Hard constraints:

- **One writer** on `AudioRingBuffer`. Leaving a previous capture (or the test-signal timer) running mixes sources.
- **Never** `dspQueue.sync` from the UI for configuration. That deadlocks against the DSP timer. Config updates are `async`.
- UI frames are accepted only when `data.generation == acceptedGeneration`.

Source switches always tear down all three captures, then start one. A start generation cancels work that was superseded by a later picker change.

## Code structure

```
Spectrum/
  SpectrumApp.swift          App entry, Help menu, modal About
  Info.plist                 Help book keys
  Spectrum.entitlements      Sandbox off; mic / audio-input
  Spectrum.help/             In-app Help HTML (WKWebView; not Apple Help Viewer)

  Audio/
    AudioEngineManager.swift     Capture + DSP orchestration
    AudioRingBuffer.swift        Lock-free SPSC Float32 ring
    AudioBufferProcessor.swift   Mix to mono, peak / RMS / clip
    AudioCapture.swift           Capture protocols
    TestSignalCapture.swift      Internal generators (no permission)
    PhysicalAudioCapture.swift   Mic / interface via HAL
    SystemAudioCapture.swift     System + per-app Core Audio Taps
    HALInputCapture.swift        Shared IOProc writer
    AudioDeviceManager.swift     Devices and running-output processes

  DSP/
    SpectrumProcessor.swift      Hop → FFT → map → dB → smooth
    FFTProcessor.swift           Real FFT, window coherent-gain scale
    FrequencyMapper.swift        Log bands, peak or RMS aggregation
    SpectrumSmoother.swift       Attack / release, peak hold
    WindowFunction.swift         Hann, Blackman-Harris, rectangular
    DecibelCalculator.swift      Linear → dBFS
    SignalGenerator.swift        Test-signal waveforms

  Models/                    Configuration, SpectrumData, sources, errors
  ViewModels/                Spectrum, devices, settings
  Views/                     Canvas plot, chrome, Settings, Help, About
  Utilities/                 Theme, TCC helpers, CPU meter, logging

SpectrumTests/               DSP, mapping, capture-switch, deadlock regressions
```

Help is shipped as a book under `Spectrum.help` but shown in an in-app window. Apple Help Viewer often reports “Help isn’t available” for ad-hoc signed Debug builds.

## Capture paths

| Source | Implementation | Permission |
| --- | --- | --- |
| Test signals | Timer on a private queue, writes the ring buffer | None |
| Physical input | HAL IOProc on the selected input device | Microphone |
| System Audio | `CATapDescription` global tap + private aggregate | Screen Recording |
| Application | Process tap of apps that currently have output | Screen Recording |

App Sandbox stays **off**. A sandboxed Debug build cannot install the tap/aggregate path used here.

Spectrum never records video, screenshots, or window contents. Screen Recording is the TCC switch macOS uses for Core Audio Taps.

## Screen Recording vs Xcode rebuilds

This is the usual reason developers think capture is broken after they already granted it.

macOS TCC keys Screen Recording to the **code signature** (designated requirement / cdhash), not to the bundle ID alone. Xcode Debug runs are typically ad-hoc or development-signed. **Each rebuild mints a new identity.**

What you will see:

1. You grant Screen Recording. System Audio or an app tap works.
2. You change code and hit Run. Xcode writes a new `.app` with a new signature.
3. System Settings still shows Spectrum as allowed — that row is the **previous** binary.
4. The new process is a different TCC client. The tap installs but you get silence, or tap/aggregate creation fails.
5. After a few Runs, Privacy → Screen Recording lists **several** Spectrum rows.

Microphone permission is also identity-scoped, but the prompt path is more forgiving. Test signals never use TCC. Use **Test Signal → Sine 1 kHz** first: if that peak appears, DSP is fine and the live source is blocked by identity or a missing grant.

### What to do while developing

1. Grant Screen Recording (and Microphone if you need a hardware input).
2. **Quit Spectrum completely** (⌘Q). A grant does not apply to the process that just asked.
3. Relaunch the **same** `.app` **without rebuilding**. Opening the product from DerivedData, or a copy you already made, keeps the identity TCC just approved.
4. If Settings lists more than one Spectrum, enable every row, then quit and reopen.

Stable workflow for tap work:

- After a build you care about, copy  
  `DerivedData/Build/Products/Debug/Spectrum.app`  
  to a fixed path (for example `~/Applications/Spectrum.app`) and launch **that** copy while debugging capture.
- Rebuild only when you need new code. Treat the next Run as a new app: grant again, quit, reopen that new binary.
- Prefer a persistent Apple Development signing identity over **Sign to Run Locally**. A changing ad-hoc signature is the worst case for TCC.
- Do not expect System Settings to “just work” across Xcode Runs. The UI label is `Spectrum`; the grant is the signature.
- Changing `PRODUCT_BUNDLE_IDENTIFIER` is also a new TCC client. Grants for an older ID (this project used to be `com.byrdal.Spectrum`) do not transfer. Re-grant Microphone and Screen Recording for `dk.byrdal.Spectrum`.

End-user builds that keep one Developer ID (or App Store) signature do not hit this. The Help book therefore does not mention Xcode. This section is for people who Run from the IDE.

## Tests

`SpectrumTests` covers FFT scaling (full-scale sine ≈ 0 dBFS), frequency mapping, smoother / peak hold, buffer mix-down, configuration updates without DSP-queue deadlock, and source switching so two writers cannot share the ring buffer.

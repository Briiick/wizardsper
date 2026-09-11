# Wizard

Hold a key, talk, release. The transcript lands in whatever app you were already
typing in. Everything runs on-device.

Menu-bar only — no Dock tile, no window, and the app never takes focus, because
taking focus is the one thing that would break the paste.

## How it works

```
Fn held ──► CGEventTap ──► DictationCoordinator ──► one SessionOutcome
                               │                    (pasted │ copied │ nothing │ failed)
                               ├─ AVAudioEngine tap ──► AVAudioConverter ──► 16 kHz mono f32
                               │        └─► RMS ──► flow bar level meter
                               │        └─► lock-free ring ──┐
                               │                             ▼
                               └───────────────── StreamingASR (actor)
                                                      preprocessor → mel
                                                      + 9 cached mel frames
                                                      → encoder (cache-aware)
                                                      → greedy RNN-T → tokens
```

The model is NVIDIA's `nemotron-speech-streaming-en-0.6b`, a cache-aware
streaming FastConformer RNN-T, in the CoreML conversion published by
FluidInference. The encoder is int8 and runs on the Neural Engine; it keeps
attention and convolution caches across chunks, so audio is processed once as it
arrives rather than re-transcribed from a growing buffer.

Measured on this machine (M4 Pro), 86 s of LibriSpeech test-clean through the
560 ms tier: **4.88% WER at 46× realtime**.

## Getting it running

```bash
./Scripts/build-app.sh          # generates the Xcode project, builds, signs
open build/Build/Products/Debug/Wizard.app
```

The first launch downloads the 560 ms model (~615 MB) into
`~/Library/Application Support/Wizard/Models/`. To pre-seed it instead:

```bash
./Scripts/fetch-model.sh 560 ~/Library/Application\ Support/Wizard/Models
```

macOS will ask for three permissions. All three are load-bearing:

| Permission | Why | Without it |
|---|---|---|
| Microphone | capture | no audio |
| Input Monitoring | the `CGEventTap` that sees Fn | the key does nothing |
| Accessibility | posting Cmd-V into another app | text is copied, not pasted |

`Scripts/build-app.sh` signs with a real Apple Development identity rather than
ad-hoc, because TCC keys those grants to the code signature — an ad-hoc signature
changes every build, so you would re-grant all three every time.

The Hardened Runtime is on, so `Resources/Wizard.entitlements` must carry
`com.apple.security.device.audio-input` even though the app is not sandboxed:
that key is the runtime's Audio Input capability, not only a sandbox key.
`NSMicrophoneUsageDescription` alone is not enough — without the entitlement,
`AVCaptureDevice.requestAccess` returns `false` within milliseconds and no prompt
is ever shown, which is indistinguishable from the user denying one.

## The CLI harness

The recognition path is developed and checked against files before any
microphone is involved.

```bash
swift build -c release

.build/release/wizard-cli probe
    # every model's real input/output signatures, and the framing arithmetic

.build/release/wizard-cli transcribe speech.wav --reference "ground truth"
    # transcript, realtime factor, WER

.build/release/wizard-cli sweep speech.wav --reference "ground truth"
    # the same audio under every framing policy, scored side by side
```

`sweep` is how the shipped default was chosen. See *Framing* below.

## Design notes

### One preprocessor input length, forever

The CoreML preprocessor takes a flexible-shape `audio` input (`RangeDim`
1...480000). CoreML specialises its execution plan per concrete shape, so every
new length triggers a full rebuild. `StreamingASR` therefore allocates the input
tensor once at a single length and never resizes it; a short final chunk is
zero-extended into it and bounded by `audio_length` instead. That is safe
because the graph masks on `audio_length` twice over — samples past the length
are excluded from framing, and mel frames past `audio_length / 160` are forced
to zero on the way out.

### Framing

A chunk cannot be handed to the preprocessor on its own: the frames near each
edge would be computed against the model's own zero padding instead of the
neighbouring audio, and that seam recurs at every chunk boundary. `FramingPolicy`
widens each chunk with real audio and selects the frames that belong to it.

Measured on 86 s of LibriSpeech through the 560 ms tier:

| policy | lookback / lookahead / offset | WER | added latency |
|---|---|---|---|
| **windowAligned** (default) | 400 / 0 / 2 | **4.88%** | none |
| fullContext | 256 / 256 / 2 | 4.88% | 16 ms |
| lowLatency | 240 / 0 / 1 | 5.37% | none |
| none | 0 / 0 / 0 | 5.37% | none |

400 samples of history put the first selected frame's whole 512-wide analysis
window inside real audio. `fullContext` buys back the last frame's final 16
samples for 16 ms of latency, and the measurement says they are worth nothing.

### The session rules

`DictationCoordinator` owns exactly one session, identified by a `SessionID`.

1. **Every async continuation re-checks the id.** Capture, feeding, finishing
   and pasting all suspend. Each hop compares the id it captured against the live
   one and returns if they differ, so work from an abandoned session can never
   write into the current one.
2. **Every terminal path publishes exactly one outcome.** `finalize` is the only
   exit and is idempotent per session. The flow bar does not dismiss until it
   sees an outcome, so a path that returned without publishing would leave the
   pill on screen forever.

A press that arrives while the previous session is still finishing is honoured
when that session completes, rather than dropped — releasing and re-pressing
inside the ~200 ms it takes to paste is a real thing people do.

### Reading model outputs

`MLMultiArray` is a view, not a buffer. CoreML may return one whose `strides`
are not the dense strides implied by `shape` — the Neural Engine routinely pads
the innermost axis to a 64-byte boundary. Reading `dataPointer` as if it were
dense does not crash and does not throw; it silently interleaves padding into the
tensor, and the only symptom is a transcript that decays into noise. Every model
output goes through `MLArrayReader`, which reads the real strides and takes a
dense fast path only after confirming the strides actually are dense.

### A harmless noise at load

Every model load prints this to stderr, once:

```
E5RT encountered an STL exception. msg = Failed to PropagateInputTensorShapes:
std::runtime_error during type inference for ios17.slice_by_index: zero shape error.
```

It is CoreML building the encoder's *default* function, where `cache_len` is 0
and the graph's slice over the cache therefore has zero length. Nothing in Wizard
ever runs with `cache_len == 0` — a session seeds it to 1, which is why
`StreamingASR.reset()` does that rather than zeroing it with the rest of the
cache. The message is not reachable from any real prediction, and `warmUp()`
proves the encoder is live before the first hold. There is no way to suppress it
from Swift; it is written directly by the CoreML runtime.

### The audio tap

**The tap block must be built in a `nonisolated` context.** `AVAudioNodeTapBlock`
is an imported Objective-C block typedef and so is not `@Sendable`, which means a
closure literal written inside a `@MainActor` function silently *inherits*
main-actor isolation. Swift 6 then emits an isolation check at the top of the
block — and that check calls `dispatch_assert_queue` on the audio render thread,
fails, and traps the process:

```
EXC_BREAKPOINT in _swift_task_checkIsolatedSwift
  <- swift_task_isCurrentExecutorWithFlags
  <- closure #1 in AudioCapture.buildEngine()
  <- AVAudioNodeTap::TapMessage::RealtimeMessenger_Perform()
```

It fires on the first captured buffer, so the symptom is "the app dies the
instant you hold the key" — with a stack that points at audio, not at isolation.
`AudioCapture.makeTapBlock` is a `nonisolated static func` for exactly this
reason. Marking the closure `@Sendable` would also detach it, but
`AVAudioConverter` and `AVAudioPCMBuffer` are not `Sendable` and could not then
be captured. `wizard-cli listen` exercises this path outside the app.

Beyond that, the tap callback does no allocation and takes no locks: preallocated conversion buffers, a hoisted converter input block,
`vDSP_rmsqv` for the level, and a lock-free SPSC ring for the samples. On
`AVAudioEngineConfigurationChange` — a device swap, a sample-rate change,
headphones going in — the engine is rebuilt and the tap reinstalled without
ending the session.

## Model tiers

All four are selectable in the dashboard; the streaming maths is driven entirely
by each tier's `metadata.json`.

| tier | chunk | published WER | note |
|---|---|---|---|
| 160 ms | 16 mel frames | ~10% | removed from HF `main`; pinned to commit `c7e2cf6a` |
| **560 ms** | 56 | **2.12%** | default |
| 1120 ms | 112 | 1.99% | the model's trained chunk size |
| 2240 ms | 224 | 2.46% | highest throughput |

## Layout

```
Sources/WizardKit/       framework — everything that is not the UI
  Model/                 tier, metadata, tokenizer, framing, installer
  ASR/                   model bundle, StreamingASR actor, file loader
  Audio/                 ring buffer, level box, AVAudioEngine capture
  Trigger/               CGEventTap hotkey monitor, TCC permissions
  Session/               session types, DictationCoordinator
  Paste/                 pasteboard snapshot, Cmd-V, restore
  History/               transcript history
  Support/               errors, logging, MLArrayReader, settings
Sources/WizardApp/       the menu-bar app: delegate, flow bar, popover, dashboard
Sources/wizardcli/       the development harness
Tests/WizardKitTests/    37 tests, including end-to-end recognition
```

## Licence

The model is NVIDIA's, under the NVIDIA Open Model License.

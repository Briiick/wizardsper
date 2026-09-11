# Wizardsper

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

Measured on this machine (M4 Pro) over 73 utterances of LibriSpeech dev-clean
(1150 reference words), scored with the usual abbreviation normalisation:

| tier | WER | speed |
|---|---|---|
| 560 ms | **4.96%** | 47× realtime |
| 160 ms | 5.39% | 4.8× realtime |

Two caveats worth stating plainly. This is *dev-clean* — one chapter of dense art
criticism, heavy with proper nouns — not the *test-clean* set the publisher's
2.12% figure comes from, so the numbers are not comparable. And the 160 ms tier's
published figure is "~10% on 20 files"; through this front-end it measures within
half a point of the 560 ms tier, so if you want the lower latency it is a real
option. Reproduce either with `wizardsper-cli`.

## Getting it running

```bash
./Scripts/build-app.sh          # generates the Xcode project, builds, signs
open build/Build/Products/Debug/Wizardsper.app
```

The first launch downloads the 560 ms model (~615 MB) into
`~/Library/Application Support/Wizardsper/Models/`. To pre-seed it instead:

```bash
./Scripts/fetch-model.sh 560 ~/Library/Application\ Support/Wizardsper/Models
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

The Hardened Runtime is on, so `Resources/Wizardsper.entitlements` must carry
`com.apple.security.device.audio-input` even though the app is not sandboxed:
that key is the runtime's Audio Input capability, not only a sandbox key.
`NSMicrophoneUsageDescription` alone is not enough — without the entitlement,
`AVCaptureDevice.requestAccess` returns `false` within milliseconds and no prompt
is ever shown, which is indistinguishable from the user denying one.

## Verifying a change

```bash
./Scripts/verify.sh
```

Builds the library, the CLI and the app bundle, runs the tests, rasterises the
flow bar's transcript view to prove it is not drawing outside the pill,
transcribes a file with a known transcript, and exercises the live capture path
against a real microphone. The last one matters more than it looks: the render-thread tap block
is the single easiest place in this codebase to introduce a crash that compiles
cleanly and passes every unit test.

## The CLI harness

The recognition path is developed and checked against files before any
microphone is involved.

```bash
swift build -c release

.build/release/wizardsper-cli probe
    # every model's real input/output signatures, and the framing arithmetic

.build/release/wizardsper-cli transcribe speech.wav --reference "ground truth"
    # transcript, realtime factor, WER

.build/release/wizardsper-cli sweep speech.wav --reference "ground truth"
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

Over the 73-utterance corpus above, through the 560 ms tier:

| policy | lookback / lookahead / offset | WER | edits | added latency |
|---|---|---|---|---|
| **fullContext** (default) | 256 / 256 / 2 | **4.96%** | 58 | 16 ms |
| none | 0 / 0 / 0 | 4.96% | 58 | none |
| windowAligned | 400 / 0 / 2 | 5.13% | 60 | none |
| lowLatency | 240 / 0 / 1 | 5.30% | 62 | none |
| wide | 512 / 512 / 3 | 5.30% | 62 | 32 ms |

**Measurement does not separate these.** The whole spread is four edits in 1169
words, which is noise at this sample size — an earlier run on just eight
utterances ranked them differently. So the default is not "the one that won"; it
is chosen on the one property that does distinguish them, with the measurement
serving only to confirm it is not worse: `fullContext` is the only policy under
which every frame handed to the encoder is computed entirely from real audio,
with no part of any analysis window falling in the preprocessor's own zero
padding. It costs 256 samples — 16 ms — of lookahead.

If that 16 ms ever matters, `windowAligned` gives up only the last frame's final
16 samples to get it back.

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

### The vocabulary is fuzzy on purpose, and gated on sound

The model has 1024 SentencePiece pieces of general English. Proper nouns outside
that distribution do not come back wrong — they were never candidates. "Claude"
arrives as "cloud", "clawed" or "clod", and speaking more clearly cannot help,
because the model is not choosing between those and the right answer.

Correcting afterwards has to be fuzzy: a list of exact spellings would need every
mis-hearing enumerated in advance, and the interesting ones are the ones nobody
predicted. But fuzziness is dangerous in the other direction — a list that
rewrites ordinary words corrupts transcripts that were already correct, silently.

Edit distance alone cannot do it. Against "Claude", measured:

| must correct | distance | | must not | distance |
|---|---|---|---|---|
| cloud | 0.33 | | clouds | 0.33 |
| clode | 0.33 | | cloudy | 0.33 |
| clawed | 0.50 | | loud, code, class, claim | 0.50 |
| clod | 0.50 | | called, closed, cold, crowd | 0.67 |

The words that must be corrected and the words that must not are at *identical*
distances. So a match beyond 0.2 additionally requires the same consonant
skeleton — a compact Metaphone-style key that folds "claude", "cloud" and
"clawed" onto `klt` while leaving `klts` (clouds), `klty` (cloudy) and `klst`
(closed) distinct. Distance proposes; phonetics disposes.

Writing the tests is what found the hole: the first key dropped a trailing "y",
which collapsed "cloudy" onto "claude" and would have rewritten it silently.

### The transcript scrolls only when it has to

The pill shows one line, laid out left to right, with each word fading in where
it belongs. Nothing slides: a word that moves into place draws the eye to the
movement rather than to the word, and with a partial arriving every few hundred
milliseconds that becomes the most distracting thing on screen.

Overflow is the part that needs care. Left-aligned with `.truncationMode(.tail)`,
the moment speech runs past the pill's width the *new* words are the ones cut
off — the bar freezes on the opening of the sentence and stops reporting what is
happening now, which is the one job a live meter has. So the line stays
left-aligned while it fits and scrolls only once it would overflow, by exactly
the amount that has run off the end. A short dictation never moves at all.

Word identity is the array index, which is safe because greedy RNN-T only
appends: an emitted token is never revised, so word *n* stays word *n*. The final
word grows in place as more sub-word pieces arrive, and SwiftUI updates that one
without a transition — correct, since completing a word is not the same as
starting one.

### Input gain is not a quality knob

The dashboard has a microphone gain slider, and it is deliberately paired with a
live meter rather than offered on its own — because the control is not monotonic.
Measured on one utterance against a constant noise floor, 560 ms tier:

| signal level | no gain | 16× gain |
|---|---|---|
| normal | **0.00%** | 5.88% |
| 10% | 0.00% | 0.00% |
| 4% | 0.00% | 0.00% |
| 2% | 23.53% | **5.88%** |
| 1% | *empty transcript* | 88.24% |

Scaling clean audio down barely matters: the model still scored 0.00% on speech
attenuated to 4% of full scale, because the log-mel front end and the encoder's
layer norms are indifferent to absolute level. What hurts is a weak *microphone*,
which is a different thing — it scales the voice down against its own fixed noise
floor, so SNR falls with the level, and that is where gain earns its place.

Turn it up on a healthy signal and it clips, taking a perfect transcript to 5.88%.
A slider with no feedback invites exactly that mistake, which is why
`InputGainSection` draws the usable band behind the meter and says when the
setting has gone too far in either direction.

### A harmless noise at load

Every model load prints this to stderr, once:

```
E5RT encountered an STL exception. msg = Failed to PropagateInputTensorShapes:
std::runtime_error during type inference for ios17.slice_by_index: zero shape error.
```

It is CoreML building the encoder's *default* function, where `cache_len` is 0
and the graph's slice over the cache therefore has zero length. Nothing in Wizardsper
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
be captured. `wizardsper-cli listen` exercises this path outside the app.

**The converter's input block must be pre-bridged.** `AVAudioConverterInputBlock`
imports into Swift as a plain closure, and `convertToBuffer:error:withInputFromBlock:`
is declared *without* `NS_NOESCAPE`. Passing a Swift closure therefore bridges it
to an Objective-C block on every call, and bridging an escaping closure means
`_Block_copy` — a malloc, per audio buffer, on the render thread. Declaring the
stored property as `@Sendable @convention(block)` bridges it once at init and
reduces the per-call cost to a retain.

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
Sources/WizardsperKit/       framework — everything that is not the UI
  Model/                 tier, metadata, tokenizer, framing, installer
  ASR/                   model bundle, StreamingASR actor, file loader
  Audio/                 ring buffer, level box, AVAudioEngine capture
  Trigger/               CGEventTap hotkey monitor, TCC permissions
  Session/               session types, DictationCoordinator
  Paste/                 pasteboard snapshot, Cmd-V, restore
  History/               transcript history
  Support/               errors, logging, MLArrayReader, settings
Sources/WizardsperApp/       the menu-bar app: delegate, flow bar, popover, dashboard
Sources/wizardspercli/       the development harness
Tests/WizardsperKitTests/    37 tests, including end-to-end recognition
```

## Licence

The model is NVIDIA's, under the NVIDIA Open Model License.

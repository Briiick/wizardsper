# Contributing

## Getting it running

```bash
./Scripts/build-app.sh          # generates the Xcode project, builds, signs
open build/Build/Products/Debug/Wizardsper.app
```

The first launch downloads a ~615 MB model. To pre-seed it:

```bash
./Scripts/fetch-model.sh 560 ~/Library/Application\ Support/Wizardsper/Models
```

## Before you open a pull request

```bash
./Scripts/verify.sh
```

That builds all three targets, runs the tests, rasterises the flow bar to prove
it is not drawing outside the pill, transcribes a file with a known transcript,
and exercises the live capture path against a real microphone.

The last two matter more than they look. Three of the worst bugs in this
project's history were invisible to every test that does not run the real thing:

- a tap block that inherited actor isolation and trapped on the audio render
  thread — it compiled clean and passed the whole suite
- a missing Hardened Runtime entitlement that made microphone access fail in 8 ms
  with no prompt ever shown
- a transcript view that drew straight out through the window

If you change the audio path or the flow bar's layout, run `verify.sh` and look
at what it says rather than trusting a green build.

## House style

Comments explain **why**, never what. A short paragraph above a type saying why
it exists and what breaks without it; a line above any non-obvious decision.
If a constant was chosen by measurement, say what was measured. There are several
examples in `Sources/WizardsperKit/Model/` — read one before writing new code.

Swift 6 language mode, strict concurrency, no force-unwraps, no swallowed errors.

## Things that look like bugs and are not

- The CoreML `slice_by_index: zero shape error` printed once at model load. It
  is the encoder's default function being built with an empty cache; no real
  prediction ever runs that path. See `StreamingASR.reset()`.
- Transcripts never ending with punctuation before `TranscriptPolish` runs. The
  recogniser only emits a sentence-final mark when it hears the next sentence
  begin, and a hold ends before that.

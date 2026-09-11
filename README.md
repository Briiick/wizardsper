# Wizardsper

Hold a key, talk, release. The transcript lands in whatever app you were already
typing in. Everything runs on your Mac — no account, no network, no telemetry.

Menu-bar only: no Dock tile, no window, and it never takes focus.

<sub>macOS 26 · Apple silicon · MIT</sub>

## Install

```bash
./Scripts/build-app.sh
open build/Build/Products/Debug/Wizardsper.app
```

First launch downloads the speech model (~615 MB) into
`~/Library/Application Support/Wizardsper/Models/`.

macOS will ask for three permissions. All three are load-bearing:

| | why |
|---|---|
| Microphone | capture |
| Input Monitoring | seeing the dictation key |
| Accessibility | pasting into other apps |

## Use

Hold **fn**, speak, release. Settings live in the menu-bar icon → Dashboard:

- **Vocabulary** — words the recogniser can't produce ("Claude", a surname), corrected by sound
- **Clean-up** — optionally rewrite the transcript into written English with Apple's on-device model
- **Microphone** — input gain, with a live meter
- **History** — past transcripts, kept 7 days by default

## Develop

```bash
./Scripts/verify.sh    # build, test, layout check, transcribe a known file, drive the mic
```

There's a CLI for working on recognition without a microphone:

```bash
swift build -c release
.build/release/wizardsper-cli transcribe speech.wav --reference "ground truth"
.build/release/wizardsper-cli sweep speech.wav --reference "ground truth"
.build/release/wizardsper-cli listen
```

See [CONTRIBUTING.md](CONTRIBUTING.md). The reasoning behind the tricky parts is
in the code comments, next to the code it explains.

## Licence

Wizardsper is MIT ([LICENSE](LICENSE)).

The speech model is not: it's NVIDIA's `nemotron-speech-streaming-en-0.6b` under
the NVIDIA Open Model License, downloaded at runtime and never redistributed
here. Read [NOTICE.md](NOTICE.md) before anything commercial.

Not on the Mac App Store: the store requires the sandbox, and a global event tap
and synthetic paste can't be done from inside one.

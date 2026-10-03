# Meeting Assistant

Native macOS floating panel for meetings: live on-device transcription of
system audio, an LLM Chinese translation under every paragraph, and a reply
hint when someone addresses you by name.

## What it does

- Captures everything the Mac plays (Zoom, Teams, Meet, browser) through a
  CoreAudio Process Tap, excluding itself.
- Transcribes on-device with macOS 26 `SpeechAnalyzer` / `SpeechTranscriber`
  (Japanese or English). No extra models, no backend.
- Translates each finished paragraph into Simplified Chinese with
  `gpt-5.4-mini`, using the previous three paragraphs as context.
- When a paragraph contains your name (`セキさん / 石さん / 関さん / 席さん /
  Seki ...`), it shows a banner (no sound, so nothing leaks into the call),
  waits for the speaker to pause, and streams a reply hint from `gpt-5.4`:
  what they are asking, 2-3 points in Chinese, and 1-3 sentences you can say
  in the meeting language. The hint sees up to the last 12,000 characters of
  the meeting (about 35 min of Japanese), so "any questions?" after a long
  talk is answered from the whole talk.
- `⌘⇧Return` (global) or the speech-bubble button asks for a reply hint at any
  time. `⌘⇧L` toggles Japanese / English.

## Requirements

- macOS 26+, Xcode 27+
- An OpenAI API key

## Run

```bash
open MeetingAssistant.xcodeproj   # then Run (⌘R)
```

or from the command line:

```bash
xcodebuild -project MeetingAssistant.xcodeproj -scheme MeetingAssistant -derivedDataPath .derived-data build
open .derived-data/Build/Products/Debug/MeetingAssistant.app
```

First launch:

1. Click the gear and paste your OpenAI API key (stored in the login
   keychain). For development, `OPENAI_API_KEY` in the Xcode scheme also works.
2. Press play. macOS asks for Speech Recognition and System Audio Recording
   permission; the on-device speech model downloads once per language.

Permission prompts stick more reliably to an app bundle at a fixed path than
to a DerivedData build that moves around.

## Settings

| Setting | Default |
|---|---|
| Translation model | `gpt-5.4-mini` |
| Reply hint model | `gpt-5.4` |
| Knowledge folder | `~/Desktop/Meeting/knowledge` |
| Your name aliases | `セキさん, せきさん, 石さん, 関さん, 席さん, 積さん, seki` |

## Knowledge

Put meeting background (agenda, glossary, facts you can state) in
`knowledge/*.md`; see `knowledge/README.md`. Edits apply to the next request.

## How paragraphs are formed

SpeechTranscriber reports volatile text and then a final result per phrase.
During continuous speech SpeechTranscriber keeps one growing volatile text
and may not finalize it for a long time, so paragraphs are cut at the text
level: as soon as the live text holds a sentence or two (about 40 Japanese /
120 English characters), everything up to the last sentence end becomes a
paragraph and is translated. A paragraph also closes when the speaker pauses
(no recognizer update for 0.6s and the audio quiet for 0.6s). Breaks fall on
sentence ends; a long monologue is never cut mid-sentence by a timer.

## Checks

```bash
./scripts/check.sh
```

Compiles the pure logic (name detection, paragraph assembly, prompts, SSE
parsing, translation cleanup) with `Checks/MeetingChecks.swift` and runs it.

## Stealth

The eye button sets the window's `sharingType` to `.none` (default on). This is
best effort: capture stacks built on ScreenCaptureKit may still record it.
Test with the tools you actually use.

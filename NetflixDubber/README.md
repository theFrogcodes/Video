# Netflix Dubber — live Japanese → English AI dubbing for macOS

A native macOS app (Swift / SwiftUI) that dubs Japanese Netflix shows into English **as you watch**:

- **Listens to what your Mac is playing** (Netflix in Safari, Chrome, Edge, Firefox, Arc, …) and mutes the original Japanese track while it runs.
- **Recognises who is speaking.** An on-device neural voiceprint (WeSpeaker via [FluidAudio](https://github.com/FluidInference/FluidAudio), on the Neural Engine) identifies each voice in the scene.
- **Creates a new English voice automatically for every new speaker.** A deep male voice gets a deep English voice, a high/young voice gets a bright one, and so on. Every character keeps their voice for the rest of the session.
- **Dubs each line a few seconds after it's spoken** (typically 2–4 s, depending on the providers you choose). Speech recognition, then Claude translation that fits the line's timing and tone, then text-to-speech in that character's voice. The original soundtrack is lowered (ducked) under the dub so music and effects stay audible.

```
 Netflix audio ──► Core Audio process tap (original muted) ──┬──► pass-through, ducked ───────────────┐
                                                             │                                        ▼
                                                             └─► 16 kHz ─► speech detector ─► line   speakers
                                                                   ┌──────────────────────────┘       ▲
                                         ┌─────────────────────────┼──────────────────────────┐       │
                                         ▼                         ▼                          │       │
                            voiceprint ─► speaker registry   Japanese ASR ─► Claude ─► TTS in that  ──┘
                            (on-device)   (new voice? create   (OpenAI or     (EN line +   speaker's
                                           a voice profile)     Apple)        delivery)    voice
```

## Requirements

| | |
|---|---|
| Mac | Apple Silicon MacBook (Intel works, slower speaker recognition) |
| macOS | 15 Sequoia or later (Core Audio process taps + Neural Engine models) |
| Toolchain | Xcode 16 or later (Swift 6 compiler) |
| API keys | **Anthropic** (required, for translation). **OpenAI** (optional, for the most accurate Japanese recognition and expressive voices) |

## Build and run

```bash
cd NetflixDubber
make run            # builds "build/Netflix Dubber.app", ad-hoc signs it and opens it
```

`make app` only builds, `make test` runs the unit tests. You can also open `Package.swift` in Xcode and run the `NetflixDubber` scheme. Use the `.app` from `make app` for real use, though: macOS attaches the audio-capture permission to the app bundle.

## First run

1. **Settings (⌘,) › API Keys**: paste your Anthropic key and, optionally, your OpenAI key. Keys are stored in the macOS Keychain.
2. **Settings › Dubbing**: choose the providers:
   - *Speech recognition*: **OpenAI gpt-4o-transcribe** (best on noisy TV audio) or **Apple on-device** (free and private; needs Japanese installed for Dictation).
   - *Translation model*: **Claude Opus 5** (best translations, the default), Sonnet 5, or **Haiku 4.5** (lowest latency).
   - *English voices*: **Apple system voices** (free, instant; download "Enhanced" or "Premium" voices in System Settings › Accessibility › Spoken Content for much better quality) or **OpenAI voices** (acted, emotional delivery that follows each line's tone).
3. Open Netflix in your browser and pick a show with **Japanese audio**.
4. Press **Start dubbing** (⌘D), then play the episode. The first time, macOS asks to allow **System Audio Recording**. Allow it. On the very first start, the voice-recognition model is downloaded and cached.

While it runs:

- **Voices** panel: every detected speaker, their pitch range and assigned voice. You can preview a voice, pick a different one, or switch dubbing off for one speaker (e.g. to keep a narrator in Japanese).
- **Live transcript**: Japanese, English, delivery note, status and per-line latency.
- **Original audio while dubbing**: how loud the soundtrack stays under the dub (15% by default; 0% to hear only English).
- **New-voice sensitivity**: slide towards *Split* if two characters share one voice, or towards *Merge* if one character keeps getting new voices.

Press **Stop** (or quit the app) and your Mac's normal audio is restored immediately.

## How it stays in sync

- **Line detection** uses an adaptive-noise-floor speech detector tuned for TV audio with a music bed. Lines are cut at pauses and never run past 6 s.
- **Lines run in parallel.** Voiceprint and speech recognition run at the same time, and several lines are in flight at once. Dubs still always **play in spoken order**.
- **Catch-up**: when the dub falls behind, playback speeds up (up to 1.35×, pitch preserved). Lines that would play more than 7 s late (configurable) are dropped rather than played out of sync.
- **Translation fits the time**: Claude gets the line's duration, a target word count, the speaker, and the last few lines of dialogue, so names, tone and relationships stay consistent.
- **Recognition noise is filtered.** Speech recognisers fed music or silence tend to invent stock phrases such as ご視聴ありがとうございました ("thanks for watching"); these, song lyrics and caption artefacts are skipped.

## Privacy and fair use

- **Speaker recognition always runs on your Mac.**
- Speech recognition: with OpenAI, each line's audio is sent to OpenAI; with Apple, audio never leaves the Mac.
- Translation: the Japanese text of each line, plus recent lines for context, is sent to Anthropic.
- Voices: with OpenAI, the English text is sent to OpenAI; Apple voices run on-device.
- Nothing is recorded or written to disk. Video is never captured.
- The app does **not** touch Netflix's DRM or streams. It only hears the Mac's audio output, the same way accessibility live-caption tools do. Dubbing is for your own viewing: follow Netflix's terms and don't record or redistribute dubbed audio.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "No sound is being captured" | Make sure the episode is playing. Then allow Netflix Dubber in System Settings › Privacy & Security › **Screen & System Audio Recording** and press Start again. |
| Dub stops after plugging in headphones | Changing the output device resets capture. Press Start again. |
| One character keeps changing voice | Move *New-voice sensitivity* towards **Merge**. |
| Two characters share a voice | Move it towards **Split**, or assign a different voice in the Voices panel. |
| Dub is far behind | Use **Claude Haiku 4.5** and **Apple voices** for the lowest latency, or lower *Drop dubs later than* in Settings. |
| Music or sound effects trigger lines | Loud score can look like speech. Those lines are usually filtered out (empty or "not dialogue" translations), but they still cost a recognition request. |
| "Neural voice recognition couldn't load" | The model download failed (network/firewall). The app falls back to a built-in spectral voiceprint, which works but is less precise with similar voices. |
| Keychain prompts after rebuilding | Expected with ad-hoc signing: a rebuilt binary is a "new" app to the Keychain. Choose *Always Allow*. |

## Code map

```
NetflixDubber/
├── Package.swift
├── Sources/DubberCore/              Platform-independent logic (unit-tested)
│   ├── DSP/                         Streaming resampler, FFT, MFCC, YIN pitch
│   ├── Segmentation/                Voice-activity detector, utterance segmenter
│   ├── Speakers/                    Online speaker registry, offline fallback voiceprint
│   ├── Voices/                      Voice profiles, automatic voice designer, delivery styles
│   ├── Pipeline/                    DubPipeline actor, ordered release, pacing and ducking
│   ├── Services/                    Claude translator, OpenAI ASR/TTS, HTTP (retry, error mapping)
│   └── Text/                        Transcript clean-up and hallucination filter
├── Sources/NetflixDubber/           The macOS app
│   ├── Audio/                       Core Audio process tap, real-time buffers, AVAudioEngine mixer
│   ├── Speech/                      Apple on-device recognition and voices
│   ├── Speakers/                    Neural voiceprints (FluidAudio / WeSpeaker)
│   ├── Settings/                    Preferences, Keychain storage
│   ├── UI/                          SwiftUI views
│   └── DubbingController.swift      Session lifecycle: capture → pipeline → playback
├── Tests/DubberCoreTests/           DSP, segmentation, speakers, voices, services, pipeline
├── Resources/Info.plist             Bundle info and permission strings
└── scripts/build-app.sh             Builds and ad-hoc signs the .app
```

CI (`.github/workflows/netflix-dubber.yml`) builds the app, runs the tests and packages the bundle on a macOS runner. Run it manually with **release** checked to download a ready-built `.app`.

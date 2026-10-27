<div align="center">

<img src=".github/assets/icon.png" width="128" height="128" alt="Melete app icon: a glass water clock, half full of Egyptian-blue water">

# Melete

**A daily speaking studio for your Mac.**<br>
Shadow great speakers, talk through your own topics, and get one clear note on what to fix next.<br>
Recordings, transcripts and stats stay on your Mac, unless you turn on listening notes.

[**Download for macOS**](https://github.com/oliverxuzy-ai/Melete/releases/latest/download/Melete.dmg) · [Features](#features) · [How it works](#how-it-works) · [Design](docs/DESIGN.md) · [简体中文](README.zh-CN.md)

[![Latest release](https://img.shields.io/github/v/release/oliverxuzy-ai/Melete?style=flat-square&color=2C4AA0&label=release)](https://github.com/oliverxuzy-ai/Melete/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/oliverxuzy-ai/Melete/total?style=flat-square&color=AD7D21)](https://github.com/oliverxuzy-ai/Melete/releases)
[![Build](https://img.shields.io/github/actions/workflow/status/oliverxuzy-ai/Melete/release.yml?branch=main&style=flat-square&label=build)](https://github.com/oliverxuzy-ai/Melete/actions/workflows/release.yml)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-1A1916?style=flat-square&logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-1A1916?style=flat-square)
![Local first](https://img.shields.io/badge/data-stays%20on%20your%20Mac-3B7650?style=flat-square)
[![MIT license](https://img.shields.io/github/license/oliverxuzy-ai/Melete?style=flat-square&color=1A1916)](LICENSE)

<img src=".github/assets/screenshots/en/window-shadow-live-light.webp" width="880" alt="Shadowing a clip in Melete: as you speak, waves rise on the water clock, its halo swells and turns, and the subtitles move along with you">

</div>

> *Μελέτη* is Greek for "practice". Melete was also the oldest of the three original Muses: Melete for practice, Mneme for memory, Aoide for voice. Those are the three things this app is for: practice every day, remember the key points, and train your voice.

## Why Melete

Most speaking feedback is the same few lines: slow down, speak up, fewer "um"s, vary your tone. Knowing that is easy. Practicing it every day is the hard part, and every bit of friction is a reason to skip a day.

So Melete opens on today's next exercise. Press <kbd>Return</kbd>, a water clock fills for three seconds, and you're recording. When you stop, Whisper transcribes on your Mac and you get one sentence on the most important thing to change, measured against your own recent baseline rather than a generic norm.

## Features

### One window, three places

- **Overview.** This week's laurel in the middle. On the left, how you're trending (pace, filler words, pitch range, key-point coverage). On the right, your rhythm (minutes per day, streak, the next talk on your agenda).
- **Shadow.** Listen to how a real speaker says it, then speak along or retell it in your own words. Tap any line of the transcript to start from there. With speakers, the original stays quiet while you record and the subtitles follow *your* voice, using on-device recognition with about 0.3 s of lag. With headphones, the original plays in your ears and the subtitles follow it.
- **Topic.** Speak to a prompt, a script, or a meeting you're preparing for.

<p align="center">
  <img src=".github/assets/screenshots/en/window-home-min-light.png" width="32%" alt="The Overview: this week's laurel in the middle, your trends on the left, your rhythm and the next talk on the right">
  <img src=".github/assets/screenshots/en/window-retell-min-light.png" width="32%" alt="Retell: today's argument clip, ready to be retold in your own words">
  <img src=".github/assets/screenshots/en/window-verdict-min-light.png" width="32%" alt="The critique card after an impromptu take: a one-line verdict, four numbers and two things to try">
  <br>
  <sub>The Overview · Retelling a clip in your own words · The note you get after every take</sub>
</p>

### Feedback that tells you one thing

- **Local transcription** with [faster-whisper](https://github.com/SYSTRAN/faster-whisper), in English or Mandarin.
- **A critique card** after every take: a one-line verdict, up to four numbers this training block cares about, and at most three things to try next time. The full analysis is one click away.
- **Intonation, sentence by sentence.** Pitch and loudness are measured every 10 ms and cut into sentences with Whisper's word timings: how each sentence ends (falls, rises, stays level, or fades out), which word you stressed, and stretches where your pitch hardly moves. When you shadow, your tune is compared with the speaker's sentence by sentence, in semitones from each voice's own median.
- **Listening notes (optional).** With an OpenRouter key, Gemini listens to the take and says how it sounds: tone, confidence, energy, a note per sentence and one thing to try. It gets Melete's measurements along with the audio and is told to take them as given, since audio models are poor at measuring pitch and pace themselves.
- **Your own targets.** Pace targets start from your recent median and rise each week of a pace block. Loudness is compared only with your last five takes, because decibels depend on the mic and the distance.
- **Retelling is scored by meaning**, not word for word: each key point is marked covered, partly covered, or missed.

### A plan, so you never have to pick

- **A nine-week training cycle**, like a running plan: Τάχος pace and volume (2 weeks), Τόνος intonation and pauses (2), Μῦθος storytelling (2), Πρόσωπον speaking to different audiences (2), Ἀνάπαυσις taper (1). You can pin one block in Settings.
- **Daily clips.** Every morning Melete cuts one or two 90-second clips from talks and lectures: a story to shadow and an argument to retell. Paste any YouTube link (add `&t=` to start there) to make your own.
- **Impromptu prompts** in the forms of the ancient Greek rhetoric schools (narrative, chreia, description, comparison, thesis, rebuttal and more), about things you actually talk about at work.
- **Agenda.** Add an upcoming talk (an architecture review, a 1:1, an interview) and Melete counts back six prep steps, like a taper before a race.
- **Weekly review**, Mac notifications, and optional reminders on your phone through [ntfy.sh](https://ntfy.sh).

### Always one keystroke away

- <kbd>⌃</kbd><kbd>⌥</kbd><kbd>R</kbd> from any app starts today's next item.
- The laurel in the menu bar shows today's plan.
- The analysis server starts in the background. You can record before it is ready; the audio waits and is analyzed as soon as it is.

### Private by design

Audio, transcripts and statistics are stored only in `~/Library/Application Support/SpeechPractice/`. Your recordings are not uploaded unless you turn on listening notes; then each take is sent through OpenRouter to the model you chose, routed only to providers that neither store nor train on requests. Otherwise Melete goes online only to download the speech models once, to fetch daily clip audio with yt-dlp, and, if you turn them on, to send phone reminders through ntfy or ask Claude to pick a clip.

## Install

1. Download [**Melete.dmg**](https://github.com/oliverxuzy-ai/Melete/releases/latest/download/Melete.dmg) from the [latest release](https://github.com/oliverxuzy-ai/Melete/releases/latest), open it, and drag Melete into Applications.
2. Melete is not notarized yet, so the first time you open it macOS says it cannot verify the developer. Open **System Settings → Privacy & Security** and click **Open Anyway**, or run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Melete.app
   ```

3. For daily clips, install yt-dlp and FFmpeg:

   ```sh
   brew install yt-dlp ffmpeg
   ```

| Requirement | |
|---|---|
| macOS | 26 Tahoe or later |
| Chip | Apple Silicon |
| Disk | About 500 MB for the English model, downloaded on first launch. The Mandarin model (about 1.6 GB) loads the first time you record in Mandarin. |
| Permissions | Microphone, and Speech Recognition for live subtitles |
| Interface | Simplified Chinese or English. Switch any time in Settings > Language. |

## Quick start

1. Melete opens on **Overview**. Press <kbd>Return</kbd> to jump to today's next item. The water clock fills for three seconds, then recording starts.
2. Press <kbd>Space</kbd> to stop. The critique card appears, and **Next** takes you to the next item. Not happy halfway through? Press <kbd>Esc</kbd> and the take is neither saved nor analyzed.
3. Finishing any one item counts as practicing today.

| Shortcut | Action |
|---|---|
| <kbd>Return</kbd> | Start today's next item |
| <kbd>Space</kbd> | Stop recording |
| <kbd>Esc</kbd> | Discard the take, or close a panel |
| <kbd>⌘</kbd><kbd>R</kbd> | Start or stop recording |
| <kbd>⌘</kbd><kbd>1</kbd> to <kbd>⌘</kbd><kbd>3</kbd> | Overview, Shadow, Topic |
| <kbd>⌘</kbd><kbd>4</kbd> | All recordings |
| <kbd>⌘</kbd><kbd>N</kbd> | New script |
| <kbd>⌘</kbd><kbd>,</kbd> | Settings |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>R</kbd> | Start today's next item from any app |

### Optional: Claude

Add an Anthropic API key in **Settings → Claude**. Once a day, Claude picks the best clip from the candidates the local rules found, and writes a title plus two notes on where the speaker pauses and what they stress. The default model is Claude Opus 5.5; you can switch to Sonnet 5.5 or Haiku 5.5. Without a key, or if a request fails, Melete falls back to the local rules. The key is stored only in `settings.json` on your Mac, readable only by you.

### Optional: listening notes

Add an OpenRouter API key in **Settings → Listening**. After each take, once the local analysis is shown, the recording goes to Gemini 3.8 Flash (or the cheaper 3.5 Flash-Lite) with the numbered sentences and the measured pace, endings and stress. Usually within half a minute, its notes fill in under the verdict and in the full analysis: the overall tone, confidence and energy, a note per sentence, one tip. A two-minute take costs about one cent. The notes are never scored, and if a request fails the local analysis stands as it is. Takes over ten minutes are not sent.

## How it works

```mermaid
flowchart LR
  subgraph mac["Your Mac"]
    app["Melete.app<br/>SwiftUI"]
    server["Analysis server<br/>FastAPI + faster-whisper"]
    data[("Application Support/<br/>SpeechPractice")]
    speech["Apple Speech<br/>on-device"]
    app -- "recordings over 127.0.0.1" --> server
    server --> data
    app -. "live subtitles" .- speech
  end
  server -. "daily clips (optional)" .-> yt["YouTube<br/>via yt-dlp"]
  server -. "clip picking (optional)" .-> claude["Claude API"]
  server -. "listening notes (optional)" .-> gemini["OpenRouter<br/>Gemini"]
```

The native app bundles a Python analysis server, so there is nothing else to install or run.

**Models.** English uses Whisper `small` (about 500 MB; a 60-second take is ready in about 8 seconds) and is warmed up at launch. Mandarin uses `large-v3-turbo` (about 1.6 GB), loaded only when you first record in Mandarin. They are split on purpose: `small` drops sentences and mixes in traditional characters on Mandarin, while `turbo` swallows English fillers like "like" and "um" that `small` keeps.

<details>
<summary><b>What each metric means</b></summary>

| Metric | Meaning |
|---|---|
| Pace | Words per minute over the whole take. The target band comes from your own baseline and rises each week of a pace block. |
| Pace without pauses | Words per minute of actual speaking time |
| Pause | A gap of 0.5 seconds or more between two words |
| Filler words | um, uh, like, you know, I mean, basically… |
| Hedges | maybe, I think, just, kind of… |
| Loudness | Compared only with your last five takes, because absolute decibels depend on the mic and distance |
| Pitch range | Rough range of the fundamental frequency, in semitones. A small range can sound monotone. |
| Key-point coverage | The source is split into key points by sentence, and each is judged covered, partly covered, or missed by meaning |

The metrics are heuristics for tracking yourself, not professional measurements. The filler and hedge word lists live at the top of `analysis.py`, and are mirrored in `native/Sources/SpeechPractice/SessionDetailView.swift` and `static/index.html`; change them together.

</details>

## Build from source

You need Xcode 26 and [uv](https://docs.astral.sh/uv/).

```sh
git clone https://github.com/oliverxuzy-ai/Melete.git
cd Melete
./build_native.sh            # builds dist/Melete.app
./build_native.sh --install  # also copies it to /Applications (quit the app first)
```

`--install` replaces an older `SpeechPractice.app`. The bundle ID is unchanged, so history, exercises and settings carry over.

<details>
<summary><b>Development mode and debug flags</b></summary>

Run the analysis server on its own:

```sh
./run.sh            # or .venv/bin/python server.py
```

Flags for `dist/Melete.app/Contents/MacOS/SpeechPractice`:

- `SPEECH_SERVER_URL=http://127.0.0.1:8765` connects to the dev server instead of starting the bundled one.
- `--lang en|zh` runs in that interface language for one launch without changing your setting. `--render`, `--e2e` and the other test harnesses run in Chinese unless `--lang` is given.
- `--space home|shadow|topic` opens a place directly; `--tray settings|history|clips|agenda|newTopic|newEvent|addLink` opens a panel.
- `--selftest` decodes every endpoint against `SPEECH_SERVER_URL`, then exits.
- `--render <dir>` renders every place to light and dark PNGs offscreen, then exits (`RENDER_ONLY=home,settings` renders a subset). Launch it with `open`, because SwiftUI does not open the main window when the binary is run directly:
  `open -n --env SPEECH_SERVER_URL=http://127.0.0.1:8765 dist/Melete.app --args --render /tmp/render`
- `--e2e <report>` runs the end-to-end test: `MELETE_FAKE_MIC=<wav>` stands in for the microphone and goes through the real upload, transcription and critique, writing PASS or FAIL per check, including frame intervals while recording. `--perf <report>` measures only the frame rate while speaking. Point both at a server that uses a copy of your data.

Server environment variables:

- `SPEECH_DATA_DIR` uses another data directory (a copy, for tests).
- `SPEECH_NO_DAILY=1` turns off the daily clip job; `DAILY_START_DELAY` sets how many seconds it waits after launch (default 120).
- `WHISPER_MODEL=medium` and `WHISPER_MODEL_ZH=medium` change the English and Mandarin models.

Test the clip pipeline offline:

```sh
.venv/bin/python daily.py --local audio-file "Title" "Speaker" story
```

</details>

<details>
<summary><b>Project layout</b></summary>

| Path | What it is |
|---|---|
| `native/` | The SwiftUI app. `Theme.swift` holds the design tokens; `Components.swift` the water clock, laurel and pace gauge; `RootView.swift` the window and top navigation; `HomeView.swift` the Overview; `StudioView.swift` the Shadow and Topic studios; `Stage.swift` the stage and critique card; `Trays.swift` the panels; `SettingsPanel.swift` Settings; `SystemIntegration.swift` notifications, the global hotkey, launch at login and the menu bar; `L10n.swift` the interface language; `E2E*.swift` the end-to-end tests. |
| `server.py` | FastAPI server |
| `coach.py` | Training cycle, targets, prompts, daily plan, agenda, critique, weekly review |
| `daily.py` | Daily clip pipeline and background job |
| `i18n.py` | Which language the server writes plans, critiques and notes in, following the app |
| `analysis.py` | Transcription and metrics. `coverage.py` scores key points; `shadow.py` aligns shadowing subtitles. |
| `build_assets/` | The app icon in Icon Composer format, generated by `make_icon.swift` and compiled by `make_icon.sh` |
| `static/`, `app.py`, `build_app.sh` | The old web version, no longer maintained |

</details>

### Releases

Every push to `main` builds Melete on GitHub Actions and publishes a release with `Melete.dmg`, `Melete.zip` and their checksums. Pull requests get the same build as a downloadable workflow artifact. Version numbers follow the commit messages since the last release:

| Commit message | Bump | Example |
|---|---|---|
| anything | patch | 2.0.0 → 2.0.1 |
| starts with `feat:`, or contains `#minor` | minor | 2.0.1 → 2.1.0 |
| contains `BREAKING CHANGE` or `!:`, or `#major` | major | 2.1.0 → 3.0.0 |

To jump to a specific version, raise `CFBundleShortVersionString` in `native/Resources/Info.plist`. You can also release by hand from **Actions → Build & Release → Run workflow** and choose the bump. Changes that only touch Markdown, `docs/` or the screenshots don't trigger a release.

### Screenshots

The app draws the screenshots in this README itself, from three weeks of made-up practice (`.github/screenshots/seed.py`) rather than anyone's recordings. After a UI change, run **Actions → Screenshots → Run workflow** on your branch: it draws English and Chinese in the light look and commits the images to that branch. The moving picture at the top is 15 seconds of frames drawn the same way and joined into an animated WebP. On a Mac with the app built, `.github/screenshots/render.sh` does the same locally (it needs `brew install webp`), with its own data folder and port, so your history is not touched.

## Design

Ancient marble was never white. Greek temples and statues were painted, with pigment only where it mattered: Egyptian blue behind a relief, cinnabar in the folds of a robe, gold on a laurel. Melete works the same way. The ground is quiet marble and paper, and each pigment does exactly one job.

![kyanos: your voice and anything you can press](https://img.shields.io/badge/kyanos-your%20voice%2C%20anything%20you%20can%20press-2C4AA0?style=flat-square)
![cinnabar: the microphone is on](https://img.shields.io/badge/cinnabar-the%20mic%20is%20on-C23A1E?style=flat-square)
![ochre: rewards](https://img.shields.io/badge/ochre-rewards-AD7D21?style=flat-square)
![malachite: on target](https://img.shields.io/badge/malachite-on%20target-3B7650?style=flat-square)

The colors, type, materials, motion and the reasoning behind each decision are in [docs/DESIGN.md](docs/DESIGN.md).

## Acknowledgments

- [faster-whisper](https://github.com/SYSTRAN/faster-whisper) and [CTranslate2](https://github.com/OpenNMT/CTranslate2), running OpenAI's [Whisper](https://github.com/openai/whisper) models
- [FastAPI](https://fastapi.tiangolo.com) and [Uvicorn](https://www.uvicorn.org)
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [FFmpeg](https://ffmpeg.org)
- [ntfy](https://ntfy.sh) for phone reminders
- Design references: Dia by The Browser Company, bencho.dev, 60fps.design, and Benji Taylor's Family

## License

Melete is released under the [MIT License](LICENSE).

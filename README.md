# MyMeds UK — AI Video Ad Generator

> This repository also contains **[Netflix Dubber](NetflixDubber/README.md)**, a macOS app for live Japanese → English AI dubbing of Netflix shows.

Generates a 45–55 second vertical (9:16) promotional video for TikTok / Instagram Reels / YouTube Shorts using:
- Real app screenshots (provided by you)
- AI voiceover via ElevenLabs (British male voice)
- Ken Burns pan/zoom effects via FFmpeg
- Styled text overlays via Pillow
- ASS subtitles
- Optional royalty-free background music (Pixabay)

---

## Quick Start

### 1. Install dependencies

```bash
pip install -r requirements.txt
sudo apt install ffmpeg        # Ubuntu/Debian
# brew install ffmpeg          # macOS
```

### 2. Set API keys

```bash
export ELEVENLABS_API_KEY=your_elevenlabs_key_here
export REPLICATE_API_TOKEN=your_replicate_token_here
# Optional — for background music:
# export PIXABAY_API_KEY=your_key
```

### 3. Copy your screenshots

Copy app screenshots into `assets/screenshots/` using these exact filenames:

| Filename | Source file | Scene |
|----------|-------------|-------|
| `01_hero_composite.png` | 112C2A9D-9ED3-4B42-9A45-551CFFD5EE8B.png | Scene 10 — CTA |
| `02_medications_list.jpeg` | IMG_3680.jpeg | Scene 4 — Search |
| `03_chat_roger.jpeg` | IMG_3679.jpeg | Scene 5 — AI Chat |
| `04_drug_interaction.jpeg` | IMG_3678.jpeg | Scene 6 — Interactions |
| `05_medication_calendar.jpeg` | IMG_3677.jpeg | Scene 7 — Reminders |
| `06_compliance_history.jpeg` | IMG_3676.jpeg | (reference) |
| `07_document_privacy.jpeg` | IMG_3675.jpeg | Scene 9 — Privacy |
| `08_lcd_interaction.jpeg` | IMG_3674.jpeg | (reference) |
| `09_chat_card.jpeg` | IMG_3672.jpeg | (reference) |
| `10_calendar_card.jpeg` | IMG_3671.jpeg | (reference) |
| `11_medications_card.png` | IMG_3673.png | (reference) |
| `12_reminders_screen.jpeg` | IMG_3644.png | (reference) |
| `13_epipen_documents.png` | IMG_3640.png | (reference) |
| `14_medication_calendar_raw.png` | IMG_3637.png | (reference) |
| `15_welcome_screen.png` | IMG_3623.png | (reference) |
| `16_subscription_screen.png` | IMG_3622.png | (reference) |
| `17_nhs_prescription.jpeg` | IMG_3583.jpeg | Scene 8 — NHS |
| `18_social_ad.jpeg` | IMG_3581.jpeg | Scene 2 — Problem |
| `19_logo.jpeg` | IMG_3456.jpeg | Scene 3 — Intro |

### 4. Generate the video

```bash
python main.py
```

Output lands in `output/MyMeds_UK_Ad_<timestamp>.mp4`.

---

## Options

| Flag | Description |
|------|-------------|
| `--preview` | Low-res 540x960 test render (much faster) |
| `--no-music` | Skip background music |
| `--no-subs` | Skip subtitles |

Example preview run:
```bash
python main.py --preview --no-music
```

---

## Project Structure

```
mymeds-video-ad/
├── main.py                     # CLI entry point
├── pipeline/
│   ├── script_generator.py     # Hardcoded 10-scene script
│   ├── voice_generator.py      # ElevenLabs TTS
│   ├── image_processor.py      # Pillow frame processing + text overlays
│   ├── motion_engine.py        # Ken Burns via FFmpeg zoompan
│   ├── subtitle_engine.py      # ASS subtitle generation
│   ├── music_mixer.py          # Background music handling
│   └── video_assembler.py      # FFmpeg final composition
├── utils/
│   ├── config.py               # Paths, API keys, brand colours
│   └── prompts.py              # (reference only)
├── assets/
│   ├── screenshots/            # Copy your app screenshots here
│   ├── logo/
│   └── fonts/                  # Optional: Inter-Bold.ttf / Poppins-Bold.ttf
├── output/                     # Final video output
└── temp/                       # Intermediate files (auto-cleaned)
```

---

## Scene Breakdown

| # | Name | Duration | Screenshot used |
|---|------|----------|-----------------|
| 1 | HOOK | 5s | None — dark gradient |
| 2 | THE_PROBLEM | 6s | 18_social_ad.jpeg |
| 3 | INTRODUCE_SOLUTION | 5s | 19_logo.jpeg |
| 4 | FEATURE_SEARCH | 5s | 02_medications_list.jpeg |
| 5 | FEATURE_AI_CHAT | 7s | 03_chat_roger.jpeg |
| 6 | FEATURE_INTERACTIONS | 5s | 04_drug_interaction.jpeg |
| 7 | FEATURE_REMINDERS | 5s | 05_medication_calendar.jpeg |
| 8 | FEATURE_NHS | 5s | 17_nhs_prescription.jpeg |
| 9 | TRUST_PRIVACY | 5s | 07_document_privacy.jpeg |
| 10 | CTA_CLOSE | 7s | 01_hero_composite.png |

---

## Customising

Edit `pipeline/script_generator.py` to change:
- `narration` — what Roger says
- `text_overlay` — on-screen text
- `motion` — `slow_zoom_in`, `slow_zoom_out`, `pan_up_slow`, `pan_down_slow`, `gentle_pulse_zoom`
- `duration_seconds` — hint duration (actual audio length overrides this)
- `voice_id` — swap ElevenLabs voice

## Brand Colours

| Name | Hex |
|------|-----|
| Primary Purple | `#7B2FBE` |
| Light Purple | `#D8B4FE` |
| Gradient Dark Start | `#1a0a2e` |
| Gradient Dark End | `#4a1a6b` |
| Accent Pink | `#E879F9` |

---

## Estimated Cost

| Item | Cost |
|------|------|
| ElevenLabs (~200 words) | ~£0.08 (free tier covers this) |
| Screenshots (real app images) | £0.00 |
| FFmpeg | Free |
| **Total** | **~£0.08** |

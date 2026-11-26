<div align="center">

# Lexora

**English** | [Türkçe](README.tr.md)

An offline-first English vocabulary learning and dictionary app built with Flutter, featuring a 737K+ word monolingual dictionary, spaced repetition (SRS), contextual Cloze reviews, dual US/UK pronunciations, and a native Android home screen widget.

![Flutter](https://img.shields.io/badge/Flutter-02569B?style=flat&logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-0175C2?style=flat&logo=dart&logoColor=white)
![Kotlin](https://img.shields.io/badge/Kotlin-7F52FF?style=flat&logo=kotlin&logoColor=white)
![Python](https://img.shields.io/badge/Python-3776AB?style=flat&logo=python&logoColor=white)
![SQLite](https://img.shields.io/badge/SQLite-003B57?style=flat&logo=sqlite&logoColor=white)

</div>

---

## Features

- **Offline Monolingual Dictionary (737,261 entries):** Built from English Wiktionary data via Kaikki.org with fast local SQLite search and interactive clickable definitions (`ClickableText`).
- **Structured Daily Learning Flow:**
  - **Placement & Setup:** Calibrates starting CEFR level (B1–C2) and daily study routine.
  - **Morning Sessions:** Introduces new vocabulary with definitions, examples, and pronunciation audio.
  - **Evening Cloze Tests:** Reinforces retention through fill-in-the-blank contextual recall.
  - **Spaced Repetition (SRS):** Automatically schedules reviews based on recall performance.
- **Dual Accent Pronunciations:** Supports both American (US) and British (UK) English transcriptions and audio playback with validated Wikimedia Commons streaming and local fallback.
- **Native 2×2 Android Home Screen Widget:** Displays vocabulary cards directly on the home screen with CEFR level badges (`B1`, `B2`, `C1`, `C2`), background sync, and manual refresh.
- **Personal Vocabulary Notebook:** Save, organize, and revisit words directly from dictionary lookups or study sessions.
- **Privacy-First & Portable:** Zero backend, zero accounts, zero tracking. Includes schema-validated JSON backup and restore for user progress.

---

## Architecture

Lexora separates static lexical data from mutable user state using a **dual-SQLite architecture**:

1. **Read-Only Dictionary (`vocab_dict.db`):** Bundled as a gzip-compressed asset (`vocab_dict.db.gz`, approx. 85 MB compressed / 266 MB uncompressed) and verified against `assets/vocab_dict.meta.json` (SHA-256). On first launch, a native Kotlin extractor (`DictExtractor.kt`) streams and decompresses the database directly to internal storage without high Dart-heap memory overhead.
2. **User Database (`user_data.db`):** Stores SRS schedules, session logs, placement settings, and personal notebook entries locally.
3. **Python ETL Pipeline (`tools/build_vocab_db.py`):** Parses raw Kaikki.org Wiktionary JSONL dumps into the indexed, compressed SQLite database and generates integrity metadata.
4. **Hardened Release Configuration:** Configured with R8/ProGuard keep rules, Android `network_security_config.xml`, `data_extraction_rules.xml`, and strict URL/backup validators covered by unit tests.

---

## Project Structure

```text
Lexora/
├── android/
│   └── app/
│       ├── proguard-rules.pro              # R8 / Gson / Notification keep rules
│       └── src/main/kotlin/.../
│           ├── MainActivity.kt             # Platform channel & deep link host
│           ├── DictExtractor.kt            # Native gzip dictionary extractor
│           └── VocabWidgetProvider.kt      # Native 2x2 home screen AppWidget
├── assets/
│   └── vocab_dict.meta.json                # Dictionary schema & SHA-256 metadata
├── lib/
│   ├── main.dart                           # Application entry point
│   ├── core/                               # Constants, date utils, text normalization
│   ├── models/                             # Word entry data models
│   ├── router/                             # Navigation & deep-link routing
│   ├── screens/                            # Dashboard, sessions, cloze, dictionary, notebook, settings
│   ├── services/                           # SRS engine, SQLite, audio, backup, notifications, widget sync
│   ├── state/                              # Application state providers
│   ├── theme/                              # Dark-first Lexora UI theme
│   └── widgets/                            # Accent audio rows, clickable text, branding
├── test/                                   # Unit tests (SRS, Cloze, validators, deep links, normalizer)
└── tools/
    ├── build_vocab_db.py                   # Kaikki.org JSONL -> SQLite ETL pipeline
    └── generate_brand_assets.py            # App icon & splash asset generator
```

---

## Getting Started

> **Note:** The pre-built dictionary binary (`assets/vocab_dict.db.gz`) is excluded from Git due to GitHub's 100 MB file limit. Generate it locally with the included Python ETL script before building the app.

### Prerequisites

- **Flutter SDK** (3.x) & **Android SDK**
- **Python 3.10+** (for building the dictionary database)

### 1. Clone the Repository

```bash
git clone https://github.com/KeRmOdLeZ/Lexora.git
cd Lexora
```

### 2. Build the Offline Dictionary Database

Run the ETL script to download and process the English Wiktionary dump, generating `assets/vocab_dict.db.gz` and `assets/vocab_dict.meta.json`:

```bash
python tools/build_vocab_db.py
```

### 3. Install Dependencies & Run Tests

```bash
flutter pub get
flutter test
```

### 4. Run or Build Release APK

```bash
# Run on a connected Android device
flutter run

# Build a release APK
flutter build apk --release
```

---

## Data Attribution

- **Dictionary Data:** Sourced from [Wiktionary](https://en.wiktionary.org/) via [Kaikki.org](https://kaikki.org/), licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
- **Pronunciation Audio:** Streamed on demand from [Wikimedia Commons](https://commons.wikimedia.org/) where available, under their respective Creative Commons / Public Domain licenses.
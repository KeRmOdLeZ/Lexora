#!/usr/bin/env python3
"""
Lexora v2.0.0 — Offline Monolingual Dictionary ETL Pipeline
Builds read-only vocab_dict.db.gz + vocab_dict.meta.json for Android assets.

Modes:
  --sample : Builds a deterministic 120+ word balanced sample dictionary immediately.
  --full   : Streams Kaikki English Wiktionary JSONL (remote HTTPS or --input),
             stages into tools/.cache/staging.db (<150 MB RAM), applies CEFR mapping,
             validates Wikimedia audio paths, and exports optimized SQLite + gzip + meta.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import json
import os
import re
import sqlite3
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

DEFAULT_KAIKKI_URL = "https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl"
USER_AGENT = "LexoraAndroid/2.0.0 (Offline Monolingual Dictionary; Android)"
SCHEMA_VERSION = 2

# Exact security validator matching Dart AudioService
WIKIMEDIA_PREFIX = "https://upload.wikimedia.org/wikipedia/commons/"
SAFE_AUDIO_REL_RE = re.compile(r"^[a-zA-Z0-9/_\.\-\(\)%]+$")
FORBIDDEN_ENC_RE = re.compile(r"(%2e|%2f|%5c|%00|%0a|%0d)", re.IGNORECASE)
ALLOWED_AUDIO_EXTS = (".ogg", ".oga", ".mp3")

EXCLUDED_POS = frozenset({
    "affix", "prefix", "suffix", "punct", "symbol", "character",
    "combining_form", "infix", "interfix", "circumfix", "proverb",
    "punctuation", "letter", "number", "numeral",
})

CEFR_LEVELS = ("A1", "A2", "B1", "B2", "C1", "C2")
STUDY_LEVELS = ("B1", "B2", "C1", "C2")

_BIDI_AND_CTRL_RE = re.compile(
    r"[\x00-\x1F\x7F-\x9F\u200E\u200F\u202A-\u202E\u2066-\u2069]"
)
_MULTI_SPACE_RE = re.compile(r"\s+")
_HAS_LATIN_RE = re.compile(r"[A-Za-z\u00C0-\u024F\u1E00-\u1EFF]")


def normalize_query(text: str) -> str:
    """Exact 1:1 mirror of Dart normalizeQuery(String input)."""
    s = text.strip()
    # Turkish dotted/dotless I normalization before lowercasing
    s = s.replace("İ", "i").replace("ı", "i").replace("\u0307", "")
    s = s.lower()
    # Curly quotes/apostrophes to ASCII
    s = (
        s.replace("\u2018", "'")
        .replace("\u2019", "'")
        .replace("\u201A", "'")
        .replace("\u201B", "'")
        .replace("\u2032", "'")
        .replace("\u201C", '"')
        .replace("\u201D", '"')
        .replace("\u201E", '"')
        .replace("\u201F", '"')
        .replace("\u2033", '"')
    )
    # Strip C0/C1, BiDi controls and non-BMP codepoints
    s = _BIDI_AND_CTRL_RE.sub("", s)
    s = "".join(ch for ch in s if ord(ch) <= 0xFFFF)
    # Collapse whitespace
    s = _MULTI_SPACE_RE.sub(" ", s).strip()
    return s


def strip_diacritics_ascii(text: str) -> str:
    """Produce ASCII alias for accented words (e.g., naïve -> naive, résumé -> resume)."""
    decomposed = unicodedata.normalize("NFKD", text)
    stripped = "".join(ch for ch in decomposed if unicodedata.category(ch) != "Mn")
    return normalize_query(stripped)


def validate_wikimedia_relative_path(url_or_rel: str | None) -> str | None:
    """Extract and validate a Wikimedia Commons relative audio path matching Dart AudioService."""
    if not url_or_rel or not isinstance(url_or_rel, str):
        return None
    raw = url_or_rel.strip()
    if raw.startswith(WIKIMEDIA_PREFIX):
        rel = raw[len(WIKIMEDIA_PREFIX):]
    elif raw.startswith("https://") or raw.startswith("http://"):
        return None
    else:
        rel = raw

    if not rel or rel.startswith("/") or len(rel) > 512:
        return None
    lower_rel = rel.lower()
    if not lower_rel.endswith(ALLOWED_AUDIO_EXTS):
        return None
    if not SAFE_AUDIO_REL_RE.match(rel):
        return None
    if FORBIDDEN_ENC_RE.search(rel):
        return None
    if ".." in rel or "\\" in rel:
        return None
    try:
        decoded = urllib.parse.unquote(rel, errors="strict")
    except Exception:
        return None
    if ".." in decoded or "\\" in decoded or "\x00" in decoded or "\n" in decoded or "\r" in decoded:
        return None
    if decoded.startswith("/"):
        return None
    return rel


class HttpsOnlyRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Reject any downgrade to non-HTTPS during download redirects."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        resolved = urllib.parse.urljoin(req.full_url, newurl)
        parsed = urllib.parse.urlparse(resolved)
        if parsed.scheme.lower() != "https":
            raise urllib.error.URLError(f"Blocked non-HTTPS redirect to {resolved}")
        return super().redirect_request(req, fp, code, msg, headers, resolved)


def download_with_resume(url: str, dest: Path) -> Path:
    """Download Kaikki dataset via HTTPS-only handler with HTTP Range resume and atomic .part file."""
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme.lower() != "https":
        raise ValueError(f"Only HTTPS download URLs are permitted: {url}")

    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 1024:
        print(f"Using cached dataset: {dest}")
        return dest

    part_path = dest.with_suffix(dest.suffix + ".part")
    existing_size = part_path.stat().st_size if part_path.exists() else 0

    opener = urllib.request.build_opener(HttpsOnlyRedirectHandler())
    headers = {"User-Agent": USER_AGENT}
    if existing_size > 0:
        headers["Range"] = f"bytes={existing_size}-"

    req = urllib.request.Request(url, headers=headers)
    print(f"Downloading {url} (resume offset: {existing_size} bytes)...", flush=True)

    with opener.open(req, timeout=60) as resp:
        status = getattr(resp, "status", 200)
        mode = "ab" if (existing_size > 0 and status == 206) else "wb"
        if mode == "wb":
            existing_size = 0
        total_written = existing_size
        with open(part_path, mode) as out_f:
            while True:
                chunk = resp.read(256 * 1024)
                if not chunk:
                    break
                out_f.write(chunk)
                total_written += len(chunk)
                if total_written % (50 * 1024 * 1024) < len(chunk):
                    print(f"  Downloaded {total_written / (1024 * 1024):.1f} MB...", flush=True)

    part_path.replace(dest)
    print(f"Download complete: {dest} ({dest.stat().st_size} bytes)", flush=True)
    return dest


def open_jsonl_auto(path: Path):
    """Auto-detect gzip via first 2 magic bytes 0x1f 0x8b and open as UTF-8 text stream."""
    with open(path, "rb") as f:
        magic = f.read(2)
    if magic == b"\x1f\x8b":
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return open(path, "r", encoding="utf-8", errors="replace")


def create_output_schema(conn: sqlite3.Connection) -> None:
    conn.execute("PRAGMA page_size = 8192;")
    conn.execute("PRAGMA journal_mode = OFF;")
    conn.execute("PRAGMA synchronous = OFF;")
    conn.execute("PRAGMA cache_size = -65536;")
    conn.execute(
        """
        CREATE TABLE words (
            word_key TEXT PRIMARY KEY,
            word_display TEXT NOT NULL,
            level TEXT,
            primary_pos TEXT NOT NULL,
            meaning_en TEXT NOT NULL,
            senses TEXT NOT NULL,
            examples TEXT NOT NULL,
            cloze_example TEXT,
            synonyms TEXT NOT NULL,
            ipa_us TEXT,
            ipa_uk TEXT,
            audio_us TEXT,
            audio_uk TEXT
        );
        """
    )
    conn.execute(
        """
        CREATE TABLE word_forms (
            form TEXT NOT NULL,
            word_key TEXT NOT NULL,
            PRIMARY KEY (form, word_key)
        ) WITHOUT ROWID;
        """
    )


def create_output_indexes_and_finalize(conn: sqlite3.Connection) -> int:
    # Remove any orphan word_forms rows
    conn.execute(
        """
        DELETE FROM word_forms
        WHERE NOT EXISTS (
            SELECT 1 FROM words w WHERE w.word_key = word_forms.word_key
        );
        """
    )
    conn.execute("CREATE INDEX idx_cefr_key ON words(word_key) WHERE level IS NOT NULL;")
    conn.execute("CREATE INDEX idx_cefr_level_key ON words(level, word_key) WHERE level IS NOT NULL;")
    conn.execute(
        """
        CREATE INDEX idx_study_pool
        ON words(level, primary_pos, word_key)
        WHERE level IN ('B1','B2','C1','C2') AND cloze_example IS NOT NULL;
        """
    )
    conn.commit()
    conn.execute("VACUUM;")
    conn.execute("PRAGMA optimize;")
    check_row = conn.execute("PRAGMA integrity_check;").fetchone()
    if not check_row or check_row[0] != "ok":
        raise RuntimeError(f"SQLite integrity_check failed: {check_row}")
    count_row = conn.execute("SELECT COUNT(*) FROM words;").fetchone()
    return int(count_row[0]) if count_row else 0


def export_compressed_assets(db_path: Path, output_dir: Path, word_count: int, is_sample: bool) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    gz_path = output_dir / "vocab_dict.db.gz"
    meta_path = output_dir / "vocab_dict.meta.json"

    sha256 = hashlib.sha256()
    uncompressed_size = 0
    tmp_gz = output_dir / "vocab_dict.db.gz.tmp"

    with open(db_path, "rb") as src, gzip.open(tmp_gz, "wb", compresslevel=9) as gz_out:
        while True:
            buf = src.read(65536)
            if not buf:
                break
            sha256.update(buf)
            uncompressed_size += len(buf)
            gz_out.write(buf)

    tmp_gz.replace(gz_path)

    meta = {
        "schema_version": SCHEMA_VERSION,
        "uncompressed_sha256": sha256.hexdigest(),
        "uncompressed_size": uncompressed_size,
        "compressed_size": gz_path.stat().st_size,
        "word_count": word_count,
        "is_sample": is_sample,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    meta_path.write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(
        f"Exported {gz_path} ({meta['compressed_size']} B gz / {uncompressed_size} B raw), "
        f"words={word_count}, is_sample={is_sample}, sha256={meta['uncompressed_sha256'][:16]}..."
    )


# ---------------------------------------------------------------------------
# SAMPLE DATASET: 120 balanced entries (10 A1, 10 A2, 25 B1, 25 B2, 25 C1, 25 C2)
# ---------------------------------------------------------------------------

def _make_sample_entries() -> list[dict[str, Any]]:
    """
    Returns 120 curated, monolingual English entries:
      10 A1, 10 A2, 25 B1, 25 B2, 25 C1, 25 C2.
    Includes required words: schedule, vitamin, either, privacy, advertisement,
    compare, naïve, résumé, carry out, plus rich word_forms inflections and
    ASCII aliases for accented headwords.
    """
    # Compact tuple format:
    # (word, level, pos, meaning, extra_senses, example1, example2, synonyms, ipa_us, ipa_uk, audio_us, audio_uk, forms)
    raw_rows: list[tuple[Any, ...]] = [
        # ==================== A1 (10) ====================
        ("book", "A1", "noun", "A written or printed work consisting of pages bound together.",
         [("verb", ["To reserve accommodation, a ticket, or a place in advance."])],
         "She borrowed an interesting book from the local library.",
         "We need to book a table before the restaurant gets busy.",
         ["volume", "novel"], "/bʊk/", "/bʊk/", None, None, ["books", "booked", "booking"]),
        ("water", "A1", "noun", "A clear, colorless liquid essential for most plant and animal life.",
         [("verb", ["To pour or sprinkle water over a plant or area."])],
         "Please drink plenty of fresh water after exercising.",
         "Remember to water the garden early in the morning.",
         ["liquid", "fluid"], "/ˈwɔːtər/", "/ˈwɔːtə/", None, None, ["waters", "watered", "watering"]),
        ("house", "A1", "noun", "A building designed for people to live in.",
         [("verb", ["To provide living space or shelter for someone or something."])],
         "Their wooden house overlooks a quiet valley.",
         "The museum can house thousands of rare paintings.",
         ["home", "residence"], "/haʊs/", "/haʊs/", None, None, ["houses", "housed", "housing"]),
        ("friend", "A1", "noun", "A person whom one knows well and regards with affection and trust.",
         [],
         "My closest friend moved to another city last autumn.",
         "A loyal friend stays calm when difficulties arise.",
         ["companion", "ally"], "/frɛnd/", "/frɛnd/", None, None, ["friends"]),
        ("happy", "A1", "adjective", "Feeling or showing pleasure, joy, or contentment.",
         [],
         "The children looked happy playing near the fountain.",
         "She was genuinely happy with the final result.",
         ["glad", "cheerful"], "/ˈhæpi/", "/ˈhæpi/", None, None, ["happier", "happiest"]),
        ("learn", "A1", "verb", "To gain knowledge or skill through study, practice, or experience.",
         [],
         "Adults can learn a new language with consistent daily habits.",
         "He wants to learn how to play classical guitar.",
         ["study", "master"], "/lɜːrn/", "/lɜːn/", None, None, ["learns", "learned", "learnt", "learning"]),
        ("write", "A1", "verb", "To mark letters, words, or symbols on a surface or compose text.",
         [],
         "Try to write a short sentence for each word you review.",
         "She plans to write an article about urban gardens.",
         ["compose", "record"], "/raɪt/", "/raɪt/", None, None, ["writes", "wrote", "written", "writing"]),
        ("quick", "A1", "adjective", "Moving fast or doing something in a short amount of time.",
         [],
         "Let us take a quick break before the next session.",
         "A quick glance at the timetable confirmed the departure.",
         ["fast", "rapid"], "/kwɪk/", "/kwɪk/", None, None, ["quicker", "quickest"]),
        ("speak", "A1", "verb", "To say words aloud in order to express thoughts or converse.",
         [],
         "Could you speak a little more slowly so everyone understands?",
         "Both engineers speak fluent English and Spanish.",
         ["talk", "converse"], "/spiːk/", "/spiːk/", None, None, ["speaks", "spoke", "spoken", "speaking"]),
        ("morning", "A1", "noun", "The period of time between sunrise and noon.",
         [],
         "A crisp morning walk helps clear the mind before work.",
         "She reviews seven vocabulary cards every morning.",
         ["dawn", "forenoon"], "/ˈmɔːrnɪŋ/", "/ˈmɔːnɪŋ/", None, None, ["mornings"]),

        # ==================== A2 (10) ====================
        ("travel", "A2", "verb", "To make a journey, typically of some length or abroad.",
         [("noun", ["The action of journeying from one place to another."])],
         "Many commuters travel by rail to avoid heavy traffic.",
         "Frequent travel broadened her perspective on architecture.",
         ["journey", "voyage"], "/ˈtrævəl/", "/ˈtrævəl/", None, None, ["travels", "traveled", "travelled", "traveling", "travelling"]),
        ("decide", "A2", "verb", "To come to a resolution in the mind after consideration.",
         [],
         "They will decide the meeting date once everyone replies.",
         "It took hours to decide which route was safest.",
         ["choose", "determine"], "/dɪˈsaɪd/", "/dɪˈsaɪd/", None, None, ["decides", "decided", "deciding"]),
        ("weather", "A2", "noun", "The state of the atmosphere with respect to wind, temperature, and rain.",
         [("verb", ["To withstand or come safely through a difficult period."])],
         "Mild weather made the coastal hike enjoyable.",
         "Check the weather forecast before packing for the trip.",
         ["climate", "conditions"], "/ˈwɛðər/", "/ˈwɛðə/", None, None, ["weathered", "weathering"]),
        ("prepare", "A2", "verb", "To make something or someone ready for use or consideration.",
         [],
         "Students should prepare clear notes ahead of the seminar.",
         "The chef began to prepare fresh soup at dawn.",
         ["arrange", "ready"], "/prɪˈpɛr/", "/prɪˈpɛə/", None, None, ["prepares", "prepared", "preparing"]),
        ("improve", "A2", "verb", "To make or become better in quality, skill, or condition.",
         [],
         "Regular spaced repetition will steadily improve your recall.",
         "The city plans to improve public cycling lanes.",
         ["enhance", "refine"], "/ɪmˈpruːv/", "/ɪmˈpruːv/", None, None, ["improves", "improved", "improving"]),
        ("quiet", "A2", "adjective", "Making little or no noise; peaceful and undisturbed.",
         [("noun", ["Absence of noise or bustle; calm."])],
         "The reading room stayed remarkably quiet all afternoon.",
         "We found a quiet cafe tucked behind the bookstore.",
         ["silent", "calm"], "/ˈkwaɪət/", "/ˈkwaɪət/", None, None, ["quieter", "quietest"]),
        ("borrow", "A2", "verb", "To take and use something belonging to someone else with intent to return it.",
         [],
         "May I borrow your dictionary for a couple of minutes?",
         "Readers may borrow up to five volumes per month.",
         ["loan", "use"], "/ˈbɑːroʊ/", "/ˈbɒrəʊ/", None, None, ["borrows", "borrowed", "borrowing"]),
        ("explain", "A2", "verb", "To make an idea or situation clear by describing it in detail.",
         [],
         "Can you explain why this formula produces a different value?",
         "The guide paused to explain the history of the bridge.",
         ["clarify", "describe"], "/ɪkˈspleɪn/", "/ɪkˈspleɪn/", None, None, ["explains", "explained", "explaining"]),
        ("healthy", "A2", "adjective", "In a good physical or mental condition; promoting well-being.",
         [],
         "A balanced diet and sound sleep keep the brain healthy.",
         "Regular stretching supports healthy posture during long flights.",
         ["fit", "well"], "/ˈhɛlθi/", "/ˈhɛlθi/", None, None, ["healthier", "healthiest"]),
        ("reason", "A2", "noun", "A cause, explanation, or justification for an action or event.",
         [("verb", ["To think, understand, and form judgments logically."])],
         "There is a practical reason why the archive stays offline.",
         "She gave a convincing reason for rescheduling the talk.",
         ["cause", "motive"], "/ˈriːzən/", "/ˈriːzən/", None, None, ["reasons", "reasoned", "reasoning"]),

        # ==================== B1 (25) ====================
        ("schedule", "B1", "noun", "A plan for carrying out a process or procedure, giving lists of intended events and times.",
         [("verb", ["To arrange or plan an event to take place at a particular time."])],
         "The train departed strictly on schedule despite the fog.",
         "Let us schedule the design review for Thursday morning.",
         ["timetable", "agenda"], "/ˈskɛdʒuːl/", "/ˈʃɛdjuːl/",
         "3/3c/En-us-schedule.ogg", "9/9a/En-uk-schedule.ogg",
         ["schedules", "scheduled", "scheduling"]),
        ("vitamin", "B1", "noun", "Any of a group of organic compounds essential for normal growth and nutrition.",
         [],
         "Fresh citrus fruit provides an abundant source of vitamin C.",
         "Doctors recommend checking vitamin levels during winter.",
         ["nutrient", "supplement"], "/ˈvaɪtəmɪn/", "/ˈvɪtəmɪn/",
         "a/a8/En-us-vitamin.ogg", "d/d1/En-uk-vitamin.ogg",
         ["vitamins"]),
        ("either", "B1", "adverb", "Used to indicate a link with a preceding negative statement, or one of two alternatives.",
         [("determiner", ["One or the other of two people or things."])],
         "I do not enjoy noisy cafes, and my colleague does not either.",
         "You may choose either route to reach the harbor.",
         ["likewise", "neither"], "/ˈiːðər/", "/ˈaɪðə/",
         "5/57/En-us-either.ogg", "f/f8/En-uk-either.ogg",
         []),
        ("privacy", "B1", "noun", "A state in which one is not observed, disturbed, or tracked by other people.",
         [],
         "Storing study logs locally protects user privacy by design.",
         "The courtyard hedge offers welcome privacy from the street.",
         ["confidentiality", "solitude"], "/ˈpraɪvəsi/", "/ˈprɪvəsi/",
         "6/65/En-us-privacy.ogg", "1/1c/En-uk-privacy.ogg",
         []),
        ("advertisement", "B1", "noun", "A notice or announcement in a public medium promoting a product, service, or event.",
         [],
         "A concise advertisement on the noticeboard attracted twenty volunteers.",
         "The magazine refused to print any misleading advertisement.",
         ["commercial", "promotion"], "/ˌædvərˈtaɪzmənt/", "/ədˈvɜːtɪsmənt/",
         "0/09/En-us-advertisement.ogg", "2/2f/En-uk-advertisement.ogg",
         ["advertisements", "advert", "ad"]),
        ("compare", "B1", "verb", "To estimate, measure, or note the similarity or dissimilarity between things.",
         [],
         "Always compare American and British pronunciations when studying new vocabulary.",
         "Analysts compared quarterly metrics across three regions.",
         ["contrast", "evaluate"], "/kəmˈpɛr/", "/kəmˈpɛə/", None, None,
         ["compares", "compared", "comparing"]),
        ("carry out", "B1", "verb", "To perform, conduct, or complete a task, experiment, or instruction.",
         [],
         "The engineering team will carry out thorough testing before launch.",
         "Inspectors carried out an audit of every safety log.",
         ["execute", "conduct"], "/ˈkæri aʊt/", "/ˈkæri aʊt/", None, None,
         ["carries out", "carried out", "carrying out"]),
        ("achieve", "B1", "verb", "To successfully bring about or reach a desired objective through effort.",
         [],
         "Consistent practice helps learners achieve lasting fluency.",
         "The project achieved all of its energy efficiency targets.",
         ["accomplish", "attain"], "/əˈtʃiːv/", "/əˈtʃiːv/", None, None,
         ["achieves", "achieved", "achieving"]),
        ("encourage", "B1", "verb", "To give support, confidence, or hope to someone.",
         [],
         "Mentors encourage junior developers to ask clear questions.",
         "Gentle reminders encourage steady daily study habits.",
         ["motivate", "inspire"], "/ɪnˈkɜːrɪdʒ/", "/ɪnˈkʌrɪdʒ/", None, None,
         ["encourages", "encouraged", "encouraging"]),
        ("manage", "B1", "verb", "To be in charge of, administer, or succeed in coping with a task.",
         [],
         "Clear priorities make it easier to manage a demanding week.",
         "She managed to finish the translation before noon.",
         ["handle", "direct"], "/ˈmænɪdʒ/", "/ˈmænɪdʒ/", None, None,
         ["manages", "managed", "managing"]),
        ("predict", "B1", "verb", "To say or estimate that a specified thing will happen in the future.",
         [],
         "Meteorologists can predict coastal storms several days ahead.",
         "Few observers predicted such rapid adoption of offline tools.",
         ["forecast", "anticipate"], "/prɪˈdɪkt/", "/prɪˈdɪkt/", None, None,
         ["predicts", "predicted", "predicting"]),
        ("reduce", "B1", "verb", "To make smaller or less in amount, degree, or size.",
         [],
         "Caching audio files locally can dramatically reduce mobile data usage.",
         "Insulating the roof helped reduce winter heating bills.",
         ["decrease", "lower"], "/rɪˈduːs/", "/rɪˈdjuːs/", None, None,
         ["reduces", "reduced", "reducing"]),
        ("benefit", "B1", "noun", "An advantage or profit gained from something.",
         [("verb", ["To receive an advantage or profit from something."])],
         "One major benefit of offline dictionaries is instant lookup speed.",
         "Both beginners and advanced readers benefit from example sentences.",
         ["advantage", "gain"], "/ˈbɛnɪfɪt/", "/ˈbɛnɪfɪt/", None, None,
         ["benefits", "benefited", "benefiting"]),
        ("challenge", "B1", "noun", "A task or situation that tests someone's abilities and determination.",
         [("verb", ["To dispute the truth or validity of something, or invite to a contest."])],
         "Mastering subtle idioms remains an exciting challenge for learners.",
         "Engineers solved the latency challenge with indexed queries.",
         ["obstacle", "test"], "/ˈtʃælɪndʒ/", "/ˈtʃælɪndʒ/", None, None,
         ["challenges", "challenged", "challenging"]),
        ("evidence", "B1", "noun", "The available body of facts or information indicating whether a belief is true.",
         [],
         "Longitudinal studies offer strong evidence for spaced repetition.",
         "Archaeologists uncovered fresh evidence of ancient trade routes.",
         ["proof", "data"], "/ˈɛvɪdəns/", "/ˈɛvɪdəns/", None, None,
         []),
        ("habit", "B1", "noun", "A settled or regular tendency or practice, especially one hard to give up.",
         [],
         "Reading for fifteen minutes before bed is a rewarding habit.",
         "Breaking a careless habit requires awareness and patience.",
         ["routine", "custom"], "/ˈhæbɪt/", "/ˈhæbɪt/", None, None,
         ["habits"]),
        ("method", "B1", "noun", "A particular form of procedure for accomplishing or approaching something.",
         [],
         "Active recall is a proven method for strengthening memory.",
         "The laboratory adopted a faster method for testing samples.",
         ["technique", "approach"], "/ˈmɛθəd/", "/ˈmɛθəd/", None, None,
         ["methods"]),
        ("accurate", "B1", "adjective", "Correct in all details; exact and free from error.",
         [],
         "An accurate transcription captures every subtle vowel shift.",
         "Please verify that the invoice totals are completely accurate.",
         ["precise", "exact"], "/ˈækjərət/", "/ˈækjʊrət/", None, None,
         []),
        ("reliable", "B1", "adjective", "Consistently good in quality or performance; able to be trusted.",
         [],
         "Travelers depend on reliable maps when cell reception fades.",
         "The backup generator proved reliable throughout the storm.",
         ["dependable", "trustworthy"], "/rɪˈlaɪəbəl/", "/rɪˈlaɪəbəl/", None, None,
         []),
        ("curious", "B1", "adjective", "Eager to know or learn something; inquisitive.",
         [],
         "Staying curious turns everyday reading into effortless study.",
         "The students were curious about how the clockwork functioned.",
         ["inquisitive", "interested"], "/ˈkjʊriəs/", "/ˈkjʊəriəs/", None, None,
         []),
        ("flexible", "B1", "adjective", "Capable of bending easily without breaking; able to adapt to change.",
         [],
         "A flexible study schedule fits comfortably around busy workdays.",
         "The bridge uses flexible joints to absorb thermal expansion.",
         ["adaptable", "versatile"], "/ˈflɛksəbəl/", "/ˈflɛksɪbəl/", None, None,
         []),
        ("practical", "B1", "adjective", "Concerned with the actual doing or use of something rather than theory.",
         [],
         "Writing your own example sentence is a practical way to retain vocabulary.",
         "She offered several practical tips for organizing notes.",
         ["useful", "sensible"], "/ˈpræktɪkəl/", "/ˈpræktɪkəl/", None, None,
         []),
        ("eventually", "B1", "adverb", "In the end, especially after a long delay, dispute, or series of problems.",
         [],
         "With steady review, unfamiliar expressions eventually feel natural.",
         "The mist cleared and the mountain summit eventually appeared.",
         ["ultimately", "finally"], "/ɪˈvɛntʃuəli/", "/ɪˈvɛntʃuəli/", None, None,
         []),
        ("gradually", "B1", "adverb", "In a slow, steady way over a period of time; by degrees.",
         [],
         "Your active vocabulary grows gradually through daily exposure.",
         "The sky gradually brightened as dawn approached.",
         ["steadily", "progressively"], "/ˈɡrædʒuəli/", "/ˈɡrædʒuəli/", None, None,
         []),
        ("frequently", "B1", "adverb", "Regularly or habitually; on many occasions.",
         [],
         "High-frequency connectors appear frequently in academic essays.",
         "She frequently switches between US and UK audio tracks.",
         ["often", "regularly"], "/ˈfriːkwəntli/", "/ˈfriːkwəntli/", None, None,
         []),

        # ==================== B2 (25) ====================
        ("naïve", "B2", "adjective", "Showing a lack of experience, wisdom, or worldly judgment.",
         [],
         "It would be naïve to assume that network access is always guaranteed.",
         "Her early optimism seemed naïve once negotiations stalled.",
         ["innocent", "unsuspecting"], "/naɪˈiːv/", "/naɪˈiːv/", None, None,
         ["naive", "naïver", "naïvest"]),
        ("résumé", "B2", "noun", "A concise written summary of a person's education, qualifications, and work history.",
         [],
         "Update your résumé with measurable outcomes before applying.",
         "The recruiter reviewed each résumé carefully before shortlisting.",
         ["curriculum vitae", "profile"], "/ˈrɛzəmeɪ/", "/ˈrɛzjʊmeɪ/", None, None,
         ["resume", "résumés", "resumes"]),
        ("allocate", "B2", "verb", "To distribute resources, time, or duties for a particular purpose.",
         [],
         "We should allocate ten minutes each evening for cloze practice.",
         "The council voted to allocate funds to public libraries.",
         ["assign", "allot"], "/ˈæləkeɪt/", "/ˈæləkeɪt/", None, None,
         ["allocates", "allocated", "allocating"]),
        ("comprehend", "B2", "verb", "To grasp mentally; to understand the full nature or meaning of something.",
         [],
         "Context clues help readers comprehend unfamiliar idioms swiftly.",
         "It takes reflection to comprehend the scale of geological time.",
         ["understand", "grasp"], "/ˌkɑːmprɪˈhɛnd/", "/ˌkɒmprɪˈhɛnd/", None, None,
         ["comprehends", "comprehended", "comprehending"]),
        ("emphasize", "B2", "verb", "To give special importance, value, or prominence to something in speaking or writing.",
         [],
         "Linguists emphasize the link between active recall and retention.",
         "The report emphasized clarity over unnecessary jargon.",
         ["highlight", "stress"], "/ˈɛmfəsaɪz/", "/ˈɛmfəsaɪz/", None, None,
         ["emphasizes", "emphasized", "emphasizing", "emphasise"]),
        ("fluctuate", "B2", "verb", "To rise and fall irregularly in number, level, or amount.",
         [],
         "Coastal temperatures fluctuate less dramatically than desert climates.",
         "Electricity demand tends to fluctuate across the seasons.",
         ["vary", "oscillate"], "/ˈflʌktʃueɪt/", "/ˈflʌktʃueɪt/", None, None,
         ["fluctuates", "fluctuated", "fluctuating"]),
        ("implement", "B2", "verb", "To put a decision, plan, or agreement into effect.",
         [("noun", ["A tool, utensil, or other piece of equipment used for a particular purpose."])],
         "The studio decided to implement a strict offline-first storage layer.",
         "Teachers implemented weekly review sessions across all grades.",
         ["execute", "enact"], "/ˈɪmplɪmɛnt/", "/ˈɪmplɪmɛnt/", None, None,
         ["implements", "implemented", "implementing"]),
        ("interpret", "B2", "verb", "To explain or understand the meaning of information, words, or actions.",
         [],
         "Two readers may interpret the same metaphor in subtly different ways.",
         "Sensors gather raw signals that software must interpret accurately.",
         ["construe", "decode"], "/ɪnˈtɜːrprɪt/", "/ɪnˈtɜːprɪt/", None, None,
         ["interprets", "interpreted", "interpreting"]),
        ("sustain", "B2", "verb", "To strengthen, support, or keep an effort or state going over time.",
         [],
         "Small achievable milestones help learners sustain motivation for months.",
         "Rich soil is required to sustain diverse alpine meadows.",
         ["maintain", "uphold"], "/səˈsteɪn/", "/səˈsteɪn/", None, None,
         ["sustains", "sustained", "sustaining"]),
        ("verify", "B2", "verb", "To make sure or demonstrate that something is true, accurate, or justified.",
         [],
         "Always verify the cryptographic checksum before opening an extracted archive.",
         "Editors verify every historical quotation prior to publication.",
         ["confirm", "validate"], "/ˈvɛrɪfaɪ/", "/ˈvɛrɪfaɪ/", None, None,
         ["verifies", "verified", "verifying"]),
        ("capacity", "B2", "noun", "The maximum amount that something can contain, produce, or absorb.",
         [],
         "The auditorium reached full capacity twenty minutes before the lecture.",
         "Working memory has a limited capacity for unrelated facts.",
         ["volume", "capability"], "/kəˈpæsəti/", "/kəˈpæsəti/", None, None,
         ["capacities"]),
        ("consensus", "B2", "noun", "General agreement among a group of people.",
         [],
         "After careful debate, the committee reached a clear consensus.",
         "There is broad scientific consensus on the benefits of sleep.",
         ["agreement", "accord"], "/kənˈsɛnsəs/", "/kənˈsɛnsəs/", None, None,
         ["consensuses"]),
        ("criterion", "B2", "noun", "A principle or standard by which something may be judged or decided.",
         [],
         "Readability was the primary criterion when selecting example sentences.",
         "Every candidate met the strict eligibility criterion.",
         ["standard", "benchmark"], "/kraɪˈtɪriən/", "/kraɪˈtɪəriən/", None, None,
         ["criteria"]),
        ("hypothesis", "B2", "noun", "A proposed explanation made on the basis of limited evidence as a starting point for investigation.",
         [],
         "The experiment was carefully designed to test a single hypothesis.",
         "Fresh telescope observations supported the astronomer's hypothesis.",
         ["theory", "proposition"], "/haɪˈpɑːθəsɪs/", "/haɪˈpɒθəsɪs/", None, None,
         ["hypotheses"]),
        ("incentive", "B2", "noun", "A thing that motivates or encourages someone to take a particular action.",
         [],
         "A visible streak counter provides a gentle incentive to review daily.",
         "Tax credits created a financial incentive for solar rooftops.",
         ["motivation", "stimulus"], "/ɪnˈsɛntɪv/", "/ɪnˈsɛntɪv/", None, None,
         ["incentives"]),
        ("perspective", "B2", "noun", "A particular attitude toward or way of regarding something; a point of view.",
         [],
         "Reading monolingual definitions shifts your perspective into English.",
         "Living abroad offered a fresh perspective on urban transit.",
         ["viewpoint", "outlook"], "/pərˈspɛktɪv/", "/pəˈspɛktɪv/", None, None,
         ["perspectives"]),
        ("ambiguous", "B2", "adjective", "Open to more than one interpretation; not having one obvious meaning.",
         [],
         "Clear contracts avoid ambiguous phrasing that could spark disputes.",
         "His brief reply left the timeline somewhat ambiguous.",
         ["unclear", "vague"], "/æmˈbɪɡjuəs/", "/æmˈbɪɡjuəs/", None, None,
         []),
        ("coherent", "B2", "adjective", "Logical, consistent, and clearly structured as a unified whole.",
         [],
         "She presented a coherent argument backed by verifiable figures.",
         "Good typography binds headings and notes into a coherent layout.",
         ["logical", "consistent"], "/koʊˈhɪrənt/", "/kəʊˈhɪərənt/", None, None,
         []),
        ("concise", "B2", "adjective", "Giving a lot of information clearly and in a few words; brief yet comprehensive.",
         [],
         "Dictionary definitions work best when they remain concise and exact.",
         "Please draft a concise summary for the morning briefing.",
         ["succinct", "brief"], "/kənˈsaɪs/", "/kənˈsaɪs/", None, None,
         ["conciser", "concisest"]),
        ("feasible", "B2", "adjective", "Possible and practical to do easily or conveniently.",
         [],
         "Indexing a million entries on mobile is feasible with compact SQLite tables.",
         "The engineers confirmed that the bridge repair was economically feasible.",
         ["viable", "workable"], "/ˈfiːzəbəl/", "/ˈfiːzɪbəl/", None, None,
         []),
        ("inevitable", "B2", "adjective", "Certain to happen; unavoidable.",
         [],
         "Occasional lapses are inevitable when acquiring advanced vocabulary.",
         "With rapid population growth, transit upgrades became inevitable.",
         ["unavoidable", "certain"], "/ɪnˈɛvɪtəbəl/", "/ɪnˈɛvɪtəbəl/", None, None,
         []),
        ("resilient", "B2", "adjective", "Able to withstand or recover quickly from difficult conditions.",
         [],
         "Offline-first architectures stay resilient even when connections drop.",
         "Native wildflowers are remarkably resilient during dry summers.",
         ["tough", "adaptable"], "/rɪˈzɪljənt/", "/rɪˈzɪljənt/", None, None,
         []),
        ("deliberately", "B2", "adverb", "Consciously and intentionally; on purpose.",
         [],
         "The interface deliberately avoids clutter so focus stays on the word.",
         "She spoke slowly and deliberately during the pronunciation drill.",
         ["intentionally", "purposely"], "/dɪˈlɪbərətli/", "/dɪˈlɪbərətli/", None, None,
         []),
        ("presumably", "B2", "adverb", "Used to convey that what is asserted is very likely though not known for certain.",
         [],
         "The library lights are still on, so the archivist is presumably inside.",
         "They cancelled the ferry, presumably because of gale warnings.",
         ["probably", "likely"], "/prɪˈzuːməbli/", "/prɪˈzjuːməbli/", None, None,
         []),
        ("substantially", "B2", "adverb", "To a great or significant extent.",
         [],
         "Pre-computed B-tree indexes substantially accelerate prefix search.",
         "Battery consumption dropped substantially after optimizing background tasks.",
         ["significantly", "considerably"], "/səbˈstænʃəli/", "/səbˈstænʃəli/", None, None,
         []),

        # ==================== C1 (25) ====================
        ("alleviate", "C1", "verb", "To make suffering, deficiency, or a problem less severe.",
         [],
         "Capping daily overdue reviews helps alleviate learner fatigue.",
         "Shaded walkways help alleviate summer heat across the plaza.",
         ["ease", "mitigate"], "/əˈliːvieɪt/", "/əˈliːvieɪt/", None, None,
         ["alleviates", "alleviated", "alleviating"]),
        ("corroborate", "C1", "verb", "To confirm or give support to a statement, theory, or finding.",
         [],
         "Independent phonetic recordings corroborate the regional vowel shift.",
         "Ice-core samples corroborate historical accounts of the volcanic winter.",
         ["confirm", "substantiate"], "/kəˈrɑːbəreɪt/", "/kəˈrɒbəreɪt/", None, None,
         ["corroborates", "corroborated", "corroborating"]),
        ("disseminate", "C1", "verb", "To spread or disperse information, ideas, or knowledge widely.",
         [],
         "Open lexicons disseminate linguistic knowledge to learners worldwide.",
         "Public journals disseminate peer-reviewed discoveries rapidly.",
         ["circulate", "distribute"], "/dɪˈsɛmɪneɪt/", "/dɪˈsɛmɪneɪt/", None, None,
         ["disseminates", "disseminated", "disseminating"]),
        ("elucidate", "C1", "verb", "To make something clear; to explain or throw light upon a complex topic.",
         [],
         "Well-chosen context sentences elucidate nuances that brief glosses miss.",
         "The diagram helped elucidate how spaced intervals expand over time.",
         ["clarify", "illuminate"], "/ɪˈluːsɪdeɪt/", "/ɪˈluːsɪdeɪt/", None, None,
         ["elucidates", "elucidated", "elucidating"]),
        ("mitigate", "C1", "verb", "To make something bad less severe, serious, or painful.",
         [],
         "Atomic file renames mitigate the risk of database corruption during crashes.",
         "Coastal wetlands help mitigate storm surges.",
         ["reduce", "lessen"], "/ˈmɪtɪɡeɪt/", "/ˈmɪtɪɡeɪt/", None, None,
         ["mitigates", "mitigated", "mitigating"]),
        ("perpetuate", "C1", "verb", "To make a situation, belief, or system continue indefinitely.",
         [],
         "Rote copying without recall can perpetuate the illusion of mastery.",
         "Outdated maps tend to perpetuate old spelling errors.",
         ["prolong", "sustain"], "/pərˈpɛtʃueɪt/", "/pəˈpɛtʃueɪt/", None, None,
         ["perpetuates", "perpetuated", "perpetuating"]),
        ("scrutinize", "C1", "verb", "To examine or inspect closely and thoroughly.",
         [],
         "Security auditors scrutinize every external input before parsing JSON.",
         "Botanists scrutinized the leaf veins under magnification.",
         ["examine", "inspect"], "/ˈskruːtənaɪz/", "/ˈskruːtɪnaɪz/", None, None,
         ["scrutinizes", "scrutinized", "scrutinizing", "scrutinise"]),
        ("undermine", "C1", "verb", "To erode the base, foundation, or effectiveness of something gradually.",
         [],
         "Distracting banners undermine deep concentration during study sessions.",
         "Unverified claims quickly undermine reader trust.",
         ["weaken", "erode"], "/ˌʌndərˈmaɪn/", "/ˌʌndəˈmaɪn/", None, None,
         ["undermines", "undermined", "undermining"]),
        ("catalyst", "C1", "noun", "A person or thing that precipitates an event or accelerates change.",
         [],
         "Hearing native audio often acts as a catalyst for confident speaking.",
         "The new rail link became a catalyst for regional commerce.",
         ["spark", "impetus"], "/ˈkætəlɪst/", "/ˈkætəlɪst/", None, None,
         ["catalysts"]),
        ("dichotomy", "C1", "noun", "A division or contrast between two things represented as opposed or entirely different.",
         [],
         "There is a false dichotomy between offline privacy and rich media features.",
         "The essay explores the dichotomy between formal and colloquial registers.",
         ["contrast", "division"], "/daɪˈkɑːtəmi/", "/daɪˈkɒtəmi/", None, None,
         ["dichotomies"]),
        ("nuance", "C1", "noun", "A subtle difference in or shade of meaning, expression, or sound.",
         [],
         "Monolingual study trains your ear for every semantic nuance.",
         "The actor delivered the monologue with remarkable emotional nuance.",
         ["subtlety", "shade"], "/ˈnuːɑːns/", "/ˈnjuːɑːns/", None, None,
         ["nuances"]),
        ("paradigm", "C1", "noun", "A typical example, pattern, or conceptual framework of something.",
         [],
         "Local-first software represents a resilient paradigm for personal knowledge tools.",
         "Quantum mechanics overturned the classical paradigm of physics.",
         ["model", "framework"], "/ˈpærədaɪm/", "/ˈpærədaɪm/", None, None,
         ["paradigms"]),
        ("precedent", "C1", "noun", "An earlier event or action regarded as an example or guide for subsequent situations.",
         [],
         "The court's ruling set an important precedent for digital privacy.",
         "There was no historical precedent for such a mild arctic winter.",
         ["example", "benchmark"], "/ˈprɛsɪdənt/", "/ˈprɛsɪdənt/", None, None,
         ["precedents"]),
        ("trajectory", "C1", "noun", "The path followed by a projectile or the progression of a development over time.",
         [],
         "Tracking mastery buckets reveals the upward trajectory of your vocabulary.",
         "Telemetry confirmed the spacecraft stayed on its planned trajectory.",
         ["course", "path"], "/trəˈdʒɛktəri/", "/trəˈdʒɛktəri/", None, None,
         ["trajectories"]),
        ("ambivalent", "C1", "adjective", "Having mixed feelings or contradictory ideas about someone or something.",
         [],
         "Many readers remain ambivalent about automated summaries.",
         "He felt ambivalent about leaving his quiet coastal studio.",
         ["uncertain", "conflicted"], "/æmˈbɪvələnt/", "/æmˈbɪvələnt/", None, None,
         []),
        ("candid", "C1", "adjective", "Truthful and straightforward; frank and open.",
         [],
         "Her candid feedback helped streamline the onboarding flow.",
         "The memoir offers a candid portrait of nineteenth-century printing.",
         ["frank", "forthright"], "/ˈkændɪd/", "/ˈkændɪd/", None, None,
         []),
        ("eloquent", "C1", "adjective", "Fluent, persuasive, and clearly expressive in speaking or writing.",
         [],
         "An eloquent speaker selects precise verbs instead of vague modifiers.",
         "The museum curator gave an eloquent tribute to the restorer.",
         ["articulate", "expressive"], "/ˈɛləkwənt/", "/ˈɛləkwənt/", None, None,
         []),
        ("ephemeral", "C1", "adjective", "Lasting for a very short time; transitory.",
         [],
         "Without review, newly encountered terms remain ephemeral in short-term memory.",
         "Desert wildflowers bloom in an ephemeral burst after spring rain.",
         ["fleeting", "transient"], "/ɪˈfɛmərəl/", "/ɪˈfɛmərəl/", None, None,
         []),
        ("meticulous", "C1", "adjective", "Showing great attention to detail; very careful and precise.",
         [],
         "Meticulous indexing ensures lookups stay below ten milliseconds.",
         "The watchmaker performed a meticulous calibration of every gear.",
         ["thorough", "scrupulous"], "/məˈtɪkjələs/", "/məˈtɪkjʊləs/", None, None,
         []),
        ("pragmatic", "C1", "adjective", "Dealing with things sensibly and realistically based on practical considerations.",
         [],
         "Taking a pragmatic approach kept the application lean and fast.",
         "The committee adopted a pragmatic compromise to meet the deadline.",
         ["practical", "realistic"], "/præɡˈmætɪk/", "/præɡˈmætɪk/", None, None,
         []),
        ("ubiquitous", "C1", "adjective", "Present, appearing, or found everywhere.",
         [],
         "Dark mode interfaces have become ubiquitous on modern OLED phones.",
         "Espresso stands are ubiquitous along the narrow avenues of Rome.",
         ["omnipresent", "pervasive"], "/juːˈbɪkwɪtəs/", "/juːˈbɪkwɪtəs/", None, None,
         []),
        ("stringent", "C1", "adjective", "Strict, precise, and exacting in rules or standards.",
         [],
         "The importer enforces stringent depth and type checks on every backup.",
         "Cleanrooms operate under stringent air-filtration regulations.",
         ["strict", "rigorous"], "/ˈstrɪndʒənt/", "/ˈstrɪndʒənt/", None, None,
         []),
        ("inadvertently", "C1", "adverb", "Without intention; accidentally.",
         [],
         "An unescaped wildcard can inadvertently disable a B-tree index.",
         "She inadvertently left her notebook on the morning commuter train.",
         ["accidentally", "unintentionally"], "/ˌɪnədˈvɜːrtəntli/", "/ˌɪnədˈvɜːtəntli/", None, None,
         []),
        ("ostensibly", "C1", "adverb", "Apparently or purportedly, but perhaps not actually.",
         [],
         "The policy was ostensibly designed to simplify registration.",
         "He traveled north ostensibly for business, though he loved the fjords.",
         ["seemingly", "apparently"], "/ɑːˈstɛnsəbli/", "/ɒˈstɛnsɪbli/", None, None,
         []),
        ("unequivocally", "C1", "adverb", "In a way that leaves no doubt; clearly and unambiguously.",
         [],
         "The benchmark results unequivocally favored indexed range scans.",
         "The panel unequivocally endorsed the open archival standard.",
         ["clearly", "decisively"], "/ˌʌnɪˈkwɪvəkəli/", "/ˌʌnɪˈkwɪvəkəli/", None, None,
         []),

        # ==================== C2 (25) ====================
        ("ameliorate", "C2", "verb", "To make something bad, unsatisfactory, or painful better.",
         [],
         "Adaptive spacing intervals help ameliorate the forgetting curve.",
         "Targeted tree planting can ameliorate urban heat islands.",
         ["improve", "alleviate"], "/əˈmiːliəreɪt/", "/əˈmiːliəreɪt/", None, None,
         ["ameliorates", "ameliorated", "ameliorating"]),
        ("equivocate", "C2", "verb", "To use ambiguous language so as to conceal the truth or avoid commitment.",
         [],
         "Good technical specifications never equivocate about edge cases.",
         "The spokesperson refused to equivocate when questioned on safety.",
         ["hedge", "prevaricate"], "/ɪˈkwɪvəkeɪt/", "/ɪˈkwɪvəkeɪt/", None, None,
         ["equivocates", "equivocated", "equivocating"]),
        ("exacerbate", "C2", "verb", "To make a problem, bad situation, or negative feeling worse.",
         [],
         "Skipping reviews for weeks can exacerbate overdue backlogs.",
         "Prolonged drought will exacerbate pressure on regional reservoirs.",
         ["worsen", "aggravate"], "/ɪɡˈzæsərbeɪt/", "/ɪɡˈzæsəbeɪt/", None, None,
         ["exacerbates", "exacerbated", "exacerbating"]),
        ("obfuscate", "C2", "verb", "To render obscure, unclear, or unintelligible.",
         [],
         "Overly ornate jargon tends to obfuscate straightforward concepts.",
         "Dense footnotes should illuminate rather than obfuscate the text.",
         ["obscure", "muddy"], "/ˈɑːbfʌskeɪt/", "/ˈɒbfʌskeɪt/", None, None,
         ["obfuscates", "obfuscated", "obfuscating"]),
        ("precipitate", "C2", "verb", "To cause an event or situation, typically an undesirable one, to happen suddenly.",
         [("adjective", ["Done, made, or acting suddenly or without careful consideration."])],
         "A single unvalidated redirect could precipitate a security flaw.",
         "Sudden barometric drops often precipitate fierce alpine squalls.",
         ["trigger", "provoke"], "/prɪˈsɪpɪteɪt/", "/prɪˈsɪpɪteɪt/", None, None,
         ["precipitates", "precipitated", "precipitating"]),
        ("repudiate", "C2", "verb", "To refuse to accept, associate with, or acknowledge the validity of something.",
         [],
         "Modern linguists repudiate the myth that accents indicate intelligence.",
         "The board voted to repudiate the unauthorized agreement.",
         ["reject", "renounce"], "/rɪˈpjuːdieɪt/", "/rɪˈpjuːdieɪt/", None, None,
         ["repudiates", "repudiated", "repudiating"]),
        ("vindicate", "C2", "verb", "To clear someone or something of blame, suspicion, or doubt; to justify.",
         [],
         "Smooth performance on low-end handsets vindicated our lightweight architecture.",
         "Newly uncovered letters vindicated the cartographer's original map.",
         ["justify", "exonerate"], "/ˈvɪndɪkeɪt/", "/ˈvɪndɪkeɪt/", None, None,
         ["vindicates", "vindicated", "vindicating"]),
        ("conflate", "C2", "verb", "To combine two or more texts, ideas, or sets of information into one, often erroneously.",
         [],
         "Careful translators never conflate literal glosses with idiomatic meaning.",
         "Do not conflate temporary familiarity with long-term mastery.",
         ["merge", "confuse"], "/kənˈfleɪt/", "/kənˈfleɪt/", None, None,
         ["conflates", "conflated", "conflating"]),
        ("anachronism", "C2", "noun", "A thing belonging or appropriate to a period other than that in which it exists.",
         [],
         "A wristwatch in a medieval drama is a classic anachronism.",
         "Requiring paper forms for digital lookups feels like an anachronism.",
         ["relic", "incongruity"], "/əˈnækrənɪzəm/", "/əˈnækrənɪzəm/", None, None,
         ["anachronisms"]),
        ("conundrum", "C2", "noun", "A confusing and difficult problem or question.",
         [],
         "Balancing rich audio with zero offline stalls posed an intriguing conundrum.",
         "The archivists solved the dating conundrum using watermark analysis.",
         ["puzzle", "dilemma"], "/kəˈnʌndrəm/", "/kəˈnʌndrəm/", None, None,
         ["conundrums"]),
        ("panacea", "C2", "noun", "A solution or remedy for all difficulties or diseases.",
         [],
         "No single algorithm is a panacea, yet spaced recall remains unmatched.",
         "Analysts warned that automation alone is not a panacea for weak design.",
         ["cure-all", "elixir"], "/ˌpænəˈsiːə/", "/ˌpænəˈsiːə/", None, None,
         ["panaceas"]),
        ("perspicacity", "C2", "noun", "The quality of having a ready insight into things; shrewdness of understanding.",
         [],
         "Her editorial perspicacity turned a dense draft into luminous prose.",
         "The detective's perspicacity uncovered the overlooked ledger entry.",
         ["acumen", "insight"], "/ˌpɜːrspɪˈkæsəti/", "/ˌpɜːspɪˈkæsəti/", None, None,
         []),
        ("zeitgeist", "C2", "noun", "The defining spirit or mood of a particular period of history.",
         [],
         "Calm, distraction-free utilities capture the contemporary digital zeitgeist.",
         "The novel mirrored the architectural zeitgeist of postwar Europe.",
         ["ethos", "spirit"], "/ˈzaɪtɡaɪst/", "/ˈzaɪtɡaɪst/", None, None,
         ["zeitgeists"]),
        ("verisimilitude", "C2", "noun", "The appearance of being true or real.",
         [],
         "Authentic corpus sentences lend unmistakable verisimilitude to cloze tests.",
         "Period costumes gave the historical film striking verisimilitude.",
         ["realism", "authenticity"], "/ˌvɛrɪsɪˈmɪlɪtuːd/", "/ˌvɛrɪsɪˈmɪlɪtjuːd/", None, None,
         []),
        ("abstruse", "C2", "adjective", "Difficult to understand; obscure and overly complex.",
         [],
         "Clear examples demystify even the most abstruse philosophical terms.",
         "The treatise was packed with abstruse notation intelligible to few.",
         ["obscure", "arcane"], "/æbˈstruːs/", "/əbˈstruːs/", None, None,
         []),
        ("assiduous", "C2", "adjective", "Showing great care, perseverance, and diligent attention.",
         [],
         "Assiduous daily practice steadily lifts words into permanent mastery.",
         "An assiduous researcher cross-checks every citation against primary sources.",
         ["diligent", "industrious"], "/əˈsɪdʒuəs/", "/əˈsɪdjʊəs/", None, None,
         []),
        ("fastidious", "C2", "adjective", "Very attentive to and concerned about accuracy and detail.",
         [],
         "A fastidious typographer checks every IPA glyph for clean fallback rendering.",
         "She kept fastidious logs of every acoustic test.",
         ["meticulous", "particular"], "/fæˈstɪdiəs/", "/fæˈstɪdiəs/", None, None,
         []),
        ("iconoclastic", "C2", "adjective", "Criticizing or attacking cherished beliefs or traditional institutions.",
         [],
         "His iconoclastic essay questioned decades of passive rote memorization.",
         "The studio earned praise for its iconoclastic approach to exhibition space.",
         ["unconventional", "rebellious"], "/aɪˌkɑːnəˈklæstɪk/", "/aɪˌkɒnəˈklæstɪk/", None, None,
         []),
        ("intransigent", "C2", "adjective", "Unwilling or refusing to change one's views or agree about something.",
         [],
         "An intransigent stance stalled the standards committee for months.",
         "Despite fresh evidence, the critic remained wholly intransigent.",
         ["uncompromising", "inflexible"], "/ɪnˈtrænsɪdʒənt/", "/ɪnˈtrænsɪdʒənt/", None, None,
         []),
        ("laconic", "C2", "adjective", "Using very few words; concisely expressive to the point of seeming terse.",
         [],
         "His laconic reply conveyed complete confidence in just three words.",
         "A laconic gloss on the home widget fits cleanly inside two compact lines.",
         ["terse", "succinct"], "/ləˈkɑːnɪk/", "/ləˈkɒnɪk/", None, None,
         []),
        ("pellucid", "C2", "adjective", "Translucently clear; easily understood in style or meaning.",
         [],
         "The essay won acclaim for its pellucid exposition of complex law.",
         "Sunlight shimmered across the pellucid waters of the glacier lake.",
         ["limpid", "lucid"], "/pəˈluːsɪd/", "/pəˈluːsɪd/", None, None,
         []),
        ("recalcitrant", "C2", "adjective", "Having an obstinately uncooperative attitude toward authority or discipline.",
         [],
         "Even recalcitrant words stick once anchored to a personal sentence.",
         "The technician finally tamed the recalcitrant legacy printer.",
         ["defiant", "unruly"], "/rɪˈkælsɪtrənt/", "/rɪˈkælsɪtrənt/", None, None,
         []),
        ("inexorably", "C2", "adverb", "In a way that is impossible to stop or prevent.",
         [],
         "Daily compounding habits inexorably transform reading fluency.",
         "The tide crept inexorably across the limestone causeway.",
         ["relentlessly", "unstoppably"], "/ɪnˈɛksərəbli/", "/ɪnˈɛksərəbli/", None, None,
         []),
        ("perfunctorily", "C2", "adverb", "With a minimum of effort, care, or genuine reflection.",
         [],
         "Glancing perfunctorily at flashcards builds far weaker recall than cloze drills.",
         "He nodded perfunctorily without looking up from the ledger.",
         ["mechanically", "casually"], "/pərˈfʌŋktərəli/", "/pəˈfʌŋktərəli/", None, None,
         []),
        ("serendipitously", "C2", "adverb", "In a fortunate way by chance or happy accident.",
         [],
         "Clicking an unfamiliar word inside a definition often teaches serendipitously.",
         "The rare manuscript was serendipitously uncovered in an attic trunk.",
         ["fortuitously", "luckily"], "/ˌsɛrənˈdɪpɪtəsli/", "/ˌsɛrənˈdɪpɪtəsli/", None, None,
         []),
    ]

    entries: list[dict[str, Any]] = []
    for row in raw_rows:
        (
            word_display, level, pos, meaning, extra_senses,
            ex1, ex2, syns, ipa_us, ipa_uk, audio_us, audio_uk, forms
        ) = row
        wk = normalize_query(word_display)
        senses_list = [{"p": pos, "d": [meaning]}]
        for ep, edefs in extra_senses:
            senses_list.append({"p": ep, "d": edefs})
        examples_list = [ex for ex in (ex1, ex2) if ex]
        cloze_ex = ex1 if level in STUDY_LEVELS else None

        val_us = validate_wikimedia_relative_path(audio_us)
        val_uk = validate_wikimedia_relative_path(audio_uk)

        all_forms: set[str] = set()
        for f in forms:
            nf = normalize_query(f)
            if nf and nf != wk:
                all_forms.add(nf)
        ascii_alias = strip_diacritics_ascii(word_display)
        if ascii_alias and ascii_alias != wk:
            all_forms.add(ascii_alias)

        entries.append({
            "word_key": wk,
            "word_display": word_display,
            "level": level,
            "primary_pos": pos,
            "meaning_en": meaning,
            "senses": json.dumps(senses_list, ensure_ascii=False, separators=(",", ":")),
            "examples": json.dumps(examples_list, ensure_ascii=False, separators=(",", ":")),
            "cloze_example": cloze_ex,
            "synonyms": json.dumps(syns, ensure_ascii=False, separators=(",", ":")),
            "ipa_us": ipa_us,
            "ipa_uk": ipa_uk,
            "audio_us": val_us,
            "audio_uk": val_uk,
            "forms": sorted(all_forms),
        })
    return entries


def build_sample(repo_root: Path, output_dir: Path) -> None:
    cache_dir = repo_root / "tools" / ".cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    db_path = cache_dir / "vocab_dict_sample.db"
    if db_path.exists():
        db_path.unlink()

    entries = _make_sample_entries()
    counts_by_level: dict[str, int] = {}
    for e in entries:
        lvl = e["level"] or "NONE"
        counts_by_level[lvl] = counts_by_level.get(lvl, 0) + 1
    print(f"Sample distribution: {counts_by_level} (total={len(entries)})")

    conn = sqlite3.connect(str(db_path))
    try:
        create_output_schema(conn)
        word_rows = [
            (
                e["word_key"], e["word_display"], e["level"], e["primary_pos"],
                e["meaning_en"], e["senses"], e["examples"], e["cloze_example"],
                e["synonyms"], e["ipa_us"], e["ipa_uk"], e["audio_us"], e["audio_uk"],
            )
            for e in entries
        ]
        conn.executemany(
            """
            INSERT OR REPLACE INTO words (
                word_key, word_display, level, primary_pos, meaning_en,
                senses, examples, cloze_example, synonyms,
                ipa_us, ipa_uk, audio_us, audio_uk
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            word_rows,
        )
        form_rows = [
            (form, e["word_key"])
            for e in entries
            for form in e["forms"]
        ]
        conn.executemany(
            "INSERT OR IGNORE INTO word_forms (form, word_key) VALUES (?, ?);",
            form_rows,
        )
        word_count = create_output_indexes_and_finalize(conn)
    finally:
        conn.close()

    export_compressed_assets(db_path, output_dir, word_count=word_count, is_sample=True)


# ---------------------------------------------------------------------------
# FULL KAIKKI ETL PIPELINE (<150 MB RAM via staging.db)
# ---------------------------------------------------------------------------

def load_cefr_csv(csv_path: Path | None) -> dict[str, str]:
    mapping: dict[str, str] = {}
    if not csv_path or not csv_path.exists():
        return mapping
    level_rank = {lvl: idx for idx, lvl in enumerate(CEFR_LEVELS)}
    with open(csv_path, "r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            raw_word = (
                row.get("word")
                or row.get("headword")
                or row.get("Word")
                or row.get("Headword")
                or ""
            )
            raw_level = (
                row.get("level")
                or row.get("cefr")
                or row.get("CEFR")
                or row.get("Level")
                or ""
            ).strip().upper()
            if raw_level not in level_rank:
                continue
            wk = normalize_query(raw_word)
            if not wk:
                continue
            prev = mapping.get(wk)
            if prev is None or level_rank[raw_level] < level_rank[prev]:
                mapping[wk] = raw_level
    print(f"Loaded {len(mapping)} CEFR entries from {csv_path}")
    return mapping


def _score_accent_tags(tags: list[str]) -> tuple[int, int]:
    """Return (us_priority, uk_priority); higher is better, 0 means no match."""
    lower = {t.lower() for t in tags if isinstance(t, str)}
    us_score = 0
    uk_score = 0
    if "general-american" in lower or "ga" in lower:
        us_score = 100
    elif "us" in lower or "american" in lower:
        us_score = 80
    elif "north-america" in lower:
        us_score = 50

    if "received-pronunciation" in lower or "rp" in lower:
        uk_score = 100
    elif "uk" in lower or "british" in lower:
        uk_score = 80
    elif "england" in lower or "southern-england" in lower:
        uk_score = 60

    return us_score, uk_score


def _extract_sounds(sounds: list[dict[str, Any]]) -> dict[str, Any]:
    best = {
        "ipa_us": (0, None),
        "ipa_uk": (0, None),
        "audio_us": (0, None),
        "audio_uk": (0, None),
    }
    fallback_ipa: str | None = None
    for s in sounds:
        if not isinstance(s, dict):
            continue
        tags = s.get("tags") or []
        us_p, uk_p = _score_accent_tags(tags)
        ipa = s.get("ipa")
        if isinstance(ipa, str) and ipa.strip():
            ipa_clean = ipa.strip()
            if fallback_ipa is None:
                fallback_ipa = ipa_clean
            if us_p > best["ipa_us"][0]:
                best["ipa_us"] = (us_p, ipa_clean)
            if uk_p > best["ipa_uk"][0]:
                best["ipa_uk"] = (uk_p, ipa_clean)

        # Prefer ogg_url over mp3_url, validate exact relative Wikimedia path
        ogg_rel = validate_wikimedia_relative_path(s.get("ogg_url"))
        mp3_rel = validate_wikimedia_relative_path(s.get("mp3_url"))
        chosen_rel = ogg_rel or mp3_rel
        fmt_bonus = 20 if ogg_rel else (10 if mp3_rel else 0)
        if chosen_rel:
            # Infer accent from filename if tags absent
            fname_low = chosen_rel.lower()
            if us_p == 0 and ("en-us-" in fname_low or "-us-" in fname_low):
                us_p = 65
            if uk_p == 0 and ("en-uk-" in fname_low or "en-gb-" in fname_low or "-uk-" in fname_low):
                uk_p = 65
            if us_p > 0 and (us_p + fmt_bonus) > best["audio_us"][0]:
                best["audio_us"] = (us_p + fmt_bonus, chosen_rel)
            if uk_p > 0 and (uk_p + fmt_bonus) > best["audio_uk"][0]:
                best["audio_uk"] = (uk_p + fmt_bonus, chosen_rel)

    return {
        "ipa_us": best["ipa_us"][1] or fallback_ipa,
        "ipa_uk": best["ipa_uk"][1] or fallback_ipa,
        "ipa_us_score": best["ipa_us"][0],
        "ipa_uk_score": best["ipa_uk"][0],
        "audio_us": best["audio_us"][1],
        "audio_uk": best["audio_uk"][1],
        "audio_us_score": best["audio_us"][0],
        "audio_uk_score": best["audio_uk"][0],
    }


def _clean_text(s: str) -> str:
    s = _BIDI_AND_CTRL_RE.sub("", s)
    return _MULTI_SPACE_RE.sub(" ", s).strip()


def _heuristic_cefr(word_key: str, pos: str, has_cloze: bool, senses_count: int) -> str | None:
    if not has_cloze or " " in word_key or pos not in ("noun", "verb", "adjective", "adverb"):
        return None
    length = len(word_key)
    if senses_count >= 5 and length <= 7:
        return "B1"
    if senses_count >= 3 and length <= 9:
        return "B2"
    if length <= 12:
        return "C1"
    return "C2"


def build_full(
    repo_root: Path,
    output_dir: Path,
    input_path: Path | None,
    cefr_csv: Path | None,
    allow_heuristic_cefr: bool,
) -> None:
    cache_dir = repo_root / "tools" / ".cache"
    cache_dir.mkdir(parents=True, exist_ok=True)

    if input_path is None:
        input_path = download_with_resume(
            DEFAULT_KAIKKI_URL,
            cache_dir / "kaikki.org-dictionary-English.jsonl",
        )
    elif not input_path.exists():
        raise FileNotFoundError(f"Input file not found: {input_path}")

    cefr_map = load_cefr_csv(cefr_csv)
    staging_path = cache_dir / "staging.db"
    if staging_path.exists():
        staging_path.unlink()

    stage = sqlite3.connect(str(staging_path))
    stage.execute("PRAGMA journal_mode = OFF;")
    stage.execute("PRAGMA synchronous = OFF;")
    stage.execute("PRAGMA cache_size = -65536;")
    stage.execute("PRAGMA temp_store = FILE;")
    stage.execute(
        """
        CREATE TABLE staged_words (
            word_key TEXT PRIMARY KEY,
            word_display TEXT NOT NULL,
            primary_pos TEXT NOT NULL,
            meaning_en TEXT NOT NULL,
            senses_json TEXT NOT NULL,
            examples_json TEXT NOT NULL,
            cloze_example TEXT,
            synonyms_json TEXT NOT NULL,
            ipa_us TEXT,
            ipa_us_score INTEGER NOT NULL DEFAULT 0,
            ipa_uk TEXT,
            ipa_uk_score INTEGER NOT NULL DEFAULT 0,
            audio_us TEXT,
            audio_us_score INTEGER NOT NULL DEFAULT 0,
            audio_uk TEXT,
            audio_uk_score INTEGER NOT NULL DEFAULT 0
        );
        """
    )
    stage.execute(
        """
        CREATE TABLE staged_forms (
            form TEXT NOT NULL,
            word_key TEXT NOT NULL,
            PRIMARY KEY (form, word_key)
        ) WITHOUT ROWID;
        """
    )

    processed = 0
    accepted = 0
    print(f"Streaming {input_path} into {staging_path}...", flush=True)

    try:
        with open_jsonl_auto(input_path) as fh:
            for line in fh:
                processed += 1
                if processed % 100000 == 0:
                    stage.commit()
                    print(f"  Processed {processed:,} lines ({accepted:,} staged)...", flush=True)
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue

                if rec.get("lang_code") != "en":
                    continue
                pos = str(rec.get("pos") or "").strip().lower()
                if not pos or pos in EXCLUDED_POS:
                    continue
                word_raw = str(rec.get("word") or "").strip()
                if not word_raw:
                    continue
                word_key = normalize_query(word_raw)
                if not (1 <= len(word_key) <= 64):
                    continue
                if not _HAS_LATIN_RE.search(word_key):
                    continue

                raw_senses = rec.get("senses") or []
                clean_defs: list[str] = []
                clean_examples: list[str] = []
                clean_syns: list[str] = []
                cloze_candidate: str | None = None

                word_re = re.compile(
                    r"(?<![A-Za-z0-9\u00C0-\u024F-])"
                    + re.escape(word_key)
                    + r"(?![A-Za-z0-9\u00C0-\u024F-])",
                    re.IGNORECASE,
                )

                for s in raw_senses:
                    if not isinstance(s, dict):
                        continue
                    tags = {str(t).lower() for t in (s.get("tags") or [])}
                    if "form-of" in tags or "alt-of" in tags:
                        continue
                    glosses = s.get("glosses") or []
                    if not glosses:
                        continue
                    gloss = _clean_text(str(glosses[0]))
                    if not gloss or len(gloss) < 4:
                        continue
                    if gloss not in clean_defs and len(clean_defs) < 4:
                        clean_defs.append(gloss)

                    for ex in (s.get("examples") or []):
                        if not isinstance(ex, dict):
                            continue
                        ex_text = _clean_text(str(ex.get("text") or ""))
                        if 15 <= len(ex_text) <= 220:
                            if ex_text not in clean_examples and len(clean_examples) < 3:
                                clean_examples.append(ex_text)
                            if cloze_candidate is None and word_re.search(ex_text):
                                cloze_candidate = ex_text

                    for syn in (s.get("synonyms") or []):
                        if isinstance(syn, dict):
                            sw = _clean_text(str(syn.get("word") or ""))
                            if sw and normalize_query(sw) != word_key and sw not in clean_syns and len(clean_syns) < 6:
                                clean_syns.append(sw)

                if not clean_defs:
                    continue

                sound_info = _extract_sounds(rec.get("sounds") or [])

                # Collect word_forms
                forms_to_add: set[str] = set()
                for frm in (rec.get("forms") or []):
                    if not isinstance(frm, dict):
                        continue
                    fw = normalize_query(str(frm.get("form") or ""))
                    if fw and fw != word_key and 1 <= len(fw) <= 64 and _HAS_LATIN_RE.search(fw):
                        forms_to_add.add(fw)
                ascii_alias = strip_diacritics_ascii(word_raw)
                if ascii_alias and ascii_alias != word_key:
                    forms_to_add.add(ascii_alias)

                existing = stage.execute(
                    """
                    SELECT word_display, primary_pos, meaning_en, senses_json,
                           examples_json, cloze_example, synonyms_json,
                           ipa_us, ipa_us_score, ipa_uk, ipa_uk_score,
                           audio_us, audio_us_score, audio_uk, audio_uk_score
                    FROM staged_words WHERE word_key = ?;
                    """,
                    (word_key,),
                ).fetchone()

                if existing is None:
                    senses_obj = [{"p": pos, "d": clean_defs}]
                    stage.execute(
                        """
                        INSERT INTO staged_words (
                            word_key, word_display, primary_pos, meaning_en,
                            senses_json, examples_json, cloze_example, synonyms_json,
                            ipa_us, ipa_us_score, ipa_uk, ipa_uk_score,
                            audio_us, audio_us_score, audio_uk, audio_uk_score
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """,
                        (
                            word_key, word_raw, pos, clean_defs[0],
                            json.dumps(senses_obj, ensure_ascii=False, separators=(",", ":")),
                            json.dumps(clean_examples, ensure_ascii=False, separators=(",", ":")),
                            cloze_candidate,
                            json.dumps(clean_syns, ensure_ascii=False, separators=(",", ":")),
                            sound_info["ipa_us"], sound_info["ipa_us_score"],
                            sound_info["ipa_uk"], sound_info["ipa_uk_score"],
                            sound_info["audio_us"], sound_info["audio_us_score"],
                            sound_info["audio_uk"], sound_info["audio_uk_score"],
                        ),
                    )
                    accepted += 1
                else:
                    (
                        ex_disp, ex_pos, ex_meaning, ex_senses_j,
                        ex_examples_j, ex_cloze, ex_syns_j,
                        ex_ipa_us, ex_ipa_us_s, ex_ipa_uk, ex_ipa_uk_s,
                        ex_aud_us, ex_aud_us_s, ex_aud_uk, ex_aud_uk_s,
                    ) = existing
                    senses_obj = json.loads(ex_senses_j)
                    if len(senses_obj) < 6 and not any(item["p"] == pos for item in senses_obj):
                        senses_obj.append({"p": pos, "d": clean_defs})
                    examples_obj = json.loads(ex_examples_j)
                    for e_item in clean_examples:
                        if len(examples_obj) < 4 and e_item not in examples_obj:
                            examples_obj.append(e_item)
                    syns_obj = json.loads(ex_syns_j)
                    for s_item in clean_syns:
                        if len(syns_obj) < 8 and s_item not in syns_obj:
                            syns_obj.append(s_item)

                    # Keep primary_pos, meaning_en, and cloze_example aligned to same clean sense group
                    new_pos = ex_pos
                    new_meaning = ex_meaning
                    new_cloze = ex_cloze
                    if ex_cloze is None and cloze_candidate is not None:
                        new_pos = pos
                        new_meaning = clean_defs[0]
                        new_cloze = cloze_candidate

                    new_ipa_us, new_ipa_us_s = (
                        (sound_info["ipa_us"], sound_info["ipa_us_score"])
                        if sound_info["ipa_us"] and sound_info["ipa_us_score"] > ex_ipa_us_s
                        else (ex_ipa_us or sound_info["ipa_us"], ex_ipa_us_s)
                    )
                    new_ipa_uk, new_ipa_uk_s = (
                        (sound_info["ipa_uk"], sound_info["ipa_uk_score"])
                        if sound_info["ipa_uk"] and sound_info["ipa_uk_score"] > ex_ipa_uk_s
                        else (ex_ipa_uk or sound_info["ipa_uk"], ex_ipa_uk_s)
                    )
                    new_aud_us, new_aud_us_s = (
                        (sound_info["audio_us"], sound_info["audio_us_score"])
                        if sound_info["audio_us"] and sound_info["audio_us_score"] > ex_aud_us_s
                        else (ex_aud_us, ex_aud_us_s)
                    )
                    new_aud_uk, new_aud_uk_s = (
                        (sound_info["audio_uk"], sound_info["audio_uk_score"])
                        if sound_info["audio_uk"] and sound_info["audio_uk_score"] > ex_aud_uk_s
                        else (ex_aud_uk, ex_aud_uk_s)
                    )

                    stage.execute(
                        """
                        UPDATE staged_words SET
                            primary_pos = ?, meaning_en = ?, senses_json = ?,
                            examples_json = ?, cloze_example = ?, synonyms_json = ?,
                            ipa_us = ?, ipa_us_score = ?, ipa_uk = ?, ipa_uk_score = ?,
                            audio_us = ?, audio_us_score = ?, audio_uk = ?, audio_uk_score = ?
                        WHERE word_key = ?;
                        """,
                        (
                            new_pos, new_meaning,
                            json.dumps(senses_obj, ensure_ascii=False, separators=(",", ":")),
                            json.dumps(examples_obj, ensure_ascii=False, separators=(",", ":")),
                            new_cloze,
                            json.dumps(syns_obj, ensure_ascii=False, separators=(",", ":")),
                            new_ipa_us, new_ipa_us_s, new_ipa_uk, new_ipa_uk_s,
                            new_aud_us, new_aud_us_s, new_aud_uk, new_aud_uk_s,
                            word_key,
                        ),
                    )

                if forms_to_add:
                    stage.executemany(
                        "INSERT OR IGNORE INTO staged_forms (form, word_key) VALUES (?, ?);",
                        [(f, word_key) for f in forms_to_add],
                    )

        stage.commit()
        print(f"Staging finished: {processed:,} lines processed, {accepted:,} unique English words.")

        # Export staged data to final optimized read-only SQLite DB
        final_db_path = cache_dir / "vocab_dict_full.db"
        if final_db_path.exists():
            final_db_path.unlink()

        out_conn = sqlite3.connect(str(final_db_path))
        try:
            create_output_schema(out_conn)
            cur = stage.execute(
                """
                SELECT word_key, word_display, primary_pos, meaning_en,
                       senses_json, examples_json, cloze_example, synonyms_json,
                       ipa_us, ipa_uk, audio_us, audio_uk
                FROM staged_words;
                """
            )
            batch: list[tuple[Any, ...]] = []
            for row in cur:
                wk, disp, pos, meaning, senses_j, ex_j, cloze, syns_j, i_us, i_uk, a_us, a_uk = row
                lvl = cefr_map.get(wk)
                if lvl is None and allow_heuristic_cefr:
                    s_count = len(json.loads(senses_j))
                    lvl = _heuristic_cefr(wk, pos, cloze is not None, s_count)
                batch.append((wk, disp, lvl, pos, meaning, senses_j, ex_j, cloze, syns_j, i_us, i_uk, a_us, a_uk))
                if len(batch) >= 5000:
                    out_conn.executemany(
                        """
                        INSERT INTO words (
                            word_key, word_display, level, primary_pos, meaning_en,
                            senses, examples, cloze_example, synonyms,
                            ipa_us, ipa_uk, audio_us, audio_uk
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """,
                        batch,
                    )
                    batch.clear()
            if batch:
                out_conn.executemany(
                    """
                    INSERT INTO words (
                        word_key, word_display, level, primary_pos, meaning_en,
                        senses, examples, cloze_example, synonyms,
                        ipa_us, ipa_uk, audio_us, audio_uk
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    batch,
                )

            f_cur = stage.execute("SELECT form, word_key FROM staged_forms;")
            f_batch: list[tuple[str, str]] = []
            for f_row in f_cur:
                f_batch.append(f_row)
                if len(f_batch) >= 10000:
                    out_conn.executemany(
                        "INSERT OR IGNORE INTO word_forms (form, word_key) VALUES (?, ?);",
                        f_batch,
                    )
                    f_batch.clear()
            if f_batch:
                out_conn.executemany(
                    "INSERT OR IGNORE INTO word_forms (form, word_key) VALUES (?, ?);",
                    f_batch,
                )

            word_count = create_output_indexes_and_finalize(out_conn)
        finally:
            out_conn.close()

        export_compressed_assets(final_db_path, output_dir, word_count=word_count, is_sample=False)
    finally:
        stage.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Lexora v2.0.0 Dictionary ETL Pipeline")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--sample", action="store_true", help="Build 120-word balanced sample dictionary")
    mode.add_argument("--full", action="store_true", help="Build full Kaikki English Wiktionary dictionary")
    parser.add_argument("--input", type=Path, default=None, help="Local Kaikki .jsonl or .jsonl.gz file")
    parser.add_argument("--cefr-csv", type=Path, default=None, help="CSV mapping word -> CEFR level (A1..C2)")
    parser.add_argument(
        "--allow-heuristic-cefr",
        action="store_true",
        help="Allow heuristic CEFR assignment for unmapped entries in --full mode",
    )
    parser.add_argument("--output-dir", type=Path, default=None, help="Output assets directory (default: assets/)")

    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    output_dir = args.output_dir if args.output_dir else (repo_root / "assets")

    if args.sample:
        build_sample(repo_root, output_dir)
    else:
        build_full(
            repo_root=repo_root,
            output_dir=output_dir,
            input_path=args.input,
            cefr_csv=args.cefr_csv,
            allow_heuristic_cefr=args.allow_heuristic_cefr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

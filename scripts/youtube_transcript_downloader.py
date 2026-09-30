#!/usr/bin/env python3
"""
YouTube Transcript Downloader
==============================
Loops, asking you for YouTube video URLs, playlist URLs, or bare video IDs.
You can paste one, or several separated by spaces/commas in a single
prompt, and they will be fetched concurrently (multithreaded). Pasting a
playlist URL expands it to every video in the playlist. Each video's
transcript is saved to its own .txt file, named after the video's title.

Requirements:
    pip install youtube-transcript-api yt-dlp

Usage:
    python youtube_transcript_downloader.py

Then paste video/playlist URLs or IDs when prompted. Type 'q' or 'quit' to exit.
"""

import re
import os
import sys
import json
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

from youtube_transcript_api import YouTubeTranscriptApi
from youtube_transcript_api._errors import (
    TranscriptsDisabled,
    NoTranscriptFound,
    VideoUnavailable,
)

try:
    import yt_dlp
except ImportError:
    yt_dlp = None

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
OUTPUT_DIR = "transcripts"          # folder where .txt files are saved
MAX_WORKERS = 2                     # how many extractions run at once
PREFERRED_LANGUAGES = ["en", "en-US", "en-GB"]  # tried in order, then falls
                                                 # back to whatever is available

VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
PLAYLIST_ID_RE = re.compile(r"[?&]list=([A-Za-z0-9_-]+)")


def extract_playlist_id(text: str) -> str | None:
    """Pull a playlist ID out of a playlist/watch URL, if present."""
    match = PLAYLIST_ID_RE.search(text.strip())
    if match:
        return match.group(1)
    return None


def get_playlist_video_ids(playlist_id: str) -> list[str]:
    """Return the list of video IDs in a playlist, in playlist order,
    using yt-dlp in flat-extraction mode (fast - no per-video metadata
    fetch)."""
    if yt_dlp is None:
        raise RuntimeError(
            "yt-dlp is required for playlist support. Install it with: "
            "pip install yt-dlp"
        )

    url = f"https://www.youtube.com/playlist?list={playlist_id}"
    ydl_opts = {
        "extract_flat": True,
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=False)

    entries = info.get("entries") or []
    video_ids = []
    for entry in entries:
        if not entry:
            continue
        vid = entry.get("id")
        if vid and VIDEO_ID_RE.match(vid):
            video_ids.append(vid)
    return video_ids


def extract_video_id(text: str) -> str | None:
    """Pull an 11-character YouTube video ID out of a URL or return the
    text itself if it already looks like a bare video ID."""
    text = text.strip()
    if not text:
        return None

    if VIDEO_ID_RE.match(text):
        return text

    patterns = [
        r"(?:v=|/videos/|embed/|youtu\.be/|/v/|/shorts/)([A-Za-z0-9_-]{11})",
        r"^https?://(?:www\.)?youtube\.com/watch\?.*[?&]v=([A-Za-z0-9_-]{11})",
    ]
    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            return match.group(1)

    return None


def sanitize_filename(name: str, max_length: int = 150) -> str:
    """Make a string safe to use as a filename across platforms."""
    name = re.sub(r'[\\/*?:"<>|]', "", name)
    name = re.sub(r"\s+", " ", name).strip()
    if not name:
        name = "untitled"
    return name[:max_length]


def get_video_title(video_id: str) -> str:
    """Fetch the video title via YouTube's oEmbed endpoint (no API key
    needed). Falls back to the video ID if this fails for any reason."""
    url = f"https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v={video_id}&format=json"
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            data = json.loads(response.read().decode("utf-8"))
            title = data.get("title")
            if title:
                return title
    except Exception:
        pass
    return video_id


def format_timestamp(seconds: float) -> str:
    total_seconds = int(seconds)
    hrs, rem = divmod(total_seconds, 3600)
    mins, secs = divmod(rem, 60)
    if hrs:
        return f"{hrs:02d}:{mins:02d}:{secs:02d}"
    return f"{mins:02d}:{secs:02d}"


def fetch_transcript(video_id: str):
    """Return a FetchedTranscript-like list of snippets for video_id,
    trying preferred languages first, then any available transcript
    (including auto-generated / translated ones)."""
    api = YouTubeTranscriptApi()

    try:
        return api.fetch(video_id, languages=PREFERRED_LANGUAGES)
    except NoTranscriptFound:
        pass

    # Fall back: grab whatever transcript is available, translating to
    # English if a translation is offered.
    transcript_list = api.list(video_id)

    try:
        transcript = transcript_list.find_transcript(PREFERRED_LANGUAGES)
    except NoTranscriptFound:
        transcript = next(iter(transcript_list))
        if transcript.is_translatable:
            try:
                transcript = transcript.translate("en")
            except Exception:
                pass

    return transcript.fetch()


def process_video(raw_input: str, output_dir: str) -> tuple[str, bool, str]:
    """Fetch a transcript and write it to disk. Returns (label, success, message)."""
    video_id = extract_video_id(raw_input)
    if not video_id:
        return (raw_input, False, "Could not parse a video ID from this input.")

    title = get_video_title(video_id)

    try:
        fetched = fetch_transcript(video_id)
    except TranscriptsDisabled:
        return (title, False, "Transcripts are disabled for this video.")
    except VideoUnavailable:
        return (title, False, "Video is unavailable.")
    except NoTranscriptFound:
        return (title, False, "No transcript found in any language.")
    except Exception as exc:
        return (title, False, f"Error: {exc}")

    lines = []
    for snippet in fetched:
        timestamp = format_timestamp(snippet.start)
        lines.append(f"[{timestamp}] {snippet.text}")

    filename = f"{sanitize_filename(title)} [{video_id}].txt"
    filepath = os.path.join(output_dir, filename)

    try:
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(f"Title: {title}\n")
            f.write(f"Video ID: {video_id}\n")
            f.write(f"URL: https://www.youtube.com/watch?v={video_id}\n")
            f.write("-" * 60 + "\n\n")
            f.write("\n".join(lines))
    except OSError as exc:
        return (title, False, f"Could not write file: {exc}")

    return (title, True, filepath)


def split_inputs(raw: str) -> list[str]:
    """Split a line of user input into individual URLs/IDs on commas,
    semicolons or whitespace. If the whole input is a path to an
    existing text file, read URLs/IDs from that file instead (one per
    line; blank lines and lines starting with # are ignored)."""
    raw = raw.strip()

    candidate_path = raw
    if (candidate_path.startswith('"') and candidate_path.endswith('"')) or (
        candidate_path.startswith("'") and candidate_path.endswith("'")
    ):
        candidate_path = candidate_path[1:-1]

    if candidate_path.lower().endswith((".txt", ".csv")) and os.path.isfile(candidate_path):
        print(f"  Reading URLs from file: {candidate_path}")
        entries = []
        with open(candidate_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                entries.extend(split_inputs(line))
        return entries

    parts = re.split(r"[,\s;]+", raw)
    return [p for p in parts if p]


def expand_entries(entries: list[str]) -> list[str]:
    """Replace any playlist URL in the list with the video IDs it
    contains. Plain video URLs/IDs pass through unchanged."""
    expanded = []
    for entry in entries:
        playlist_id = extract_playlist_id(entry)
        if playlist_id:
            print(f"  Expanding playlist {playlist_id} ...")
            try:
                video_ids = get_playlist_video_ids(playlist_id)
            except Exception as exc:
                print(f"  [FAIL] Could not read playlist {playlist_id}: {exc}")
                continue
            if not video_ids:
                print(f"  [FAIL] Playlist {playlist_id} had no videos (private or empty?).")
                continue
            print(f"  Found {len(video_ids)} video(s) in playlist.")
            expanded.extend(video_ids)
        else:
            expanded.append(entry)
    return expanded


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    print("YouTube Transcript Downloader")
    print(f"Transcripts will be saved to: {os.path.abspath(OUTPUT_DIR)}")
    print(f"Running up to {MAX_WORKERS} extraction(s) at once.")
    print("Paste one or more video/playlist URLs or IDs (space or comma separated).")
    print("Type 'q' or 'quit' to exit.\n")

    while True:
        try:
            raw = input("Video URL(s) > ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nExiting.")
            break

        if raw.lower() in ("q", "quit", "exit"):
            print("Exiting.")
            break

        if not raw:
            continue

        entries = split_inputs(raw)
        if not entries:
            continue

        entries = expand_entries(entries)
        if not entries:
            print()
            continue

        with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
            futures = {
                executor.submit(process_video, entry, OUTPUT_DIR): entry
                for entry in entries
            }
            for future in as_completed(futures):
                label, success, message = future.result()
                if success:
                    print(f"  [OK]   {label} -> {message}")
                else:
                    print(f"  [FAIL] {label}: {message}")

        print()


if __name__ == "__main__":
    main()

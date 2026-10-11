"""Extract a timestamped transcript from a YouTube URL or a local video file.

    python extract_video.py "<url-or-path>" <out.json>

Prints a one-line status to stdout and writes JSON to out.json.

Three tiers, cheapest first, because the expensive one is almost never needed:

  1. YouTube captions. Free, instant, no download. Covers nearly everything,
     since YouTube auto-captions almost all uploads.
  2. Local file. Audio decoded straight out of the container by PyAV and
     transcribed by the faster-whisper already installed for voice notes.
     Nothing leaves the machine, which matters for client call recordings.
  3. Frames for on-screen content. NOT implemented. It is the only tier that
     needs a vision model and real money, and it should be added when a video
     actually requires it rather than on speculation.

Deliberately NOT used: yt-dlp audio download as a fallback for uncaptioned
YouTube videos. Tested 2026-08-09 and YouTube returned 403 Forbidden. It is an
arms race that breaks silently, and a knowledge pipeline that fails silently is
worse than one that says it cannot do something.
"""

import json
import os
import re
import sys
import urllib.parse
import urllib.request
import warnings

warnings.filterwarnings("ignore")

YT = re.compile(
    r"(?:youtube\.com/(?:watch\?(?:.*&)?v=|shorts/|embed/|live/)|youtu\.be/)([A-Za-z0-9_-]{11})"
)

# drive.google.com/file/d/<id>/... or ...open?id=<id> or ...uc?id=<id>
DRIVE = re.compile(r"drive\.google\.com/(?:file/d/|open\?id=|uc\?id=)([A-Za-z0-9_-]{20,})")


def video_id(s):
    m = YT.search(s)
    return m.group(1) if m else None


def drive_id(s):
    m = DRIVE.search(s)
    return m.group(1) if m else None


def from_drive(fid):
    """Download a Google Drive file to disk, then transcribe it like any local
    file. Uses gdown, which streams to disk, so there is no size limit and no
    base64 through the context window.

    Only works for files shared 'anyone with the link'. A private file needs
    Sara's Google auth, which this headless path does not have, so it fails with
    a clear reason and the caller points her at the Inbox folder instead.
    """
    import gdown

    dest = os.path.join(
        os.environ.get("TEMP", "/tmp"), "aya-drive-" + fid[:16]
    )
    out = gdown.download(id=fid, output=dest, quiet=True, fuzzy=True)
    if not out or not os.path.exists(out):
        raise RuntimeError(
            "could not download this Drive file. It is probably private. Either "
            "share it as 'anyone with the link' or drop the file in the Aya Inbox "
            "folder, which handles private files with no size limit."
        )
    data = from_file(out)
    data["source"] = "google-drive:" + fid
    data["kind"] = "drive-" + data["kind"]
    try:
        os.remove(out)
    except Exception:
        pass
    return data


def yt_meta(vid):
    """Title and channel via oEmbed. No API key, no download, no auth."""
    out = {"title": None, "author": None}
    try:
        url = "https://www.youtube.com/oembed?url=%s&format=json" % urllib.parse.quote(
            "https://www.youtube.com/watch?v=" + vid, safe=""
        )
        with urllib.request.urlopen(url, timeout=20) as r:
            d = json.load(r)
        out["title"] = d.get("title")
        out["author"] = d.get("author_name")
    except Exception:
        pass
    return out


def from_youtube(vid):
    from youtube_transcript_api import YouTubeTranscriptApi

    api = YouTubeTranscriptApi()
    # Prefer a real human transcript over auto-captions when both exist:
    # auto-captions mangle proper nouns, and Sara's world is full of them.
    try:
        lst = api.list(vid)
        tr = None
        try:
            tr = lst.find_manually_created_transcript(["en", "en-US", "en-GB"])
            kind = "youtube-captions-manual"
        except Exception:
            tr = lst.find_transcript(["en", "en-US", "en-GB"])
            kind = "youtube-captions-auto"
        segs = tr.fetch()
    except Exception:
        segs = api.fetch(vid)
        kind = "youtube-captions"

    items = [
        {"t": round(float(s.start), 1), "text": s.text.replace("\n", " ").strip()}
        for s in segs
        if s.text and s.text.strip()
    ]
    dur = 0.0
    if items:
        last = segs[-1]
        dur = float(last.start) + float(getattr(last, "duration", 0) or 0)
    meta = yt_meta(vid)
    return {
        "kind": kind,
        "source": "https://www.youtube.com/watch?v=" + vid,
        "title": meta["title"] or vid,
        "author": meta["author"],
        "duration_sec": round(dur),
        "segments": items,
    }


def from_file(path):
    from faster_whisper import WhisperModel

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        from transcribe import VOCAB, MODEL
    except Exception:
        VOCAB, MODEL = None, "base.en"

    model = WhisperModel(MODEL, device="cpu", compute_type="int8")
    segs, info = model.transcribe(
        path, beam_size=5, vad_filter=True, initial_prompt=VOCAB
    )
    items = []
    dur = 0.0
    for s in segs:
        txt = s.text.strip()
        if txt:
            items.append({"t": round(float(s.start), 1), "text": txt})
        dur = max(dur, float(s.end))
    return {
        "kind": "local-whisper",
        "source": os.path.abspath(path),
        "title": os.path.splitext(os.path.basename(path))[0],
        "author": None,
        "duration_sec": round(dur),
        "segments": items,
    }


def main():
    if len(sys.argv) < 3:
        print("EXTRACT_FAILED: usage: extract_video.py <url-or-path> <out.json>")
        return 1
    target, out = sys.argv[1], sys.argv[2]

    vid = video_id(target)
    did = drive_id(target)
    try:
        if vid:
            data = from_youtube(vid)
        elif did:
            data = from_drive(did)
        elif os.path.exists(target):
            data = from_file(target)
        elif target.startswith("http"):
            print(
                "EXTRACT_FAILED: that is a URL but not a YouTube or Google Drive "
                "video. Supported: YouTube links, Google Drive links, and local files."
            )
            return 1
        else:
            print("EXTRACT_FAILED: not a supported URL and not a file that exists: %s" % target)
            return 1
    except Exception as e:
        msg = str(e).replace("\n", " ")[:300]
        # Name the two common ones plainly, because the library's own message
        # buries them and the fix is different for each.
        if "TranscriptsDisabled" in type(e).__name__ or "disabled" in msg.lower():
            print("EXTRACT_FAILED: captions are turned off for this video. No local "
                  "fallback exists for YouTube. Ask for the file instead.")
        elif "NoTranscriptFound" in type(e).__name__:
            print("EXTRACT_FAILED: no English transcript on this video.")
        else:
            print("EXTRACT_FAILED: %s: %s" % (type(e).__name__, msg))
        return 1

    if not data["segments"]:
        # An empty transcript handed onward as if it were content would have Aya
        # summarising silence.
        print("EXTRACT_FAILED: transcript came back empty")
        return 1

    words = sum(len(s["text"].split()) for s in data["segments"])
    data["word_count"] = words
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)

    print(
        "EXTRACT_OK|%s|%s|%d|%d|%s"
        % (data["kind"], data["title"], data["duration_sec"], words, data["author"] or "")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Transcribe a Telegram voice note for Aya.

Usage:  python transcribe.py <audio-file>
Prints the transcript to stdout, or TRANSCRIBE_FAILED: <reason> to stdout and
exits 1.

Deliberate choices:

  base.en   Sara's C drive had 4.2 GB free when this was built. base.en is
            about 75 MB against small.en's 250 MB and medium's 1.5 GB. For
            short spoken instructions from one known speaker in English it is
            accurate enough, and it runs on CPU in a couple of seconds. If
            accuracy disappoints, small.en is a one-word change here, but
            check the disk first.

  int8      CPU quantisation. Roughly twice as fast as float32 with no
            meaningful accuracy loss at this model size.

  local     The model downloads once to the HuggingFace cache, then never
            touches the network again. No API key, no per-minute cost, no
            vendor to be down, and Sara's voice never leaves the machine.
            That last point matters: she talks about clients and revenue.

  retry + tiny.en fallback   Added 2026-08-14. On 2026-08-12 two voice notes
            in a row died with "mkl_malloc failed to allocate memory": the
            machine was under momentary memory pressure and each note was
            simply lost, costing Sara 27 seconds of instructions. So now:
            threads are capped (smaller scratch allocations), a failure is
            retried once, and the last resort is tiny.en, whose working set
            is about a third of base.en's. A rougher transcript beats a lost
            message every time.
"""

import sys, os, gc, warnings

warnings.filterwarnings("ignore")

# Fewer threads means smaller MKL scratch buffers, which is exactly what ran
# out on 2026-08-12. Two threads is still fast for a sub-minute note.
os.environ.setdefault("OMP_NUM_THREADS", "2")

# (model, note) in the order tried. base twice because the 08-12 failure was
# transient pressure, then tiny as the low-memory last resort.
ATTEMPTS = (
    ("base.en", "first try"),
    ("base.en", "retry after failure"),
    ("tiny.en", "low-memory fallback"),
)

# Whisper guesses proper nouns from sound alone and gets Sara's vocabulary
# wrong: a test note saying "tell Zack" came back as "tells Aya". An
# initial_prompt biases the decoder toward words it expects to hear, which is
# the cheapest accuracy win available on a small model.
#
# Keep this list to names and terms Sara actually says out loud. A bloated
# prompt makes Whisper hallucinate these words into audio that never had them,
# so add sparingly and remove anything she has stopped talking about.
VOCAB = (
    "Aya. Sara Sheikh. Saibble. Zack. Vikas. Nabil. Robin Whitley. Becky Amble. "
    "Mark Ipaviz. Hayat. Breyon. Fer Patel. Jewels Watier. "
    "Saevel. Fabiale. Evianny. SocialMuse. Israa. AIFO. Sassy and Secure. "
    "Bravaya. Nonprofit360. UHV. ClearToCompete. OmegaCore. CES. "
    "GoHighLevel. Telegram. Discord. Outlook. OpenRouter. Obsidian. "
    "AZ Cybersecurity. Security Training. Turnstile. Supabase. Vercel."
)


def transcribe_once(path, model_name):
    from faster_whisper import WhisperModel

    model = WhisperModel(model_name, device="cpu", compute_type="int8",
                         cpu_threads=2)
    # vad_filter drops silence, which stops Whisper inventing words to fill
    # dead air. Telegram voice notes usually open with a moment of it.
    segments, info = model.transcribe(
        path, beam_size=5, vad_filter=True, initial_prompt=VOCAB
    )
    text = " ".join(s.text.strip() for s in segments).strip()
    # Free the model before any retry so two never coexist in memory.
    del segments, model
    gc.collect()
    return text


def main():
    if len(sys.argv) < 2:
        print("TRANSCRIBE_FAILED: no file given")
        return 1
    path = sys.argv[1]
    if not os.path.exists(path):
        print("TRANSCRIBE_FAILED: file not found: %s" % path)
        return 1

    try:
        import faster_whisper  # noqa: F401
    except Exception as e:
        print("TRANSCRIBE_FAILED: faster-whisper not importable: %s" % e)
        return 1

    errors = []
    for model_name, note in ATTEMPTS:
        try:
            text = transcribe_once(path, model_name)
        except Exception as e:
            errors.append("%s (%s): %s" % (model_name, note, e))
            gc.collect()
            continue
        if text:
            print(text)
            return 0
        # Silence is a real outcome and must not be reported as a transcript.
        # An empty string handed to Aya as if it were speech would have her
        # answering a message Sara never sent. It is also not a memory error,
        # so retrying another model would invent nothing better.
        print("TRANSCRIBE_FAILED: no speech detected")
        return 1

    print("TRANSCRIBE_FAILED: all attempts failed: " + " | ".join(errors))
    return 1


if __name__ == "__main__":
    sys.exit(main())

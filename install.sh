#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

echo "=== S10 Offline Transcriber — One-Click Installer ==="

# -----------------------------
# 0) Sanity
# -----------------------------
if ! command -v pkg >/dev/null 2>&1; then
  echo "This script must run inside the Termux app."
  exit 1
fi

# -----------------------------
# 1) Termux packages (+ API check)
# -----------------------------
echo "[*] Updating Termux..."
pkg update -y && pkg upgrade -y

echo "[*] Installing base packages..."
pkg install -y git build-essential ffmpeg python openssh

# Check/advise for Termux:API (needed for notifications, mic record, clipboard, open)
echo "[*] Checking Termux:API..."
if ! pkg list-installed | grep -q '^termux-api/'; then
  echo "⚠️  Termux:API package not installed in Termux."
  echo "   • Install the companion app from F-Droid: https://f-droid.org/packages/com.termux.api/"
  echo "   • Then run in Termux:  pkg install termux-api"
  echo "   Installer will continue, but any 'termux-*' commands will fail until you do this."
else
  echo "✓ Termux:API found."
fi

echo "[*] Installing Python extras (wake-word & audio IO)..."
pkg install -y python-pip portaudio || true
python -m pip install --upgrade pip || true
python -m pip install numpy sounddevice openwakeword || true

# -----------------------------
# 2) Whisper.cpp
# -----------------------------
echo "[*] Setting up whisper.cpp..."
if [ ! -d "$HOME/whisper.cpp" ]; then
  git clone https://github.com/ggerganov/whisper.cpp "$HOME/whisper.cpp"
  cd "$HOME/whisper.cpp"
  make
else
  cd "$HOME/whisper.cpp"
  git pull || true
  make
fi

echo "[*] Downloading Whisper models (tiny.en, base.en)..."
cd "$HOME/whisper.cpp/models"
./download-ggml-model.sh tiny.en
./download-ggml-model.sh base.en

# -----------------------------
# 3) Folders
# -----------------------------
echo "[*] Creating folders..."
mkdir -p "$HOME/bin" "$HOME/logs" "$HOME/Recordings" "$HOME/Transcripts"

# -----------------------------
# 4) Config
# -----------------------------
echo "[*] Writing config.env..."
cat > "$HOME/bin/config.env" << 'EOF_CFG'
# ====== Pocket Transcriber Config ======
# MODEL: tiny or base (English-only)
MODEL=base
# DENOISE: yes/no (light noise reduction via ffmpeg afftdn)
DENOISE=yes
# After transcription, serve the transcript folder on :8080 for N minutes (0 disables)
AUTOSERVE_MINUTES=0
# Chaptering thresholds (if SRT present)
CHAPTER_GAP=7
MIN_CHAPTER_LEN=30
EOF_CFG

# -----------------------------
# 5) Core scripts
# -----------------------------
echo "[*] Writing core scripts..."

# Start recording
cat > "$HOME/bin/start_record.sh" << 'EOF_START'
#!/data/data/com.termux/files/usr/bin/bash
set -e
OUTDIR="$HOME/Recordings"
mkdir -p "$OUTDIR"
STAMP=$(date +%Y%m%d_%H%M%S)
RAW="$OUTDIR/rec_${STAMP}.wav"
# Stop any previous recorder
termux-microphone-record --stop >/dev/null 2>&1 || true
termux-notification --id 7001 --title "Recorder" --content "Recording started…" --ongoing
termux-microphone-record --file "$RAW" --start
echo "$RAW" > "$HOME/.current_recording"
EOF_START

# Stop + transcribe
cat > "$HOME/bin/stop_and_transcribe.sh" << 'EOF_STOP'
#!/data/data/com.termux/files/usr/bin/bash
set -e
CONF="$HOME/bin/config.env"
[ -f "$CONF" ] && source "$CONF" || true

REC_FILE=$(cat "$HOME/.current_recording" 2>/dev/null || true)
if [ -z "$REC_FILE" ] || [ ! -f "$REC_FILE" ]; then
  termux-notification --id 7001 --title "Recorder" --content "No active recording found." --prio max
  exit 1
fi

termux-microphone-record --stop || true
termux-notification --id 7001 --title "Transcribe" --content "Preparing audio…" --prio max

BASE=$(basename "$REC_FILE" .wav)
DIR=$(dirname "$REC_FILE")
WAV16="${DIR}/${BASE}_16k.wav"

# Normalize to 16k mono (optional denoise)
if [ "${DENOISE,,}" = "yes" ]; then
  ffmpeg -y -i "$REC_FILE" -af "afftdn=nf=-20" -ac 1 -ar 16000 -c:a pcm_s16le "$WAV16" >/dev/null 2>&1
else
  ffmpeg -y -i "$REC_FILE" -ac 1 -ar 16000 -c:a pcm_s16le "$WAV16" >/dev/null 2>&1
fi

# Choose model
if [ "${MODEL,,}" = "tiny" ]; then
  MODEL_PATH="${HOME}/whisper.cpp/models/ggml-tiny.en.bin"
else
  MODEL_PATH="${HOME}/whisper.cpp/models/ggml-base.en.bin"
fi

termux-notification --id 7001 --title "Transcribe" --content "Running Whisper (${MODEL_PATH##*/})…" --prio max --ongoing
cd "$HOME/whisper.cpp"
LOG="$HOME/logs/whisper_$(date +%s).log"
./main -m "$MODEL_PATH" -f "$WAV16" -otxt -osrt -ovtt > "$LOG" 2>&1 || {
  termux-notification --id 7001 --title "Transcribe" --content "Whisper failed. See logs." --prio max
  echo "Whisper failed. Log: $LOG"
  exit 2
}

# Collect outputs
TRG="$HOME/Transcripts/$(basename "$BASE")"
mkdir -p "$TRG"
for ext in txt srt vtt; do
  [ -f "${WAV16}.${ext}" ] && mv "${WAV16}.${ext}" "$TRG/"
done

TXT="$TRG/$(basename "$WAV16").txt"
SRT="$TRG/$(basename "$WAV16").srt"

# Postprocess
termux-notification --id 7001 --title "Transcribe" --content "Post-processing…" --prio max --ongoing
python "$HOME/bin/postprocess_transcript.py" --txt "$TXT" --srt "$SRT" --outdir "$TRG" --gap "${CHAPTER_GAP:-7}" --minlen "${MIN_CHAPTER_LEN:-30}" || true
python "$HOME/bin/export_tasks.py" --tasks "$TRG/tasks.md" --outdir "$TRG" || true

# Optional local share
if [ "${AUTOSERVE_MINUTES:-0}" -gt 0 ]; then
  termux-notification --id 7002 --title "Local Share" --content "Serving $(basename "$TRG") for ${AUTOSERVE_MINUTES} min on http://<S10-IP>:8080/" --prio max
  ( cd "$TRG" && nohup sh -c "python3 -m http.server 8080 & SERVER_PID=$!; sleep $((60*AUTOSERVE_MINUTES)); kill $SERVER_PID 2>/dev/null || true" >/dev/null 2>&1 & )
fi

termux-notification --id 7001 --title "Transcribe" --content "Done → $(basename "$TRG")" --prio max
rm -f "$HOME/.current_recording"
echo "Saved to: $TRG"
EOF_STOP

# Toggle
cat > "$HOME/bin/toggle_rec.sh" << 'EOF_TOG'
#!/data/data/com.termux/files/usr/bin/bash
set -e
if [ -f "$HOME/.current_recording" ]; then
  sh "$HOME/bin/stop_and_transcribe.sh"
else
  sh "$HOME/bin/start_record.sh"
fi
EOF_TOG

# -----------------------------
# 6) Post-processing (Python)
# -----------------------------
echo "[*] Writing post-processing scripts..."

cat > "$HOME/bin/postprocess_transcript.py" << 'EOF_PP'
#!/data/data/com.termux/files/usr/bin/python
# Summary, tasks, chapters, highlights, tags + diarization-lite (if SRT present)
import argparse, re, os, collections

STOPWORDS=set('''a an the and or not of in on at to for with from up down by as is am are was were be been being
it its they them he she we you i this that these those there here then than so just very really have has had do did does
can could should would may might must will wont dont isnt arent wasnt werent havent hasnt hadnt couldnt wouldnt shouldnt
over under into out about across after before again further once each own same too only more most other some such no nor
per via within without between among upon your my our their his her theirs ours yours me us him her itself themselves'''.split())

def sent_tokenize(t): return [s.strip() for s in re.split(r'(?<=[.!?])\s+', t.strip()) if s.strip()]
def word_tokenize(t): return re.findall(r"[A-Za-z][A-Za-z\-']+", t.lower())
def top_keywords(t,n=12):
    words=[w for w in word_tokenize(t) if w not in STOPWORDS and len(w)>2]
    return [w for w,_ in collections.Counter(words).most_common(n)]
def summarize(t,n=6):
    sents=sent_tokenize(t); return sents[:n] if sents else []
def extract_tasks(t):
    return re.findall(r'(?:we|i|let\'s|lets|please|team)\s+(?:will|need to|should|must|can|to)\s+[^.]+', t, re.I)

def parse_srt(srt):
    blocks=[]; time_re=re.compile(r'(\d{2}):(\d{2}):(\d{2}),(\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2}),(\d{3})')
    chunk=[]
    for line in srt.splitlines():
        line=line.strip()
        if not line:
            if len(chunk)>=2:
                m=time_re.search(chunk[1])
                if m:
                    st=int(m.group(1))*3600+int(m.group(2))*60+int(m.group(3))+int(m.group(4))/1000.0
                    en=int(m.group(5))*3600+int(m.group(6))*60+int(m.group(7))+int(m.group(8))/1000.0
                    txt=" ".join(chunk[2:]).strip()
                    blocks.append((st,en,txt))
            chunk=[]; continue
        chunk.append(line)
    return blocks

def format_ts(sec):
    h=int(sec//3600); m=int((sec%3600)//60); s=int(sec%60)
    return f"{h:02d}:{m:02d}:{s:02d}"
def build_chapters(blocks,gap=7.0,minlen=30.0):
    if not blocks: return []
    out=[]; cs=blocks[0][0]; texts=[]; le=blocks[0][1]
    for st,en,txt in blocks:
        gapv=st-le
        if gapv>gap and (le-cs)>=minlen:
            out.append((cs,le," ".join(texts))); cs=st; texts=[txt]
        else: texts.append(txt)
        le=en
    if (le-cs)>=1.0: out.append((cs,le," ".join(texts)))
    return out
def diarize_lite(blocks,thr=1.6):
    if not blocks: return []
    segs=[]; label="Speaker A"; ss=blocks[0][0]; le=blocks[0][1]; lw=max(1,len(blocks[0][2].split()))
    for st,en,txt in blocks[1:]:
        gap=st-le; nw=max(1,len(txt.split())); ratio=nw/lw
        if gap>1.2 and (ratio>thr or ratio<1.0/thr):
            segs.append((ss,le,label))
            label="Speaker B" if label=="Speaker A" else "Speaker A"; ss=st
        le=en; lw=nw
    segs.append((ss,le,label)); return segs
def write_vtt(segs,path):
    with open(path,"w",encoding="utf-8") as f:
        f.write("WEBVTT\n\n")
        for st,en,label in segs:
            ms=lambda x: f"{int(x//3600):02d}:{int((x%3600)//60):02d}:{int(x%60):02d}.{int((x%1)*1000):03d}"
            f.write(f"{ms(st)} --> {ms(en)}\n{label}\n\n")

def main():
    import argparse
    ap=argparse.ArgumentParser()
    ap.add_argument("--txt",required=True)
    ap.add_argument("--srt",default=None)
    ap.add_argument("--outdir",required=True)
    ap.add_argument("--gap",type=float,default=7.0)
    ap.add_argument("--minlen",type=float,default=30.0)
    a=ap.parse_args()
    os.makedirs(a.outdir,exist_ok=True)
    text=open(a.txt,encoding="utf-8",errors="ignore").read()

    with open(os.path.join(a.outdir,"summary.md"),"w",encoding="utf-8") as f:
        f.write("# Summary\n\n"); [f.write(f"- {s}\n") for s in summarize(text,6)]
    tasks=extract_tasks(text)
    with open(os.path.join(a.outdir,"tasks.md"),"w",encoding="utf-8") as f:
        f.write("# Action Items\n\n")
        if not tasks: f.write("_No explicit tasks detected._\n")
        for t in tasks: f.write(f"- [ ] {t.strip()}\n")
    with open(os.path.join(a.outdir,"highlights.md"),"w",encoding="utf-8") as f:
        f.write("# Highlights\n\n"); [f.write(f"- {s}\n") for s in summarize(text,6)]
    with open(os.path.join(a.outdir,"tags.txt"),"w",encoding="utf-8") as f:
        f.write(", ".join(top_keywords(text,12)))

    # Chapters & diarization-lite if SRT present
    if a.srt and os.path.exists(a.srt):
        srt=open(a.srt,encoding="utf-8",errors="ignore").read()
        blocks=parse_srt(srt)
        chaps=build_chapters(blocks,a.gap,a.minlen)
        with open(os.path.join(a.outdir,"chapters.md"),"w",encoding="utf-8") as f:
            f.write("# Chapters\n\n")
            for st,en,txt in chaps:
                f.write(f"## {format_ts(st)}–{format_ts(en)}\n\n{' '.join(sent_tokenize(txt)[:2])}\n\n")
        write_vtt(diarize_lite(blocks), os.path.join(a.outdir,"speakers.vtt"))
    else:
        with open(os.path.join(a.outdir,"chapters.md"),"w",encoding="utf-8") as f:
            f.write("# Chapters\n\n_Add an SRT to enable chaptering._\n")

if __name__=="__main__":
    main()
EOF_PP
chmod +x "$HOME/bin/postprocess_transcript.py"

cat > "$HOME/bin/export_tasks.py" << 'EOF_EX'
#!/data/data/com.termux/files/usr/bin/python
# Convert tasks.md to CSV + ICS (VTODO)
import argparse, csv, os, re
from datetime import datetime

def parse_tasks(path):
    items=[]
    if not os.path.exists(path): return items
    for line in open(path,encoding="utf-8"):
        line=line.strip()
        if line.startswith("- [ ]"):
            desc=re.sub(r"\s*\(.*?\)\s*","",line[5:].strip())
            m_due=re.search(r"\(due:\s*([^)]+)\)",line,re.I)
            m_owner=re.search(r"\(owner:\s*([^)]+)\)",line,re.I)
            items.append({"desc":desc,"due":(m_due.group(1).strip() if m_due else None),"owner":(m_owner.group(1).strip() if m_owner else None)})
    return items

def write_csv(items,path):
    with open(path,"w",newline="",encoding="utf-8") as f:
        w=csv.DictWriter(f,fieldnames=["description","due","owner"]); w.writeheader()
        for it in items: w.writerow({"description":it["desc"],"due":it.get("due","") or "","owner":it.get("owner","") or ""})

def write_ics(items,path):
    now=datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    lines=["BEGIN:VCALENDAR","VERSION:2.0","PRODID:-//S10Transcriber//Tasks//EN"]
    esc=lambda s: s.replace("\\","\\\\").replace(",","\\,").replace(";","\\;")
    for i,it in enumerate(items,1):
        lines+=["BEGIN:VTODO",f"UID:{now}-{i}@s10transcriber",f"DTSTAMP:{now}",f"SUMMARY:{esc(it['desc'])}"]
        if it.get("due"): lines.append(f"DESCRIPTION:Due {esc(it['due'])}")
        if it.get("owner"): lines.append(f"DESCRIPTION:Owner {esc(it['owner'])}")
        lines.append("END:VTODO")
    lines.append("END:VCALENDAR")
    with open(path,"w",encoding="utf-8") as f: f.write("\n".join(lines))

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--tasks",required=True)
    ap.add_argument("--outdir",required=True)
    a=ap.parse_args()
    os.makedirs(a.outdir,exist_ok=True)
    items=parse_tasks(a.tasks)
    if not items: return
    write_csv(items, os.path.join(a.outdir,"tasks.csv"))
    write_ics(items, os.path.join(a.outdir,"tasks.ics"))

if __name__=="__main__":
    main()
EOF_EX
chmod +x "$HOME/bin/export_tasks.py"

# -----------------------------
# 7) Wake-word & helpers
# -----------------------------
echo "[*] Writing wake-word + helper scripts..."

cat > "$HOME/bin/wakeword_toggle.py" << 'EOF_WW'
#!/data/data/com.termux/files/usr/bin/python
# Wake-word listener triggers toggle on "hey note"/"okay note"
import os, time, subprocess
try:
    import numpy as np
    import sounddevice as sd
    from openwakeword.model import Model
except Exception as e:
    print("Deps missing. Run: pkg install -y python-pip portaudio && pip install numpy sounddevice openwakeword")
    raise

SAMPLE_RATE=16000; BLOCK=512
model=Model(wakeword_models=["hey_note","okay_note"])

def on_hotword():
    subprocess.run(["sh","/data/data/com.termux/files/home/bin/toggle_rec.sh"])

def audio_callback(indata, frames, time_info, status):
    mono=indata[:,0] if indata.ndim>1 else indata
    scores=model.predict(mono)
    for w,score in scores.items():
        if score>0.5:
            print("Hotword:",w,score)
            on_hotword(); model.reset(); break

def main():
    print("Wake-word ready: say 'hey note' to start, 'okay note' to stop.")
    with sd.InputStream(channels=1,samplerate=SAMPLE_RATE,blocksize=BLOCK,dtype="float32",callback=audio_callback):
        while True: time.sleep(0.1)

if __name__=="__main__":
    main()
EOF_WW
chmod +x "$HOME/bin/wakeword_toggle.py"

cat > "$HOME/bin/wakeword_start.sh" << 'EOF_WWS'
#!/data/data/com.termux/files/usr/bin/bash
nohup python /data/data/com.termux/files/home/bin/wakeword_toggle.py >/data/data/com.termux/files/home/logs/wakeword.log 2>&1 &
echo $! > /data/data/com.termux/files/home/.wakeword_pid
termux-notification --id 7003 --title "Wake Word" --content "Listening (hey note / okay note)..." --ongoing
EOF_WWS

cat > "$HOME/bin/wakeword_stop.sh" << 'EOF_WWE'
#!/data/data/com.termux/files/usr/bin/bash
if [ -f /data/data/com.termux/files/home/.wakeword_pid ]; then
  kill $(cat /data/data/com.termux/files/home/.wakeword_pid) 2>/dev/null || true
  rm -f /data/data/com.termux/files/home/.wakeword_pid
fi
pkill -f wakeword_toggle.py 2>/dev/null || true
termux-notification --id 7003 --remove
termux-toast "Wake word stopped"
EOF_WWE

cat > "$HOME/bin/list_transcripts.sh" << 'EOF_LT'
#!/data/data/com.termux/files/usr/bin/bash
N=${1:-30}
base="$HOME/Transcripts"
[ -d "$base" ] || exit 0
cd "$base"
ls -1t | head -n "$N"
EOF_LT

cat > "$HOME/bin/latest_transcript_dir.sh" << 'EOF_LD'
#!/data/data/com.termux/files/usr/bin/bash
base="$HOME/Transcripts"
[ -d "$base" ] || exit 1
cd "$base"
latest=$(ls -1t | head -n 1)
[ -n "$latest" ] && echo "$base/$latest"
EOF_LD

cat > "$HOME/bin/serve_latest.sh" << 'EOF_SL'
#!/data/data/com.termux/files/usr/bin/bash
CONF="$HOME/bin/config.env"
[ -f "$CONF" ] && source "$CONF" || true
MIN=${1:-$AUTOSERVE_MINUTES}
[ -z "$MIN" ] && MIN=10
dir=$("$HOME/bin/latest_transcript_dir.sh")
[ -z "$dir" ] && { termux-toast "No transcripts yet"; exit 1; }
termux-notification --id 7002 --title "Local Share" --content "Serving $(basename "$dir") for ${MIN} min on http://<S10-IP>:8080/" --prio max
( cd "$dir" && nohup sh -c "python3 -m http.server 8080 & SERVER_PID=$!; sleep $((60*MIN)); kill $SERVER_PID 2>/dev/null || true" >/dev/null 2>&1 & )
EOF_SL

cat > "$HOME/bin/open_latest_in_files.sh" << 'EOF_OL'
#!/data/data/com.termux/files/usr/bin/bash
dir=$("$HOME/bin/latest_transcript_dir.sh")
[ -z "$dir" ] && { termux-toast "No transcripts"; exit 1; }
termux-open --content-type text/plain "$dir/summary.md" 2>/dev/null || termux-open "$dir"
EOF_OL

cat > "$HOME/bin/copy_latest_path.sh" << 'EOF_CP'
#!/data/data/com.termux/files/usr/bin/bash
dir=$("$HOME/bin/latest_transcript_dir.sh")
[ -n "$dir" ] && echo -n "$dir" | termux-clipboard-set && termux-toast "Path copied"
EOF_CP

# -----------------------------
# 7.5) Export / zip / open helpers
# -----------------------------
cat > "$HOME/bin/export_to_storage.sh" << 'EOF_EXP'
#!/data/data/com.termux/files/usr/bin/bash
set -e
SRC_DIR="${1:-}"
if [ -z "$SRC_DIR" ]; then
  SRC_DIR=$(ls -1dt "$HOME/Transcripts"/* 2>/dev/null | head -n1)
fi
[ -z "$SRC_DIR" ] && { echo "No transcript folder found."; exit 1; }
DEST_BASE="$HOME/storage/shared/Documents/Transcripts"
mkdir -p "$DEST_BASE"
SESSION="$(basename "$SRC_DIR")"
DEST="$DEST_BASE/$SESSION"
rm -rf "$DEST"
cp -a "$SRC_DIR" "$DEST"
echo "Exported to: $DEST"
termux-toast "Exported to Documents/Transcripts/$SESSION" 2>/dev/null || true
EOF_EXP
chmod +x "$HOME/bin/export_to_storage.sh"

cat > "$HOME/bin/zip_transcript.sh" << 'EOF_ZIP'
#!/data/data/com.termux/files/usr/bin/bash
set -e
SRC_DIR="${1:-}"
if [ -z "$SRC_DIR" ]; then
  SRC_DIR=$(ls -1dt "$HOME/Transcripts"/* 2>/dev/null | head -n1)
fi
[ -z "$SRC_DIR" ] && { echo "No transcript folder found."; exit 1; }
SESSION="$(basename "$SRC_DIR")"
DEST_DIR="$HOME/storage/shared/Documents/Transcripts"
mkdir -p "$DEST_DIR"
ZIP="$DEST_DIR/${SESSION}.zip"
rm -f "$ZIP"
( cd "$(dirname "$SRC_DIR")" && zip -r "$ZIP" "$SESSION" >/dev/null )
echo "Zipped to: $ZIP"
termux-toast "Zipped → Documents/Transcripts/${SESSION}.zip" 2>/dev/null || true
EOF_ZIP
chmod +x "$HOME/bin/zip_transcript.sh"

cat > "$HOME/bin/open_exported_summary.sh" << 'EOF_OPEN'
#!/data/data/com.termux/files/usr/bin/bash
set -e
BASE="$HOME/storage/shared/Documents/Transcripts"
[ -d "$BASE" ] || { echo "No exported transcripts in Documents/Transcripts"; exit 1; }
LATEST=$(ls -1dt "$BASE"/*/ 2>/dev/null | head -n1)
[ -z "$LATEST" ] && { echo "No exported transcript folder found"; exit 1; }
if [ -f "${LATEST}/summary.md" ]; then
  termux-open --content-type text/markdown "${LATEST}/summary.md" 2>/dev/null || termux-open "${LATEST}/summary.md"
else
  termux-open "${LATEST}"
fi
EOF_OPEN
chmod +x "$HOME/bin/open_exported_summary.sh"


# -----------------------------
# 8) Permissions
# -----------------------------
chmod +x "$HOME/bin/"*.sh || true

# -----------------------------
# 9) Final tips
# -----------------------------
echo
echo "=== Install complete! ==="
echo "Try these commands:"
echo "  sh ~/bin/start_record.sh           # start recording"
echo "  sh ~/bin/stop_and_transcribe.sh    # stop & transcribe (offline)"
echo "  sh ~/bin/toggle_rec.sh             # single-button toggle"
echo
echo "Wake-word (optional):"
echo "  sh ~/bin/wakeword_start.sh         # say 'hey note' / 'okay note'"
echo "  sh ~/bin/wakeword_stop.sh"
echo
echo "Transcript helpers:"
echo "  sh ~/bin/list_transcripts.sh 20    # list recent"
echo "  sh ~/bin/serve_latest.sh 10        # serve latest on :8080 for 10 min"
echo "  sh ~/bin/open_latest_in_files.sh   # open latest in a viewer"
echo "  sh ~/bin/copy_latest_path.sh       # copy latest path to clipboard"
echo
echo "Files land in:"
echo "  Audio:       ~/Recordings/"
echo "  Transcripts: ~/Transcripts/<session>/"
echo "    summary.md, tasks.md, chapters.md, highlights.md, tags.txt, speakers.vtt, tasks.csv, tasks.ics"
echo
echo "If you saw the Termux:API warning above, install it from F-Droid and run: pkg install termux-api"

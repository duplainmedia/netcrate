# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
import hashlib
import json
import subprocess
import sys
from fractions import Fraction
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps
from verify_media import verify_sample
from disk_reserve import run_guarded

ROOT = Path(r"C:\NetCrate\Workspace")
JOB = ROOT / "work" / "sample-project"
OUT = ROOT / "outputs" / "Sample-Project-Test"
BIN = Path(r"C:\ProgramData\NetCrate\Office\Tools\FFmpeg")
FLAGS = subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS

def run_tool(args, log_path, on_poll=None):
    log_path.parent.mkdir(parents=True, exist_ok=True)
    result = run_guarded(args, log_path.parent, capture_output=True, text=True, creationflags=FLAGS, on_poll=on_poll)
    log_path.write_text(result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"Media command failed; inspect {log_path}")
    return result.stdout

def probe(path, log_path):
    data = json.loads(run_tool([str(BIN / "ffprobe.exe"), "-v", "error", "-count_frames", "-show_streams", "-show_format", "-of", "json", str(path)], log_path))
    video = next(s for s in data["streams"] if s["codec_type"] == "video")
    timecode = video.get("tags", {}).get("timecode") or data["format"].get("tags", {}).get("timecode")
    if not timecode:
        timecode = next((s.get("tags", {}).get("timecode") for s in data["streams"] if s.get("tags", {}).get("timecode")), None)
    return {"video": video, "audio": [s for s in data["streams"] if s["codec_type"] == "audio"], "format": data["format"], "timecode": timecode}

def file_hash(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest().upper()

def display_time(seconds):
    milliseconds = round(seconds * 1000)
    hours, rem = divmod(milliseconds, 3600000)
    minutes, rem = divmod(rem, 60000)
    secs, ms = divmod(rem, 1000)
    return f"{hours:02}:{minutes:02}:{secs:02}.{ms:03}"

def make_contact_sheet(item, destination, sample_work, progress=None):
    timestamps = [item["duration"] * (i + 0.5) / 12 for i in range(12)]
    sheet = Image.new("RGB", (1232, 1176), "#10151c")
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.truetype(r"C:\Windows\Fonts\segoeui.ttf", 18)
    heading = ImageFont.truetype(r"C:\Windows\Fonts\segoeuib.ttf", 25)
    draw.text((24, 16), item.get("project_label", "SAMPLE PROJECT") + "  |  " + item["camera"] + "  |  " + Path(item["path"]).name, font=heading, fill="white")
    video = item["video"]
    details = f'{video["width"]} x {video["height"]}  |  {float(Fraction(video["avg_frame_rate"])):.3f} fps  |  Duration {display_time(item["duration"])}'
    draw.text((24, 52), details, font=font, fill="#bdc9d8")
    for index, timestamp in enumerate(timestamps):
        frame_path = sample_work / f"frame-{index:02}.jpg"
        run_tool([str(BIN / "ffmpeg.exe"), "-nostdin", "-hide_banner", "-v", "error", "-n", "-ss", f"{timestamp:.6f}", "-i", item["path"], "-frames:v", "1", "-vf", "scale=384:-2", "-threads", "2", "-filter_threads", "1", "-q:v", "3", str(frame_path)], sample_work / f"frame-{index:02}.log")
        if progress: progress.sheet_frame(index+1)
        with Image.open(frame_path) as image:
            tile = ImageOps.contain(image.convert("RGB"), (384, 216))
            column, row = index % 3, index // 3
            x, y = 24 + column * 400, 96 + row * 260
            sheet.paste(tile, (x + (384 - tile.width) // 2, y + (216 - tile.height) // 2))
            draw.text((x, y + 220), f"{index + 1:02}  |  {display_time(timestamp)}", font=font, fill="#e0e8f0")
    draw.text((24, 1144), "12 evenly spaced source frames | labels are elapsed clip time | no creative LUT applied", font=font, fill="#94a8ba")
    sheet.save(destination, quality=93, subsampling=0)
    return timestamps


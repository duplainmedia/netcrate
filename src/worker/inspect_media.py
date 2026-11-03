# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
import json
import argparse
import subprocess
from collections import Counter
from pathlib import Path
from validate_restore import validate_restore

ROOT = Path(r"C:\NetCrate\Workspace")
JOB = ROOT / "work" / "sample-project"
FFPROBE = Path(r"C:\ProgramData\NetCrate\Office\Tools\FFmpeg\ffprobe.exe")

def write_json_atomic(path, value):
    partial = path.with_suffix(path.suffix + '.writing')
    partial.write_text(json.dumps(value, indent=2), encoding='utf-8')
    partial.replace(path)

parser = argparse.ArgumentParser()
parser.add_argument("--job-root", type=Path, default=JOB)
arguments = parser.parse_args()
JOB = arguments.job_root.resolve()
verification = json.loads((JOB / "restore-verification.json").read_text(encoding="utf-8-sig"))
assert verification["ResticVerifyPassed"] and verification["Files"] > 0
validate_restore(verification)
inventory = []
output_names = set()
for path in sorted((JOB / "originals").rglob("*")):
    if not path.is_file() or path.suffix.lower() not in (".mp4", ".mov", ".mxf", ".mts", ".m2ts", ".avi", ".mkv", ".mpg", ".mpeg", ".webm"):
        continue
    result = subprocess.run([str(FFPROBE), "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)], capture_output=True, text=True, check=True)
    probe = json.loads(result.stdout)
    video = next(s for s in probe["streams"] if s["codec_type"] == "video")
    audio = [s for s in probe["streams"] if s["codec_type"] == "audio"]
    relative = path.relative_to(JOB / "originals")
    output_key = str(relative.with_suffix('')).casefold()
    if output_key in output_names:
        raise RuntimeError('Two media clips share an output stem; rename or split the project before processing.')
    output_names.add(output_key)
    timecode = video.get("tags", {}).get("timecode") or probe.get("format", {}).get("tags", {}).get("timecode")
    if not timecode:
        timecode = next((s.get("tags", {}).get("timecode") for s in probe["streams"] if s.get("tags", {}).get("timecode")), None)
    inventory.append({
        "path": str(path), "relative_path": str(relative), "camera": relative.parts[0] if len(relative.parts) > 1 else "Footage",
        "video": video, "audio": audio, "format": probe["format"], "timecode": timecode,
        "duration": float(video.get("duration") or probe["format"]["duration"]),
    })
    print(f"PROBED {relative}", flush=True)
if not inventory:
    raise RuntimeError('No supported video files found in this footage set.')
write_json_atomic(JOB / 'media-inventory.json', inventory)
verification["VideoFiles"] = len(inventory)
write_json_atomic(JOB / 'restore-verification.json', verification)
counts = Counter((item["camera"], item["video"]["codec_name"], item["video"]["width"], item["video"]["height"], item["video"]["avg_frame_rate"], tuple((s["channels"], s.get("sample_rate")) for s in item["audio"])) for item in inventory)
for key, count in counts.items():
    print(count, key)
print("SUCCESS: probed", len(inventory), "verified restored media files.")

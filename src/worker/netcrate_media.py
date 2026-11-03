"""Encode and verify one immutable NetCrate generation."""
import csv
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import media_tools
from verify_media import verify_sample


def run(args, log):
    log.parent.mkdir(parents=True, exist_ok=True)
    reserve = 5 * 1024**3
    if shutil.disk_usage(log.parent).free < reserve:
        raise RuntimeError("Free at least 5 GB on the processing drive before retrying.")
    capture = log.with_suffix(".stdout")
    with log.open("w", encoding="utf-8") as errors, capture.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=output, stderr=errors,
                                   creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS)
        started = time.monotonic()
        try:
            while process.poll() is None:
                if shutil.disk_usage(log.parent).free < reserve or time.monotonic() - started > 86400:
                    raise RuntimeError("Processing stopped because its space or time limit was reached.")
                time.sleep(0.1)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    if process.returncode:
        raise RuntimeError("Media processing failed. See the server's job log.")
    if capture.stat().st_size > 8 * 1024**2:
        raise RuntimeError("The media tool returned too much metadata.")
    return capture.read_text(encoding="utf-8")


def sha(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest().lower()


def generate(spec):
    out, work = Path(spec["Output"]), Path(spec["Work"])
    out.mkdir(parents=True, exist_ok=False)
    work.mkdir(parents=True, exist_ok=True)
    media_tools.BIN = Path(spec["FFmpeg"]).parent
    media_tools.run_tool = lambda args, log, on_poll=None: run(args, log)
    divisor = 2 if spec["Recipe"].startswith("half-prores-v2|") else 4
    index = []
    for number, item in enumerate(spec["Files"]):
        source = Path(item["Source"])
        relative = item["RelativePath"]
        original = media_tools.probe(source, work / f"{number}-source.log")
        original.update(path=str(source), camera="Source", project_label=spec["Project"],
                        duration=float(original["video"].get("duration") or original["format"]["duration"]))
        if original["video"]["width"] % (2 * divisor) or original["video"]["height"] % divisor:
            raise ValueError("The source dimensions cannot use the selected proxy scale exactly.")
        proxy = out / "Proxies" / (relative + ".mov")
        sheet = out / "Contact sheets" / (relative + ".jpg")
        proxy.parent.mkdir(parents=True, exist_ok=True)
        sheet.parent.mkdir(parents=True, exist_ok=True)
        logs = work / str(number)
        logs.mkdir(exist_ok=True)
        args = [spec["FFmpeg"], "-nostdin", "-hide_banner", "-v", "error", "-n", "-i", str(source),
                "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0", "-map_chapters", "0",
                "-vf", f"scale=iw/{divisor}:ih/{divisor}", "-c:v", "prores_ks", "-profile:v", "0",
                "-pix_fmt", "yuv422p10le", "-fps_mode", "passthrough", "-c:a", "pcm_s24le",
                "-threads", "2", "-filter_threads", "1"]
        if original["timecode"]:
            args += ["-timecode", original["timecode"]]
        run(args + [str(proxy)], logs / "encode.log")
        result = media_tools.probe(proxy, logs / "proxy.log")
        run([spec["FFmpeg"], "-nostdin", "-v", "error", "-i", str(proxy), "-f", "null", "-"], logs / "decode.log")
        times = media_tools.make_contact_sheet(original, sheet, logs)
        sample = dict(original=original, proxy=result, proxy_scale_divisor=divisor,
                      proxy_recipe="half-prores-v2" if divisor == 2 else "quarter-prores-v1",
                      decode_passed=True, proxy_path=str(proxy), contact_sheet_path=str(sheet),
                      contact_sheet_timestamps=times)
        verify_sample(sample)
        index.append({"Source": relative, "Proxy": proxy.relative_to(out).as_posix(),
                      "ContactSheet": sheet.relative_to(out).as_posix(), "Video": result["video"],
                      "Audio": result["audio"], "Timecode": result["timecode"]})
    (out / "media_index.json").write_text(json.dumps(index, ensure_ascii=False), encoding="utf-8")
    with (out / "Files-SHA256.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["Path", "Bytes", "SHA256"])
        writer.writeheader()
        for path in sorted(out.rglob("*")):
            if path.is_file() and path.name != "Files-SHA256.csv":
                writer.writerow(dict(Path=path.relative_to(out).as_posix(), Bytes=path.stat().st_size, SHA256=sha(path)))
    complete = {"Version": 2, "JobId": spec["JobId"], "GenerationSnapshotId": spec["SnapshotId"],
                "ProjectPath": spec["ProjectPath"], "Recipe": spec["Recipe"], "FootageFingerprint": spec["FootageFingerprint"],
                "Clips": len(index), "ResultManifestSHA256": sha(out / "Files-SHA256.csv")}
    (out / "COMPLETE.json").write_text(json.dumps(complete), encoding="utf-8")


if __name__ == "__main__":
    generate(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig")))

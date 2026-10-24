# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
import argparse
import csv
import json
import shutil
import time
import os
from pathlib import Path

import media_tools as m
from verify_media import verify_sample
from validate_restore import validate_restore
from media_index import write_index
from disk_reserve import assert_reserve
from office_media_progress import SafeReporter
from proxy_recipe import DEFAULT_DIVISOR, PIXEL_FORMAT, BIT_DEPTH, recipe_id, scale_filter

parser = argparse.ArgumentParser()
parser.add_argument("--inventory", type=Path, required=True)
parser.add_argument("--restore-report", type=Path, required=True)
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--label", required=True)
parser.add_argument('--proxy-divisor',type=int,choices=(2,4),default=DEFAULT_DIVISOR)
parser.add_argument('--proxy-recipe')
args = parser.parse_args()
recipe=recipe_id(args.proxy_divisor)
if args.proxy_recipe and args.proxy_recipe!=recipe:
    raise RuntimeError('Queued proxy recipe and scale differ; existing outputs preserved.')
verification = json.loads(args.restore_report.read_text(encoding="utf-8-sig"))
if not verification["ResticVerifyPassed"]:
    raise RuntimeError("Verified restore is required.")
validate_restore(verification)
inventory = json.loads(args.inventory.read_text(encoding="utf-8-sig"))
progress=SafeReporter(os.environ.get('OFFICE_MEDIA_PROGRESS_CONTEXT'),inventory)
progress.verify_stage()
if len(inventory) != verification.get("VideoFiles", verification["Files"]):
    raise RuntimeError("Media inventory does not match the verified restore.")
args.out.mkdir(parents=True, exist_ok=True)
assert_reserve(args.out)
job = args.inventory.parent
state_root = job / "batch-state"
state_root.mkdir(exist_ok=True)
sample_report = m.OUT / "sample-results.json"
samples = json.loads(sample_report.read_text(encoding="utf-8-sig")) if sample_report.exists() else []
reusable = {s["original"]["relative_path"]: s for s in samples}
results = []
started = time.time()

def write_json_atomic(path, value):
    partial = path.with_suffix(path.suffix + ".writing")
    partial.write_text(json.dumps(value, indent=2), encoding="utf-8")
    partial.replace(path)

for index, original in enumerate(inventory, 1):
    assert_reserve(args.out)
    item = dict(original, project_label=args.label)
    source = Path(item["path"])
    relative = Path(item["relative_path"])
    if relative.is_absolute() or ".." in relative.parts:
        raise RuntimeError("Unsafe media relative path.")
    camera_out = args.out / relative.parent
    camera_out.mkdir(parents=True, exist_ok=True)
    proxy_path = camera_out / f"{source.stem}_Proxy.mov"
    partial_path = camera_out / f"{source.stem}_Proxy.partial.mov"
    contact_path = camera_out / f"{source.stem}_ContactSheet.jpg"
    key = m.hashlib.sha256(item["relative_path"].encode()).hexdigest()[:24]
    state_path = state_root / f"{key}.json"
    sample_work = job / "batch-work" / key
    sample_work.mkdir(parents=True, exist_ok=True)
    print(f"START {index}/{len(inventory)} {item['relative_path']}", flush=True)
    write_json_atomic(job / "batch-status.json", {"state":"processing","clip":item["relative_path"],"completed":len(results),"total":len(inventory),"elapsed_seconds":round(time.time()-started),"output":str(args.out)})
    if state_path.exists():
        saved = json.loads(state_path.read_text(encoding="utf-8"))
        if saved.get('proxy_scale_divisor',4)!=args.proxy_divisor or saved.get('proxy_recipe',recipe_id(4))!=recipe:
            raise RuntimeError('Saved proxy uses another recipe; use its original job or a new output version.')
        if not proxy_path.exists() and partial_path.exists() and saved["original"]["path"] == item["path"] and m.file_hash(partial_path) == saved["proxy_sha256"]:
            partial_path.rename(proxy_path)
        if saved["original"]["path"] == item["path"] and m.file_hash(source) == saved["source_sha256"] and Path(saved["proxy_path"]) == proxy_path and m.file_hash(proxy_path) == saved["proxy_sha256"] and m.file_hash(contact_path) == saved["contact_sheet_sha256"]:
            verify_sample(saved)
            results.append(saved)
            progress.reused(item.get('duration'))
            print(f"REUSED {index}/{len(inventory)} verified prior result", flush=True)
            continue
        raise RuntimeError("Existing result does not match this job; refusing overwrite.")
    original_hash = m.file_hash(source)
    previous = None  # Fresh jobs encode their own files; prior completed states resume above.
    if previous and previous["original"]["path"] == item["path"] and previous["source_sha256"] == original_hash:
        verify_sample(previous)
        for old, new in ((Path(previous["proxy_path"]),proxy_path),(Path(previous["contact_sheet_path"]),contact_path)):
            if new.exists():
                raise RuntimeError("Untracked output already exists; refusing overwrite.")
            shutil.copy2(old,new)
        result = dict(previous, original=item, proxy_path=str(proxy_path), contact_sheet_path=str(contact_path))
        result["proxy"]["format"]["filename"] = str(proxy_path)
    else:
        if proxy_path.exists():
            raise RuntimeError("Untracked final proxy exists; refusing overwrite.")
        # Only resumable scratch outputs owned by this exact clip job may be removed.
        if partial_path.exists():
            partial_path.unlink()
        for frame in sample_work.glob("frame-*.jpg"):
            frame.unlink()
        command = [str(m.BIN/"ffmpeg.exe"),"-nostdin","-hide_banner","-v","warning","-n","-i",str(source),"-map","0:v:0","-map","0:a?","-map_metadata","0","-map_metadata:s:v:0","0:s:v:0","-vf",scale_filter(args.proxy_divisor),"-c:v","prores_ks","-profile:v","0","-vendor","apl0","-pix_fmt",PIXEL_FORMAT,"-threads","2","-filter_threads","1","-fps_mode","passthrough","-c:a","pcm_s24le","-movflags","+faststart"]
        for field,option in (("color_range","-color_range"),("color_space","-colorspace"),("color_transfer","-color_trc"),("color_primaries","-color_primaries")):
            value=item["video"].get(field)
            if value and value not in ("unknown","unspecified","reserved"):
                command += [option,value]
        if item["timecode"]:
            command += ["-timecode",item["timecode"]]
        progress_path=sample_work/'ffmpeg-progress.txt'
        progress_path.unlink(missing_ok=True)
        progress.start_clip(item['relative_path'],item.get('duration'),len(results))
        command += ['-progress',str(progress_path),'-stats_period','1','-nostats',str(partial_path)]
        m.run_tool(command,sample_work/"encode.log",on_poll=lambda:progress.poll_file(progress_path))
        progress.end_proxy()
        progress.verify_stage()
        proxy=m.probe(partial_path,sample_work/"probe.log")
        m.run_tool([str(m.BIN/"ffmpeg.exe"),"-nostdin","-hide_banner","-v","error","-xerror","-i",str(partial_path),"-map","0:v:0","-map","0:a?","-threads","2","-f","null","-"],sample_work/"decode.log")
        progress.sheet_stage(len(results))
        timestamps=m.make_contact_sheet(item,contact_path,sample_work,progress=progress)
        progress.sheet_done()
        progress.verify_stage()
        result={"proxy_scale_divisor":args.proxy_divisor,"proxy_recipe":recipe,"proxy_bit_depth":BIT_DEPTH,"original":item,"proxy":proxy,"proxy_path":str(partial_path),"contact_sheet_path":str(contact_path),"contact_sheet_timestamps":timestamps,"decode_passed":True,"source_sha256":original_hash,"proxy_sha256":m.file_hash(partial_path),"contact_sheet_sha256":m.file_hash(contact_path),"source_unchanged":m.file_hash(source)==original_hash}
        if not result["source_unchanged"]:
            raise RuntimeError("Original changed during processing.")
        verify_sample(result)
        result["proxy_path"]=str(proxy_path)
        result["proxy"]["format"]["filename"]=str(proxy_path)
        # Journal validated scratch content before its atomic promotion, so restart
        # can recover either side of the rename without overwriting final media.
        write_json_atomic(state_path,result)
        partial_path.rename(proxy_path)
    verify_sample(result)
    write_json_atomic(state_path,result)
    results.append(result)
    progress.clip_done()
    print(f"PASS {index}/{len(inventory)} {item['relative_path']}",flush=True)

write_json_atomic(args.out/"media-results.json",results)
write_index(args.out, results, args.label)
with (args.out/"Files-SHA256.csv").open("w",newline="",encoding="utf-8") as handle:
    writer=csv.DictWriter(handle,fieldnames=["RelativePath","Bytes","SHA256"])
    writer.writeheader()
    for result in results:
        for field,hash_field in (("proxy_path","proxy_sha256"),("contact_sheet_path","contact_sheet_sha256")):
            path=Path(result[field])
            writer.writerow({"RelativePath":str(path.relative_to(args.out)),"Bytes":path.stat().st_size,"SHA256":result[hash_field]})
write_json_atomic(args.out/"COMPLETE.json",{"project":args.label,"snapshot_id":verification["SnapshotId"],"proxy_recipe":recipe,"proxy_scale_divisor":args.proxy_divisor,"proxy_bit_depth":BIT_DEPTH,"proxy_pixel_format":PIXEL_FORMAT,"clips":len(results),"proxy_files":len(results),"contact_sheets":len(results),"verified":True,"elapsed_seconds":round(time.time()-started)})
(args.out/'Premiere-Readme.txt').write_text(f'{args.label}\nProxy recipe: {recipe}\nProRes Proxy MOV; source width and height divided by {args.proxy_divisor}; 10-bit 4:2:2.\nSource frame rate, audio and timecode are preserved where present; no creative LUT.\nIn Premiere select the original clips, Proxy > Attach Proxies, and select the matching _Proxy.mov files in THIS delivered version.\nIf an older proxy version is attached, reattach to these replacements after delivery verification.\nKeep originals for final-quality export. Contact sheets have 12 timestamped source frames per clip.\n',encoding='utf-8')
write_json_atomic(job/"batch-status.json",{"state":"complete","completed":len(results),"total":len(inventory),"output":str(args.out)})
print(f"COMPLETE {len(results)} proxies and {len(results)} contact sheets verified.",flush=True)

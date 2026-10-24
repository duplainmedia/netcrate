# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
import json
from fractions import Fraction
from pathlib import Path
from proxy_recipe import recipe_id

ROOT = Path(r"C:\NetCrate\Workspace")
REPORT = ROOT / "outputs" / "Sample-Project-Test" / "sample-results.json"

def verify_sample(sample):
    original, proxy = sample["original"], sample["proxy"]
    ov, pv = original["video"], proxy["video"]
    assert pv["codec_name"] == "prores" and pv["profile"] == "Proxy"
    assert pv["pix_fmt"] == "yuv422p10le"
    divisor=sample.get('proxy_scale_divisor',4)
    assert sample.get('proxy_recipe',recipe_id(divisor))==recipe_id(divisor)
    assert pv["width"] * divisor == ov["width"] and pv["height"] * divisor == ov["height"]
    rate = Fraction(ov["avg_frame_rate"])
    assert Fraction(pv["avg_frame_rate"]) == rate
    assert abs(float(pv["duration"]) - original["duration"]) <= float(1 / rate) + 0.001
    if ov.get("nb_frames", "N/A") != "N/A":
        assert int(pv["nb_read_frames"]) == int(ov["nb_frames"])
    assert len(proxy["audio"]) == len(original["audio"])
    for oa, pa in zip(original["audio"], proxy["audio"]):
        assert oa["channels"] == pa["channels"]
        assert oa.get("sample_rate") == pa.get("sample_rate")
    if original["timecode"]:
        assert original["timecode"] == proxy["timecode"]
    assert sample["decode_passed"] is True
    assert Path(sample["proxy_path"]).is_file()
    assert Path(sample["contact_sheet_path"]).is_file()
    assert len(sample["contact_sheet_timestamps"]) == 12

if __name__ == "__main__":
    samples = json.loads(REPORT.read_text(encoding="utf-8"))
    assert len(samples) >= 2
    assert {s["original"]["camera"] for s in samples} == {"FX30", "Mavic 3"}
    for sample in samples:
        verify_sample(sample)
        print("PASS", sample["original"]["relative_path"])
    print("SUCCESS: all sample media checks passed. Premiere UI attachment remains a user acceptance test.")

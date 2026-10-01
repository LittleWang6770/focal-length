#!/usr/bin/env python3
"""Read-only independent ExifTool audit. Outputs are written only to --output.

python3 scripts/cross-check-focal.py /path/to/photos --output artifacts/audit-local
An optional --imageio JSON from audit-imageio.swift enables per-file comparison.
"""
import argparse
import csv
import json
import math
import os
import subprocess
from collections import Counter, defaultdict
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

EXTENSIONS = {".jpg", ".jpeg", ".png", ".heic", ".heif"}
PACKAGES = {".app", ".photoslibrary", ".photolibrary", ".bundle", ".framework", ".plugin"}


def discover(root):
    errors = []
    files = []
    for base, dirs, names in os.walk(root, followlinks=False, onerror=lambda e: errors.append(str(e))):
        dirs[:] = [d for d in dirs if not d.startswith(".") and not Path(base, d).is_symlink()
                   and Path(d).suffix.lower() not in PACKAGES]
        for name in names:
            path = Path(base, name)
            if not name.startswith(".") and path.suffix.lower() in EXTENSIONS and not path.is_symlink() and path.is_file():
                files.append(str(path))
    return sorted(files), errors


def field(record, name):
    for group in ("ExifIFD", "IFD0", "EXIF"):
        key = f"{group}:{name}"
        if key in record:
            return record[key]
    return next((v for k, v in record.items() if k.split(":")[-1] == name), None)


def positive(value):
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
        return number if math.isfinite(number) and number > 0 else None
    except (TypeError, ValueError):
        return None


def clean(value):
    return " ".join(value.replace("\0", " ").split()) if isinstance(value, str) and value.strip() else None


def canonical(record):
    lens, make = clean(field(record, "LensModel")), clean(field(record, "LensMake"))
    if lens and make and make.casefold() not in lens.casefold():
        lens = f"{make} {lens}"
    return {"path":record["SourceFile"], "lens":lens,
            "actual":positive(field(record, "FocalLength")),
            "equivalent":positive(field(record, "FocalLengthIn35mmFormat")),
            "camera":clean(field(record, "Model")),
            "taken":field(record, "DateTimeOriginal"), "subsecond":field(record, "SubSecTimeOriginal"),
            "width":field(record, "ImageWidth"), "height":field(record, "ImageHeight")}


def exact(value):
    return int(Decimal(str(value)).quantize(Decimal("1"), rounding=ROUND_HALF_UP)) if value is not None else None


def distribution(records, key):
    counts = Counter(exact(r[key]) for r in records if r[key] is not None)
    return [{"mm":mm, "count":n, "percentage":round(n / max(1, len(records)) * 100, 4)}
            for mm, n in sorted(counts.items(), key=lambda row:(-row[1], row[0]))]


def target_lens(record, needle):
    return needle.casefold() in (record["lens"] or "").replace("–", "-").casefold()


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--imageio", type=Path)
    parser.add_argument("--cached", action="store_true", help="reuse saved ExifTool metadata")
    parser.add_argument("--lens", default="FE 24-70mm F2.8 GM II")
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    args.output.mkdir(parents=True, exist_ok=True)
    files, enumeration_errors = discover(root)
    raw_path = args.output / "exiftool-records.json"
    if args.cached:
        raw = json.loads(raw_path.read_text())
        if {r["SourceFile"] for r in raw} != set(files):
            raise SystemExit("Cached manifest no longer matches folder; run without --cached.")
    else:
        raw = []
        for offset in range(0, len(files), 256):
            command = ["exiftool", "-j", "-n", "-G1", "-EXIF:LensModel", "-EXIF:LensMake",
                       "-EXIF:FocalLength", "-EXIF:FocalLengthIn35mmFormat", "-EXIF:Model",
                       "-EXIF:DateTimeOriginal", "-EXIF:SubSecTimeOriginal", "-ImageWidth", "-ImageHeight",
                       "--", *files[offset:offset + 256]]
            result = subprocess.run(command, capture_output=True, text=True, check=False)
            if result.returncode not in (0, 1):
                raise RuntimeError(result.stderr)
            if result.stderr:
                with (args.output / "exiftool-warnings.log").open("a") as log:
                    log.write(result.stderr)
            raw.extend(json.loads(result.stdout))
            print(f"ExifTool: {min(offset + 256, len(files))}/{len(files)}", flush=True)
        write_json(raw_path, raw)
    records = [canonical(r) for r in raw if not any(k.split(":")[-1] == "Error" for k in r)]
    selected = [r for r in records if target_lens(r, args.lens)]
    at24 = [r for r in selected if exact(r["equivalent"]) == 24]
    by_dir = defaultdict(list)
    for r in selected:
        relative = Path(r["path"]).relative_to(root)
        by_dir[str(relative.parent)].append(r)
    directory_rows = []
    for name, rows in by_dir.items():
        count24 = sum(exact(r["equivalent"]) == 24 for r in rows)
        directory_rows.append({"folder":name, "lens_photos":len(rows), "at_24mm":count24,
                               "percentage":round(100 * count24 / len(rows), 2)})
    directory_rows.sort(key=lambda r:(-r["at_24mm"], r["folder"]))
    # Same timestamp/lens/focal is evidence for candidate repeats, NOT proof of identical photos.
    shot_groups = defaultdict(list)
    for r in selected:
        if r["taken"]:
            shot_groups[(r["camera"],r["taken"],r["subsecond"],r["actual"],r["equivalent"])].append(r["path"])
    repeated = [paths for paths in shot_groups.values() if len(paths) > 1]
    summary = {"root":str(root), "discovered":len(files), "exiftool_readable":len(records),
               "enumeration_errors":enumeration_errors,
               "lenses":dict(Counter(r["lens"] for r in records).most_common()),
               "selected_lens":args.lens, "selected_count":len(selected),
               "equivalent_distribution":distribution(selected,"equivalent"),
               "actual_distribution":distribution(selected,"actual"),
               "equivalent_24_count":len(at24),
               "actual_values_among_equivalent_24":dict(Counter(str(r["actual"]) for r in at24)),
               "physical_vs_equivalent_differences":sum(r["actual"] != r["equivalent"] for r in selected),
               "subfolders":directory_rows, "candidate_repeated_capture_groups":len(repeated),
               "candidate_repeated_capture_files":sum(map(len,repeated)),
               "cameras":dict(Counter(r["camera"] for r in selected))}
    if args.imageio:
        imageio = json.loads(args.imageio.read_text())
        app = {r["path"]:r for r in imageio["records"]}
        other = {r["path"]:r for r in records}
        differences = []
        for path in sorted(app.keys() & other.keys()):
            changed = {k:{"imageio":app[path][k], "exiftool":other[path][k]}
                       for k in ("lens","actual","equivalent") if app[path][k] != other[path][k]}
            if changed:
                differences.append({"path":path, "fields":changed})
        summary["comparison"] = {"imageio_count":len(app), "imageio_failed":imageio["failed"],
            "only_imageio":sorted(app.keys()-other.keys()), "only_exiftool":sorted(other.keys()-app.keys()),
            "different_files":len(differences)}
        write_json(args.output / "differences.json", differences)
    write_json(args.output / "summary.json", summary)
    write_json(args.output / "candidate-repeats.json", repeated)
    with (args.output / "24mm-files.csv").open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["path","lens","actual","equivalent","camera","taken","subsecond","width","height"])
        writer.writeheader(); writer.writerows(at24)
    print(json.dumps({k:summary[k] for k in ("discovered","exiftool_readable","selected_count","equivalent_24_count","physical_vs_equivalent_differences")},ensure_ascii=False))
    print("Top focal lengths:", summary["equivalent_distribution"][:5])
    if "comparison" in summary:
        print("Comparison:",summary["comparison"])


if __name__ == "__main__":
    main()

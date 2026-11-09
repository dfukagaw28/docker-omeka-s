#!/usr/bin/env python3
"""Summarize an image collection without revealing file or directory names.

    python3 scripts/survey-images.py <root-dir> [--sample N] [--patterns] [--psd]

Prints only counts and shapes, so the output can be shared even when the
collection itself is confidential:

  - files per extension, directory depth, files per directory
  - how files with the same base name are duplicated across formats
  - image size / bands / pixel format / compression / tiling (vipsheader,
    on a random sample of N files per extension; default 200)
  - with --patterns: file and directory name *shapes*, where every digit
    becomes 9, every ASCII letter a, every other character (e.g. Japanese) x;
    separators such as _ - . are kept. Check the output before sharing it.
  - with --psd: PSD layer counts, group depth, layer kinds and sizes (needs
    psd-tools: uv run --with psd-tools python3 scripts/survey-images.py ...)

Nothing is written; files are only read (headers, and whole PSDs with --psd).
Progress is shown on stderr (with tqdm if installed: uv run --with tqdm ...).
"""
import argparse
import collections
import os
import random
import re
import subprocess
import sys
import time

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".tga", ".psd", ".pdf"}


def progress(iterable, desc: str, total=None, unit: str = "file"):
    """Progress on stderr: tqdm when installed, otherwise a simple counter.

    stdout stays clean, so `... > survey.txt` still shows the progress.
    """
    try:
        from tqdm import tqdm
    except ImportError:
        tqdm = None
    if tqdm:
        yield from tqdm(iterable, desc=desc, total=total, unit=unit, file=sys.stderr,
                        dynamic_ncols=True, mininterval=0.5)
        return
    start = last = time.monotonic()
    n = 0

    def show(end=""):
        elapsed = time.monotonic() - start
        of = f"/{total}" if total else ""
        rate = n / elapsed if elapsed > 0 else 0
        eta = f", ETA {int((total - n) / rate)}s" if total and rate else ""
        print(f"\r{desc}: {n}{of} {unit}s ({int(elapsed)}s{eta})   ", end=end, file=sys.stderr, flush=True)

    for item in iterable:
        yield item
        n += 1
        now = time.monotonic()
        if now - last >= 1:
            last = now
            show()
    show("\n")


def shape(name: str) -> str:
    out = []
    for ch in name:
        if ch.isdigit():
            out.append("9")
        elif ch.isascii() and ch.isalpha():
            out.append("a")
        elif ch in "_-. ()[]+#@":
            out.append(ch)
        else:
            out.append("x")
    # collapse runs: 9999 -> 9{4}
    return re.sub(r"(.)\1{2,}", lambda m: f"{m.group(1)}{{{len(m.group(0))}}}", "".join(out))


def hist(counter, title, limit=30, total=None):
    print(f"\n## {title}")
    total = total or sum(counter.values())
    for key, n in counter.most_common(limit):
        print(f"  {n:>8}  {100 * n / total:5.1f}%  {key}")
    if len(counter) > limit:
        print(f"  ... {len(counter) - limit} more")


def bucket(n: int) -> str:
    for edge in (1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 5000):
        if n <= edge:
            return f"<={edge}"
    return ">5000"


def px_bucket(w: int, h: int) -> str:
    m = max(w, h)
    for edge in (1000, 2000, 3000, 4000, 5000, 7000, 10000, 15000, 20000):
        if m <= edge:
            return f"long side <={edge}"
    return "long side >20000"


def vipsheader(path: str) -> dict:
    try:
        out = subprocess.run(["vipsheader", "-a", path], capture_output=True,
                             text=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    info = {}
    for line in out.splitlines():
        key, _, value = line.partition(":")
        info[key.strip()] = value.strip()
    return info


TIFF_COMPRESSION = {1: "none", 5: "lzw", 7: "jpeg", 8: "deflate", 32773: "packbits",
                    32946: "deflate", 34887: "lerc", 50000: "zstd", 50001: "webp"}


def tiff_compression(path: str) -> str:
    """Compression of the first IFD, read from the TIFF tags (vips omits it)."""
    import struct
    try:
        with open(path, "rb") as f:
            head = f.read(16)
            bo = {b"II": "<", b"MM": ">"}.get(head[:2])
            if not bo:
                return "?"
            magic = struct.unpack(bo + "H", head[2:4])[0]
            if magic == 42:
                f.seek(struct.unpack(bo + "I", head[4:8])[0])
                (n,) = struct.unpack(bo + "H", f.read(2))
                entries = [f.read(12) for _ in range(n)]
                fmt = bo + "HHI4s"
            elif magic == 43:  # BigTIFF
                f.seek(struct.unpack(bo + "Q", head[8:16])[0])
                (n,) = struct.unpack(bo + "Q", f.read(8))
                entries = [f.read(20) for _ in range(n)]
                fmt = bo + "HHQ8s"
            else:
                return "?"
        for e in entries:
            tag, typ, _, val = struct.unpack(fmt, e)
            if tag == 259:
                code = struct.unpack(bo + ("H" if typ == 3 else "I"), val[:2 if typ == 3 else 4])[0]
                return TIFF_COMPRESSION.get(code, str(code))
        return "none"
    except (OSError, struct.error):
        return "?"


def survey(root: str, sample: int, patterns: bool, psd: bool) -> None:
    root = os.path.abspath(root)
    files_by_ext = collections.defaultdict(list)
    size_by_ext = collections.Counter()
    depth = collections.Counter()
    per_dir = collections.Counter()
    dir_depth = collections.Counter()
    ext_sets = collections.Counter()
    file_shapes = collections.Counter()
    dir_shapes = collections.defaultdict(collections.Counter)
    others = collections.Counter()

    for dirpath, dirnames, filenames in progress(os.walk(root), "Scanning", unit="dir"):
        dirnames.sort()
        rel = os.path.relpath(dirpath, root)
        d = 0 if rel == "." else rel.count(os.sep) + 1
        dir_depth[d] += 1
        if patterns and d > 0:
            dir_shapes[d][shape(os.path.basename(dirpath))] += 1
        by_base = collections.defaultdict(set)
        n_images = 0
        for name in filenames:
            base, ext = os.path.splitext(name)
            ext = ext.lower()
            if ext not in IMAGE_EXTS:
                others[ext or "(none)"] += 1
                continue
            path = os.path.join(dirpath, name)
            try:
                size_by_ext[ext] += os.path.getsize(path)
            except OSError:
                continue
            files_by_ext[ext].append(path)
            depth[d] += 1
            n_images += 1
            by_base[base].add(ext)
            if patterns:
                file_shapes[shape(base) + ext] += 1
        if n_images:
            per_dir[bucket(n_images)] += 1
        for exts in by_base.values():
            ext_sets[" + ".join(sorted(exts))] += 1

    total = sum(len(v) for v in files_by_ext.values())
    print(f"# Survey: {total} image files")
    print("\n## Files per extension (count, total GB, mean MB)")
    for ext, paths in sorted(files_by_ext.items(), key=lambda kv: -len(kv[1])):
        gb = size_by_ext[ext] / 1e9
        print(f"  {ext:6} {len(paths):>8}  {gb:9.1f} GB  {size_by_ext[ext] / len(paths) / 1e6:8.1f} MB")
    if others:
        hist(others, "Other files (by extension)", limit=15)
    hist(collections.Counter({f"depth {k}": v for k, v in sorted(depth.items())}),
         "Image files by directory depth (0 = root)")
    hist(collections.Counter({f"depth {k}": v for k, v in sorted(dir_depth.items())}),
         "Directories by depth")
    hist(per_dir, "Directories by number of image files")
    hist(ext_sets, "Same base name in the same directory: format combinations")

    rng = random.Random(0)
    print(f"\n## Image properties (vipsheader, sample of up to {sample} per extension)")
    for ext, paths in sorted(files_by_ext.items()):
        if ext == ".pdf":
            continue
        picked = paths if len(paths) <= sample else rng.sample(paths, sample)
        dims, kinds, comp, dpi = (collections.Counter() for _ in range(4))
        failed = 0
        for p in progress(picked, f"Reading {ext}", total=len(picked)):
            info = vipsheader(p)
            try:
                w, h = int(info["width"]), int(info["height"])
            except (KeyError, ValueError):
                failed += 1
                continue
            dims[px_bucket(w, h)] += 1
            kinds[f"{info.get('bands', '?')} bands, {info.get('format', '?')}, "
                  f"{info.get('interpretation', '?')}, pages={info.get('n-pages', '1')}"] += 1
            try:  # vips reports pixels per mm
                dpi[f"{round(float(info['xres']) * 25.4)} dpi"] += 1
            except (KeyError, ValueError):
                pass
            if ext in (".tif", ".tiff"):
                tiled = "tiled" if "tile-width" in info else "strips"
                comp[f"{tiff_compression(p)}, {tiled}"] += 1
        print(f"\n### {ext}: {len(picked)} sampled, {failed} unreadable by vips")
        for title, c in (("size", dims), ("pixels", kinds), ("dpi", dpi), ("tiff", comp)):
            for key, n in c.most_common(10):
                print(f"  {title:6} {n:>6}  {key}")

    if patterns:
        hist(file_shapes, "File name shapes (9 digit, a letter, x other)", limit=40)
        for d in sorted(dir_shapes):
            hist(dir_shapes[d], f"Directory name shapes at depth {d}", limit=20)

    if psd and files_by_ext.get(".psd"):
        survey_psd(files_by_ext[".psd"], sample, rng)


def survey_psd(paths, sample, rng) -> None:
    try:
        from psd_tools import PSDImage
    except ImportError:
        print("\n(psd-tools not installed; skipped PSD survey)", file=sys.stderr)
        return
    picked = paths if len(paths) <= sample else rng.sample(paths, sample)
    n_layers, depth, kinds, modes, blend = (collections.Counter() for _ in range(5))
    coverage = collections.Counter()
    failed = 0
    for p in progress(picked, "Reading .psd", total=len(picked)):
        try:
            psd = PSDImage.open(p)
        except Exception:
            failed += 1
            continue
        modes[f"{psd.color_mode.name}, {psd.depth}bit, {psd.channels}ch"] += 1
        count, maxdepth = 0, 0

        def walk(group, d):
            nonlocal count, maxdepth
            for layer in group:
                maxdepth = max(maxdepth, d)
                if layer.is_group():
                    kinds["group"] += 1
                    walk(layer, d + 1)
                    continue
                count += 1
                kinds[layer.kind] += 1
                blend[str(layer.blend_mode).split(".")[-1]] += 1
                area = max(layer.width * layer.height, 0)
                full = max(psd.width * psd.height, 1)
                coverage[f"{min(100, (100 * area // full) // 10 * 10)}%+ of canvas"] += 1

        walk(psd, 0)
        n_layers[bucket(count)] += 1
        depth[f"group depth {maxdepth}"] += 1
    print(f"\n## PSD ({len(picked)} sampled, {failed} unreadable)")
    for title, c in (("mode", modes), ("layers per file", n_layers), ("nesting", depth),
                     ("layer kind", kinds), ("blend mode", blend), ("layer area", coverage)):
        hist(c, f"PSD {title}", limit=15)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("root")
    ap.add_argument("--sample", type=int, default=200)
    ap.add_argument("--patterns", action="store_true")
    ap.add_argument("--psd", action="store_true")
    args = ap.parse_args()
    survey(args.root, args.sample, args.patterns, args.psd)


if __name__ == "__main__":
    main()

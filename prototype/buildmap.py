#!/usr/bin/env python3
"""
Turn raw embeddings into the data the music map needs.

Also the working prototype of R9 (metadata) and R12 (search folding):
  - read embedded tags first, via ffprobe
  - fall back to parsing the filename when tags are missing
  - canonicalise artist names so one artist collapses to one entity
  - build a script-aware folded search key that does not corrupt Japanese
"""
import json
import re
import subprocess
import sys
import unicodedata as ud
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent

# ------------------------------------------------------- search folding ----
KANA_VOICING = {0x3099, 0x309A}          # dakuten / handakuten: NOT accents
LATIN_MARKS = range(0x0300, 0x0370)      # combining diacriticals


def fold(s: str) -> str:
    """Mirror of the Swift `searchKey`. Strips Latin accents, keeps kana voicing."""
    d = ud.normalize("NFKD", s)
    kept = [c for c in d
            if ord(c) in KANA_VOICING or ord(c) not in LATIN_MARKS]
    return ud.normalize("NFKC", "".join(kept)).casefold().strip()


# ------------------------------------------------------------ metadata ----
TRACK_PREFIX = re.compile(r"^\s*(\d{1,3})\s*[-._)]\s*")   # "02 - ", "13. "
TRACK_BARE = re.compile(r"^\s*(\d{1,3})\s+")              # "06 Title"
FEAT = re.compile(r"\s*[\(\[]?\s*(?:feat\.?|ft\.?|featuring|with)\s+([^\)\]]+)[\)\]]?\s*",
                  re.IGNORECASE)
MULTI_ARTIST = re.compile(r"\s+(?:&|and|e|y|x|vs\.?|,)\s+", re.IGNORECASE)


def probe_tags(path):
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", str(path)],
            capture_output=True, text=True, timeout=30)
        fmt = json.loads(r.stdout).get("format", {})
        return {k.lower(): v for k, v in (fmt.get("tags") or {}).items()}
    except Exception:
        return {}


def parse_filename(stem):
    """
    Handles the shapes actually present in this library:
      Artist - Album - NN Track
      NN - Track
      NN. Track
      Bare title
    """
    parts = [p.strip() for p in stem.split(" - ")]
    if len(parts) >= 3:
        artist, album, last = parts[0], parts[1], " - ".join(parts[2:])
        m = TRACK_BARE.match(last)
        if m:
            return artist, album, TRACK_BARE.sub("", last), int(m.group(1))
        return artist, album, last, None
    if len(parts) == 2 and not parts[0].isdigit():
        return parts[0], None, parts[1], None

    m = TRACK_PREFIX.match(stem)
    if m:
        return None, None, TRACK_PREFIX.sub("", stem), int(m.group(1))
    return None, None, stem, None


def canonical_artist(name):
    """Collapse spelling variants to one key. Display keeps the original."""
    if not name:
        return None
    n = FEAT.sub(" ", name)
    n = fold(n)
    n = re.sub(r"^(the)\s+", "", n)
    n = re.sub(r"[^\w\s]", " ", n, flags=re.UNICODE)
    return re.sub(r"\s+", " ", n).strip()


def metadata_for(path):
    p = Path(path)
    tags = probe_tags(p)
    f_artist, f_album, f_title, f_track = parse_filename(p.stem)

    title = (tags.get("title") or "").strip() or f_title or p.stem
    artist = ((tags.get("artist") or tags.get("album_artist") or "").strip()
              or f_artist or "Unknown Artist")
    album = (tags.get("album") or "").strip() or f_album or "Unknown Album"

    feat = FEAT.search(title)
    featured = feat.group(1).strip() if feat else None

    return {
        "title": title,
        "artist": artist,
        "album": album,
        "artistKey": canonical_artist(artist),
        "featured": featured,
        "artists": [a.strip() for a in MULTI_ARTIST.split(artist) if a.strip()],
        "source": "tags" if tags.get("title") else "filename",
        "search": fold(f"{title} {artist} {album}"),
    }


# ---------------------------------------------------------------- main ----
def main():
    src = ROOT / "embeddings.jsonl"
    rows = []
    for line in src.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            pass                      # tolerate a half-written final line
    if not rows:
        sys.exit("no embeddings")

    print(f"building map for {len(rows)} tracks...")
    X = np.array([r["embedding"] for r in rows], dtype=np.float64)
    X /= np.linalg.norm(X, axis=1, keepdims=True) + 1e-9

    # 2D projection: PCA via SVD. Ports to Accelerate on device.
    Xc = X - X.mean(axis=0)
    U, S, Vt = np.linalg.svd(Xc, full_matrices=False)
    coords = U[:, :2] * S[:2]
    coords /= np.abs(coords).max() + 1e-9          # normalise to [-1, 1]
    var = (S ** 2) / (S ** 2).sum()

    # neighbours for radio
    SIM = X @ X.T
    np.fill_diagonal(SIM, -2.0)
    K = min(12, len(rows) - 1)
    nbrs = np.argsort(-SIM, axis=1)[:, :K]

    tracks = []
    for i, r in enumerate(rows):
        md = metadata_for(r["path"])
        tracks.append({
            "i": i,
            **md,
            "seconds": r.get("seconds"),
            "x": round(float(coords[i, 0]), 4),
            "y": round(float(coords[i, 1]), 4),
            "nbr": [int(j) for j in nbrs[i]],
            "sim": [round(float(SIM[i, j]), 3) for j in nbrs[i]],
        })
        if (i + 1) % 50 == 0:
            print(f"  metadata {i+1}/{len(rows)}")

    artists = {}
    for t in tracks:
        artists.setdefault(t["artistKey"], []).append(t["artist"])

    out = {
        "tracks": tracks,
        "variance": [round(float(var[0]), 4), round(float(var[1]), 4)],
        "artistCount": len(artists),
    }
    (ROOT / "mapdata.json").write_text(json.dumps(out))
    tagged = sum(1 for t in tracks if t["source"] == "tags")
    print(f"\n{len(tracks)} tracks, {len(artists)} canonical artists")
    print(f"metadata from tags: {tagged}  from filename: {len(tracks)-tagged}")
    print(f"PC1 {var[0]:.1%}  PC2 {var[1]:.1%}")
    print(f"wrote {ROOT/'mapdata.json'}")


if __name__ == "__main__":
    main()

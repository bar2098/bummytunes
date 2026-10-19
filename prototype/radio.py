#!/usr/bin/env python3
"""
BummyTunes radio prototype.

Reads embeddings.json and answers the two questions the app has to answer:

  radio.py similar "<seed>"   -> nearest neighbours by cosine (the "start radio
                                 from this track" feature)
  radio.py map                -> 2D projection of the library (the music map),
                                 via PCA, which is the piece that ports to
                                 Accelerate on device without a UMAP dependency

Both operate on unit-norm 200-d MusiCNN vectors, so cosine == dot product.
"""
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
DB = ROOT / "embeddings.json"


def load():
    rows = json.loads(DB.read_text())
    if not rows:
        sys.exit("no embeddings yet; run embed.py first")
    names = [r["name"] for r in rows]
    X = np.array([r["embedding"] for r in rows], dtype=np.float64)
    X /= np.linalg.norm(X, axis=1, keepdims=True) + 1e-9
    return names, X


def similar(seed, k=8):
    names, X = load()
    matches = [i for i, n in enumerate(names) if seed.lower() in n.lower()]
    if not matches:
        sys.exit(f"no track matching {seed!r}\navailable:\n  " + "\n  ".join(names))
    i = matches[0]
    sims = X @ X[i]
    order = np.argsort(-sims)

    print(f"\nRADIO seeded on: {names[i]}\n" + "-" * 66)
    shown = 0
    for j in order:
        if j == i:
            continue
        print(f"  {sims[j]:+.4f}  {names[j]}")
        shown += 1
        if shown >= k:
            break


def music_map():
    names, X = load()
    Xc = X - X.mean(axis=0)
    # PCA via SVD; top 2 components are the map axes.
    U, S, Vt = np.linalg.svd(Xc, full_matrices=False)
    coords = U[:, :2] * S[:2]
    var = (S ** 2) / (S ** 2).sum()

    print(f"\nMUSIC MAP  ({len(names)} tracks)")
    print(f"variance explained: PC1 {var[0]:.1%}  PC2 {var[1]:.1%}\n" + "-" * 66)
    for n, (x, y) in sorted(zip(names, coords), key=lambda t: t[1][0]):
        print(f"  x={x:+7.3f}  y={y:+7.3f}   {n}")


def spread():
    """Sanity check: are these vectors actually discriminating, or all alike?"""
    names, X = load()
    S = X @ X.T
    off = S[~np.eye(len(names), dtype=bool)]
    print(f"\nEMBEDDING SPREAD over {len(names)} tracks")
    print("-" * 66)
    print(f"  mean pairwise cosine : {off.mean():+.4f}")
    print(f"  min  / max           : {off.min():+.4f} / {off.max():+.4f}")
    print(f"  std                  : {off.std():.4f}")
    if off.std() < 0.02:
        print("\n  WARNING: vectors are nearly identical, embedding likely broken")
    else:
        print("\n  OK: vectors discriminate between tracks")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "spread"
    if cmd == "similar":
        similar(sys.argv[2] if len(sys.argv) > 2 else "")
    elif cmd == "map":
        music_map()
    else:
        spread()

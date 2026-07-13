#!/usr/bin/env python3
"""Step 06 — Test-set evaluation + open-set threshold calibration.

Produces eval_report.md next to the checkpoint with:
  - top-1 / top-5 / balanced accuracy on the held-out test split
  - the worst-recognized classes and most-confused pairs
  - a rejection-threshold sweep using val (in-distribution) vs OOD images,
    with a recommended confidence threshold for the app's "не распознано".

Usage:
    .venv/bin/python 06_evaluate.py --checkpoint work/runs/v1/best.pt
"""
from __future__ import annotations

import argparse
import csv
from collections import Counter, defaultdict
from pathlib import Path

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from common import SPLITS_DIR
from icon_dataset import IconDataset
from icon_model import load_checkpoint, pick_device


def read_split(path: Path) -> list[tuple[str, int]]:
    if not path.exists():
        return []
    with open(path, newline="", encoding="utf-8") as f:
        return [(r["relpath"], int(r["label"])) for r in csv.DictReader(f)]


@torch.no_grad()
def predict(model, rows, img_size, device, batch_size, workers):
    """Returns (labels, preds, maxprobs) tensors."""
    ds = IconDataset(rows, img_size, train=False)
    loader = DataLoader(ds, batch_size=batch_size, num_workers=workers)
    all_labels, all_preds, all_maxp = [], [], []
    for x, y in loader:
        logits, _ = model(x.to(device))
        probs = F.softmax(logits, dim=1).cpu()
        maxp, pred = probs.max(dim=1)
        all_labels += [int(v) for v in y]
        all_preds += [int(v) for v in pred]
        all_maxp += [float(v) for v in maxp]
    return all_labels, all_preds, all_maxp


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--target-precision", type=float, default=0.95)
    args = parser.parse_args()

    device = pick_device(args.device)
    model, ckpt = load_checkpoint(Path(args.checkpoint), device)
    cfg = ckpt["config"]
    labels_meta = {c["index"]: c for c in cfg["labels"]}
    img_size = cfg["img_size"]
    print(f"Model: {cfg['model_name']}  classes={cfg['num_classes']}  device={device}")

    test_rows = read_split(SPLITS_DIR / "test.csv")
    val_rows = read_split(SPLITS_DIR / "val.csv")
    ood_rows = read_split(SPLITS_DIR / "ood.csv")

    y, pred, maxp = predict(model, test_rows, img_size, device,
                            args.batch_size, args.workers)

    # Overall metrics (recompute top5 needs probs; do a cheap second pass for top5)
    n = len(y)
    top1 = sum(int(a == b) for a, b in zip(y, pred)) / max(1, n)
    per_total, per_correct = Counter(), Counter()
    confusion = Counter()
    for yy, pp in zip(y, pred):
        per_total[yy] += 1
        if yy == pp:
            per_correct[yy] += 1
        else:
            confusion[(yy, pp)] += 1
    bal = sum(per_correct[c] / per_total[c] for c in per_total) / max(1, len(per_total))

    lines = [f"# Icon classifier evaluation — {Path(args.checkpoint).parent.name}", ""]
    lines += [f"- checkpoint: `{args.checkpoint}` (epoch {ckpt['epoch']})",
              f"- test images: {n}, classes: {cfg['num_classes']}",
              f"- **top-1: {top1:.4f}**, balanced accuracy: {bal:.4f}", ""]

    worst = sorted(per_total, key=lambda c: per_correct[c] / per_total[c])[:25]
    lines += ["## Worst classes (test recall)", "",
              "| recall | n | class |", "|---|---|---|"]
    for c in worst:
        m = labels_meta[c]
        lines.append(f"| {per_correct[c] / per_total[c]:.2f} | {per_total[c]} "
                     f"| {m['name']} ({m['category']}, id {m['icon_id']}) |")

    lines += ["", "## Most confused pairs", "", "| n | true → predicted |", "|---|---|"]
    for (a, b), cnt in confusion.most_common(15):
        lines.append(f"| {cnt} | {labels_meta[a]['name']} → {labels_meta[b]['name']} |")

    # Open-set threshold sweep: val = in-distribution, ood = should be rejected.
    if val_rows and ood_rows:
        vy, vpred, vmaxp = predict(model, val_rows, img_size, device,
                                   args.batch_size, args.workers)
        _, _, omaxp = predict(model, ood_rows, img_size, device,
                              args.batch_size, args.workers)
        lines += ["", "## Rejection threshold sweep (val vs OOD)", "",
                  "| τ | val coverage | acc on accepted | OOD falsely accepted |",
                  "|---|---|---|---|"]
        recommended = None
        for t10 in range(30, 96, 5):
            tau = t10 / 100
            acc_idx = [i for i, p in enumerate(vmaxp) if p >= tau]
            cov = len(acc_idx) / max(1, len(vmaxp))
            acc = (sum(int(vy[i] == vpred[i]) for i in acc_idx) / len(acc_idx)
                   if acc_idx else 0.0)
            ood_acc = sum(1 for p in omaxp if p >= tau) / max(1, len(omaxp))
            lines.append(f"| {tau:.2f} | {cov:.3f} | {acc:.3f} | {ood_acc:.3f} |")
            if recommended is None and acc >= args.target_precision and ood_acc <= 0.05:
                recommended = tau
        lines += ["", f"**Recommended threshold: τ = "
                  f"{recommended if recommended is not None else 'none met targets — inspect table'}** "
                  f"(targets: accepted-accuracy ≥ {args.target_precision}, OOD accept ≤ 5%)"]
        print(f"Recommended rejection threshold: {recommended}")

    report = Path(args.checkpoint).parent / "eval_report.md"
    report.write_text("\n".join(lines), encoding="utf-8")
    print(f"top1={top1:.4f} bal={bal:.4f} on {n} test images")
    print(f"Report: {report}")


if __name__ == "__main__":
    main()

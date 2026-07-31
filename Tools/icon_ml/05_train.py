#!/usr/bin/env python3
"""Step 05 — Fine-tune the icon classifier on Apple Silicon (MPS).

Two phases:
  A. --freeze-epochs (default 2): backbone frozen, train embedding+head only.
  B. Full fine-tune with cosine LR decay and short warmup.

Typical full run on an M-series Pro (430 classes, ~13k train images, 256px):
    .venv/bin/python 05_train.py --run-name v1
Expect roughly 1–2 minutes/epoch on MPS; 30 epochs ≈ under an hour.
Resume after interruption:
    .venv/bin/python 05_train.py --run-name v1 --resume work/runs/v1/last.pt

Smoke test (validates the whole loop in ~1 minute, CPU):
    .venv/bin/python 05_train.py --run-name smoke --device cpu --epochs 2 \
        --limit-per-class 10 --batch-size 8 --workers 2 --freeze-epochs 1
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import time
from collections import Counter, defaultdict
from pathlib import Path

import torch
import torch.nn as nn
from torch.utils.data import DataLoader, WeightedRandomSampler

from common import LABELS_JSON, RUNS_DIR, SPLITS_DIR
from icon_dataset import IconDataset
from icon_model import IconNet, pick_device, save_checkpoint


def read_split(path: Path) -> list[tuple[str, int]]:
    with open(path, newline="", encoding="utf-8") as f:
        return [(r["relpath"], int(r["label"])) for r in csv.DictReader(f)]


def lr_at(step: int, total: int, base: float, warmup: int) -> float:
    if step < warmup:
        return base * (step + 1) / warmup
    p = (step - warmup) / max(1, total - warmup)
    return base * (0.01 + 0.99 * 0.5 * (1 + math.cos(math.pi * p)))


def apply_mix(x, y, mixup_alpha, cutmix_alpha, prob):
    """Returns (x, y_a, y_b, lam); lam == 1.0 means no mixing."""
    if prob <= 0 or torch.rand(1).item() > prob:
        return x, y, y, 1.0
    use_cutmix = cutmix_alpha > 0 and (mixup_alpha <= 0 or torch.rand(1).item() < 0.5)
    alpha = cutmix_alpha if use_cutmix else mixup_alpha
    if alpha <= 0:
        return x, y, y, 1.0
    lam = float(torch.distributions.Beta(alpha, alpha).sample())
    idx = torch.randperm(x.size(0), device=x.device)
    if use_cutmix:
        _, _, h, w = x.shape
        r = math.sqrt(1.0 - lam)
        ch, cw = int(h * r), int(w * r)
        cy, cx = int(torch.randint(h, (1,))), int(torch.randint(w, (1,)))
        y1, y2 = max(cy - ch // 2, 0), min(cy + ch // 2, h)
        x1, x2 = max(cx - cw // 2, 0), min(cx + cw // 2, w)
        x[:, :, y1:y2, x1:x2] = x[idx, :, y1:y2, x1:x2]
        lam = 1.0 - ((y2 - y1) * (x2 - x1) / (h * w))
    else:
        x = lam * x + (1.0 - lam) * x[idx]
    return x, y, y[idx], lam


@torch.no_grad()
def evaluate(model, loader, device, num_classes) -> dict:
    model.eval()
    top1 = top5 = n = 0
    per_class_correct = Counter()
    per_class_total = Counter()
    k = min(5, num_classes)
    for x, y in loader:
        x = x.to(device)
        logits, _ = model(x)
        logits = logits.cpu()
        pred_topk = logits.topk(k, dim=1).indices
        for i in range(len(y)):
            label = int(y[i])
            per_class_total[label] += 1
            if int(pred_topk[i, 0]) == label:
                top1 += 1
                per_class_correct[label] += 1
            if label in pred_topk[i].tolist():
                top5 += 1
            n += 1
    bal = (sum(per_class_correct[c] / per_class_total[c] for c in per_class_total)
           / max(1, len(per_class_total)))
    return {"top1": top1 / max(1, n), "top5": top5 / max(1, n), "bal_acc": bal, "n": n}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="convnext_tiny.fb_in22k_ft_in1k")
    parser.add_argument("--img-size", type=int, default=256)
    parser.add_argument("--batch-size", type=int, default=48)
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--freeze-epochs", type=int, default=2)
    parser.add_argument("--lr", type=float, default=1e-4)
    parser.add_argument("--head-lr", type=float, default=1e-3)
    parser.add_argument("--weight-decay", type=float, default=0.05)
    parser.add_argument("--label-smoothing", type=float, default=0.1)
    parser.add_argument("--embed-dim", type=int, default=512)
    parser.add_argument("--scale", type=float, default=30.0)
    parser.add_argument("--mixup", type=float, default=0.0, help="mixup alpha (0=off)")
    parser.add_argument("--cutmix", type=float, default=0.0, help="cutmix alpha (0=off)")
    parser.add_argument("--mix-prob", type=float, default=0.0, help="per-batch probability of mixing")
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--device", default="auto", choices=["auto", "mps", "cuda", "cpu"])
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--patience", type=int, default=10,
                        help="early stop after N epochs without val top1 improvement (0=off)")
    parser.add_argument("--run-name", default=time.strftime("run_%Y%m%d_%H%M"))
    parser.add_argument("--resume", default="")
    parser.add_argument("--amp", action="store_true", help="mixed precision (experimental on MPS)")
    parser.add_argument("--limit-per-class", type=int, default=0, help="debug/smoke")
    args = parser.parse_args()

    torch.manual_seed(args.seed)
    device = pick_device(args.device)
    print(f"Device: {device}")

    train_rows = read_split(SPLITS_DIR / "train.csv")
    val_rows = read_split(SPLITS_DIR / "val.csv")
    with open(LABELS_JSON, encoding="utf-8") as f:
        labels_doc = json.load(f)
    num_classes = labels_doc["num_classes"]

    if args.limit_per_class:
        by_class = defaultdict(list)
        for row in train_rows:
            if len(by_class[row[1]]) < args.limit_per_class:
                by_class[row[1]].append(row)
        train_rows = [r for rows in by_class.values() for r in rows]

    print(f"train={len(train_rows)}  val={len(val_rows)}  classes={num_classes}")

    counts = Counter(label for _, label in train_rows)
    sample_weights = [(1.0 / counts[label]) ** 0.5 for _, label in train_rows]
    sampler = WeightedRandomSampler(sample_weights, num_samples=len(train_rows),
                                    replacement=True)

    train_ds = IconDataset(train_rows, args.img_size, train=True)
    val_ds = IconDataset(val_rows, args.img_size, train=False)
    train_loader = DataLoader(train_ds, batch_size=args.batch_size, sampler=sampler,
                              num_workers=args.workers, persistent_workers=False,
                              drop_last=len(train_rows) > args.batch_size)
    val_loader = DataLoader(val_ds, batch_size=max(32, args.batch_size),
                            num_workers=max(2, args.workers // 2))

    model = IconNet(args.model, num_classes, args.embed_dim, args.scale, pretrained=True)
    model.to(device)
    if device == "mps":
        # MPS (torch 2.5.1): convolution_backward падает с "view size is not
        # compatible" когда grad_output неконтигуален (permute после conv_dw
        # в блоках ConvNeXt). Хук делает градиент контигуальным до conv-backward.
        def _contig_grad_hook(mod, inp, out):
            if isinstance(out, torch.Tensor) and out.requires_grad:
                out.register_hook(lambda g: g.contiguous())
        for m in model.modules():
            if isinstance(m, nn.Conv2d):
                m.register_forward_hook(_contig_grad_hook)
    n_params = sum(p.numel() for p in model.parameters()) / 1e6
    print(f"Model {args.model}: {n_params:.1f}M params, embed_dim={args.embed_dim}")

    config = {
        "model_name": args.model, "img_size": args.img_size,
        "num_classes": num_classes, "embed_dim": args.embed_dim, "scale": args.scale,
        "labels": labels_doc["classes"],
    }
    criterion = nn.CrossEntropyLoss(label_smoothing=args.label_smoothing)

    run_dir = RUNS_DIR / args.run_name
    run_dir.mkdir(parents=True, exist_ok=True)
    log_path = run_dir / "log.csv"
    if not log_path.exists():
        with open(log_path, "w", newline="") as f:
            csv.writer(f).writerow(
                ["epoch", "phase", "loss", "val_top1", "val_top5", "val_bal_acc", "lr", "sec"])
    with open(run_dir / "config.json", "w", encoding="utf-8") as f:
        json.dump({**config, "labels": f"{num_classes} classes (see labels in checkpoint)",
                   "args": vars(args)}, f, ensure_ascii=False, indent=1)

    start_epoch, best_top1 = 0, 0.0
    optimizer = None
    if args.resume:
        ckpt = torch.load(args.resume, map_location="cpu", weights_only=False)
        model.load_state_dict(ckpt["model"])
        start_epoch = ckpt["epoch"] + 1
        best_top1 = ckpt.get("best_top1", 0.0)
        print(f"Resumed from {args.resume} at epoch {start_epoch} (best top1 {best_top1:.3f})")

    def make_optimizer(phase: str):
        if phase == "freeze":
            for p in model.backbone.parameters():
                p.requires_grad = False
            params = list(model.embed.parameters()) + list(model.head.parameters())
            return torch.optim.AdamW(params, lr=args.head_lr, weight_decay=args.weight_decay)
        for p in model.parameters():
            p.requires_grad = True
        return torch.optim.AdamW(model.parameters(), lr=args.lr,
                                 weight_decay=args.weight_decay)

    steps_per_epoch = max(1, len(train_loader))
    finetune_total = max(1, (args.epochs - args.freeze_epochs) * steps_per_epoch)
    epochs_no_improve = 0

    try:
        for epoch in range(start_epoch, args.epochs):
            phase = "freeze" if epoch < args.freeze_epochs else "finetune"
            phase_changed = (optimizer is None
                             or (epoch == args.freeze_epochs and phase == "finetune"))
            if phase_changed:
                optimizer = make_optimizer(phase)
                if args.resume and "optimizer" in locals().get("ckpt", {}) and epoch == start_epoch:
                    try:
                        optimizer.load_state_dict(ckpt["optimizer"])
                    except Exception:
                        print("  (optimizer state incompatible, starting fresh)")

            model.train()
            t0 = time.time()
            running_loss, seen = 0.0, 0
            for step, (x, y) in enumerate(train_loader):
                gstep = (epoch - args.freeze_epochs) * steps_per_epoch + step
                if phase == "freeze":
                    lr = lr_at(epoch * steps_per_epoch + step,
                               args.freeze_epochs * steps_per_epoch, args.head_lr, 100)
                else:
                    lr = lr_at(gstep, finetune_total, args.lr, 300)
                for g in optimizer.param_groups:
                    g["lr"] = lr

                x, y = x.to(device), y.to(device)
                if phase == "finetune":
                    x, y_a, y_b, lam = apply_mix(x, y, args.mixup, args.cutmix, args.mix_prob)
                else:
                    y_a, y_b, lam = y, y, 1.0
                optimizer.zero_grad(set_to_none=True)
                if args.amp and device != "cpu":
                    with torch.autocast(device_type=device, dtype=torch.float16):
                        logits, _ = model(x)
                        loss = (criterion(logits, y_a) if lam == 1.0
                                else lam * criterion(logits, y_a) + (1.0 - lam) * criterion(logits, y_b))
                else:
                    logits, _ = model(x)
                    loss = (criterion(logits, y_a) if lam == 1.0
                            else lam * criterion(logits, y_a) + (1.0 - lam) * criterion(logits, y_b))
                loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                optimizer.step()

                running_loss += loss.item() * len(y)
                seen += len(y)
                if step % 50 == 0:
                    ips = seen / max(1e-6, time.time() - t0)
                    print(f"  e{epoch} s{step}/{steps_per_epoch} "
                          f"loss={running_loss / seen:.3f} lr={lr:.2e} {ips:.0f} img/s",
                          flush=True)

            metrics = evaluate(model, val_loader, device, num_classes)
            sec = time.time() - t0
            print(f"epoch {epoch} [{phase}] loss={running_loss / max(1, seen):.3f} "
                  f"val_top1={metrics['top1']:.3f} val_top5={metrics['top5']:.3f} "
                  f"bal={metrics['bal_acc']:.3f} ({sec:.0f}s)")
            with open(log_path, "a", newline="") as f:
                csv.writer(f).writerow([epoch, phase, f"{running_loss / max(1, seen):.4f}",
                                        f"{metrics['top1']:.4f}", f"{metrics['top5']:.4f}",
                                        f"{metrics['bal_acc']:.4f}", f"{lr:.2e}", f"{sec:.0f}"])

            save_checkpoint(run_dir / "last.pt", model, config, epoch, best_top1, optimizer)
            if metrics["top1"] > best_top1:
                best_top1 = metrics["top1"]
                epochs_no_improve = 0
                save_checkpoint(run_dir / "best.pt", model, config, epoch, best_top1)
                print(f"  ** new best top1 {best_top1:.3f} -> best.pt")
            else:
                epochs_no_improve += 1
                if args.patience and epochs_no_improve >= args.patience:
                    print(f"Early stop: no improvement for {args.patience} epochs")
                    break
    except KeyboardInterrupt:
        print("\nInterrupted — last.pt is saved, resume with --resume work/runs/"
              f"{args.run_name}/last.pt")

    print(f"Done. Best val top1 = {best_top1:.3f}. Checkpoints in {run_dir}")


if __name__ == "__main__":
    main()

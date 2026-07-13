"""IconNet: timm backbone + L2-normalized embedding + cosine classifier.

The cosine ("NormSoftmax") head serves two purposes at once:
  - `logits`  -> per-class probabilities for the curated classifier classes;
  - `embedding` (512-d, L2-normalized) -> metric space for k-NN retrieval over
    ALL ~3,150 subjects via per-subject prototypes, giving long-tail coverage
    and "similar icons" suggestions without retraining.
"""
from __future__ import annotations

from pathlib import Path

import timm
import torch
import torch.nn as nn
import torch.nn.functional as F

from icon_dataset import IMAGENET_MEAN, IMAGENET_STD


class NormLinear(nn.Module):
    """Cosine classifier: scale * cos(embedding, class_weight)."""

    def __init__(self, in_dim: int, num_classes: int, scale: float = 30.0):
        super().__init__()
        self.weight = nn.Parameter(torch.empty(num_classes, in_dim))
        nn.init.xavier_uniform_(self.weight)
        self.scale = scale

    def forward(self, x_normalized: torch.Tensor) -> torch.Tensor:
        w = F.normalize(self.weight, dim=1)
        return self.scale * (x_normalized @ w.t())


class IconNet(nn.Module):
    def __init__(self, model_name: str, num_classes: int, embed_dim: int = 512,
                 scale: float = 30.0, pretrained: bool = True):
        super().__init__()
        self.backbone = timm.create_model(model_name, pretrained=pretrained, num_classes=0)
        feat_dim = self.backbone.num_features
        self.embed = nn.Sequential(
            nn.Linear(feat_dim, embed_dim),
            nn.BatchNorm1d(embed_dim),
        )
        self.head = NormLinear(embed_dim, num_classes, scale)

    def forward(self, x: torch.Tensor):
        feat = self.backbone(x)
        emb = F.normalize(self.embed(feat), dim=1)
        logits = self.head(emb)
        return logits, emb


class ExportNet(nn.Module):
    """Inference wrapper for Core ML export.

    Input:  RGB image tensor in [0, 1] (Core ML ImageType with scale=1/255).
    Output: (probabilities, embedding) — normalization is folded inside so the
    Swift side never needs to know mean/std.
    """

    def __init__(self, core: IconNet):
        super().__init__()
        self.core = core
        self.register_buffer("mean", torch.tensor(IMAGENET_MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(IMAGENET_STD).view(1, 3, 1, 1))

    def forward(self, x: torch.Tensor):
        x = (x - self.mean) / self.std
        logits, emb = self.core(x)
        return F.softmax(logits, dim=1), emb


def save_checkpoint(path: Path, model: IconNet, config: dict, epoch: int,
                    best_top1: float, optimizer=None):
    payload = {
        "model": model.state_dict(),
        "config": config,
        "epoch": epoch,
        "best_top1": best_top1,
    }
    if optimizer is not None:
        payload["optimizer"] = optimizer.state_dict()
    path.parent.mkdir(parents=True, exist_ok=True)
    torch.save(payload, path)


def load_checkpoint(path: Path, device: str = "cpu") -> tuple[IconNet, dict]:
    ckpt = torch.load(path, map_location=device, weights_only=False)
    cfg = ckpt["config"]
    model = IconNet(cfg["model_name"], cfg["num_classes"], cfg["embed_dim"],
                    cfg["scale"], pretrained=False)
    model.load_state_dict(ckpt["model"])
    model.to(device).eval()
    return model, ckpt


def pick_device(requested: str = "auto") -> str:
    if requested != "auto":
        return requested
    if torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"

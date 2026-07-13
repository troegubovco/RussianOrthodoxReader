"""Dataset and augmentation pipeline for icon classification.

Key domain decisions:
  - NO horizontal flip: icons carry Church Slavonic inscriptions and oriented
    gestures (blessing hand); mirroring destroys those cues.
  - RandomGlare simulates specular highlights from protective glass, metal
    rizas and candle light — the dominant nuisance in real church photos.
  - Conservative crops keep the full figure in frame most of the time.
"""
from __future__ import annotations

import math
import random

import torch
from PIL import Image, ImageFile
from torch.utils.data import Dataset
from torchvision import transforms

from common import resolve_image_path

ImageFile.LOAD_TRUNCATED_IMAGES = True

IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)


class RandomGlare(torch.nn.Module):
    """Additive elliptical highlight blended toward white (screen blend).

    Operates on a float tensor in [0, 1], BEFORE Normalize.
    """

    def __init__(self, p: float = 0.25, max_alpha: float = 0.55):
        super().__init__()
        self.p = p
        self.max_alpha = max_alpha

    def forward(self, img: torch.Tensor) -> torch.Tensor:
        if random.random() > self.p:
            return img
        _, h, w = img.shape
        cx = random.uniform(0.1 * w, 0.9 * w)
        cy = random.uniform(0.1 * h, 0.9 * h)
        rx = random.uniform(0.12, 0.45) * w
        ry = random.uniform(0.08, 0.35) * h
        theta = random.uniform(0, math.pi)
        alpha = random.uniform(0.2, self.max_alpha)

        yy = torch.arange(h, dtype=torch.float32).view(-1, 1)
        xx = torch.arange(w, dtype=torch.float32).view(1, -1)
        dx, dy = xx - cx, yy - cy
        cos_t, sin_t = math.cos(theta), math.sin(theta)
        d = ((dx * cos_t + dy * sin_t) / rx) ** 2 + ((-dx * sin_t + dy * cos_t) / ry) ** 2
        mask = torch.clamp(1.0 - d, min=0.0) ** 1.5 * alpha  # (h, w)
        return torch.clamp(img + (1.0 - img) * mask.unsqueeze(0), 0.0, 1.0)


def build_transforms(img_size: int, train: bool):
    if train:
        return transforms.Compose([
            transforms.RandomResizedCrop(
                img_size, scale=(0.55, 1.0), ratio=(0.75, 1.33),
                interpolation=transforms.InterpolationMode.BICUBIC),
            transforms.RandomRotation(7, interpolation=transforms.InterpolationMode.BILINEAR),
            transforms.RandomPerspective(distortion_scale=0.12, p=0.3),
            transforms.RandomApply(
                [transforms.ColorJitter(brightness=0.3, contrast=0.3, saturation=0.25, hue=0.03)],
                p=0.8),
            transforms.RandomGrayscale(p=0.08),
            transforms.RandomApply(
                [transforms.GaussianBlur(kernel_size=5, sigma=(0.2, 1.6))], p=0.15),
            transforms.ToTensor(),
            RandomGlare(p=0.25),
            transforms.Normalize(IMAGENET_MEAN, IMAGENET_STD),
            transforms.RandomErasing(p=0.2, scale=(0.02, 0.12), value=0),
        ])
    resize = int(img_size * 292 / 256)
    return transforms.Compose([
        transforms.Resize(resize, interpolation=transforms.InterpolationMode.BICUBIC),
        transforms.CenterCrop(img_size),
        transforms.ToTensor(),
        transforms.Normalize(IMAGENET_MEAN, IMAGENET_STD),
    ])


class IconDataset(Dataset):
    """rows: list of (relpath, label:int). Label -1 is allowed for OOD/inference."""

    def __init__(self, rows: list[tuple[str, int]], img_size: int, train: bool):
        self.rows = rows
        self.tf = build_transforms(img_size, train)

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, idx: int):
        relpath, label = self.rows[idx]
        path = resolve_image_path(relpath)
        with Image.open(path) as im:
            img = im.convert("RGB")
        return self.tf(img), label

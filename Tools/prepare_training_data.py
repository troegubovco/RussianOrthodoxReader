#!/usr/bin/env python3
"""
Split icon images into Training and Testing sets for Create ML.

Uses symlinks to avoid duplicating ~13GB of images.
Handles class imbalance with optional cap per class.

Usage:
    # Default: 80/20 split using full-size images, no cap
    python3 Tools/prepare_training_data.py

    # Cap each class at 2000 images (good for initial experiments)
    python3 Tools/prepare_training_data.py --cap 2000

    # Use thumbnails instead of full-size
    python3 Tools/prepare_training_data.py --source thumbs

    # Custom split ratio
    python3 Tools/prepare_training_data.py --train-ratio 0.9

    # Oversample small classes to match the cap (with augmentation-friendly duplication)
    python3 Tools/prepare_training_data.py --cap 2000 --oversample
"""
import argparse
import os
import random
import shutil


CATEGORIES = ["saints", "theotokos", "christ", "angels"]


def main():
    parser = argparse.ArgumentParser(description="Split icon images for Create ML training")
    parser.add_argument("--images-dir", type=str, default=None,
                        help="Root images directory (default: Tools/data/pravicon_images)")
    parser.add_argument("--source", type=str, default="full", choices=["full", "thumbs"],
                        help="Use full-size or thumbnail images (default: full)")
    parser.add_argument("--output-dir", type=str, default=None,
                        help="Output directory (default: Tools/data/ml_dataset)")
    parser.add_argument("--train-ratio", type=float, default=0.8,
                        help="Fraction of images for training (default: 0.8)")
    parser.add_argument("--cap", type=int, default=0,
                        help="Max images per class (0 = no cap). Samples randomly if class exceeds cap.")
    parser.add_argument("--oversample", action="store_true",
                        help="Oversample small classes up to --cap by repeating images")
    parser.add_argument("--seed", type=int, default=42,
                        help="Random seed for reproducibility")
    parser.add_argument("--exclude", type=str, default=None,
                        help="Comma-separated categories to exclude (e.g. angels)")
    parser.add_argument("--copy", action="store_true",
                        help="Copy files instead of symlinking (uses more disk space)")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    if args.images_dir is None:
        args.images_dir = os.path.join(script_dir, "data", "pravicon_images")
    if args.output_dir is None:
        args.output_dir = os.path.join(script_dir, "data", "ml_dataset")

    source_dir = os.path.join(args.images_dir, args.source)
    train_dir = os.path.join(args.output_dir, "TrainingData")
    test_dir = os.path.join(args.output_dir, "TestingData")

    random.seed(args.seed)

    print(f"Source: {source_dir}")
    print(f"Output: {args.output_dir}")
    print(f"Split:  {args.train_ratio:.0%} train / {1 - args.train_ratio:.0%} test")
    if args.cap > 0:
        print(f"Cap:    {args.cap} per class" + (" (with oversampling)" if args.oversample else ""))
    print(f"Method: {'copy' if args.copy else 'symlink'}")
    print()

    # Clean output directory
    if os.path.exists(args.output_dir):
        shutil.rmtree(args.output_dir)

    total_train = 0
    total_test = 0

    exclude = set(args.exclude.split(",")) if args.exclude else set()

    for cat in CATEGORIES:
        if cat in exclude:
            print(f"  {cat:12s}: EXCLUDED")
            continue
        cat_source = os.path.join(source_dir, cat)
        if not os.path.isdir(cat_source):
            print(f"  {cat}: SKIPPED (directory not found)")
            continue

        # List all images
        all_images = sorted([f for f in os.listdir(cat_source) if f.endswith(".jpg")])
        original_count = len(all_images)

        if original_count == 0:
            print(f"  {cat}: SKIPPED (no images)")
            continue

        # Apply cap (downsample large classes)
        if args.cap > 0 and original_count > args.cap:
            all_images = random.sample(all_images, args.cap)

        # Oversample small classes
        if args.oversample and args.cap > 0 and len(all_images) < args.cap:
            oversampled = []
            while len(oversampled) < args.cap:
                oversampled.extend(all_images)
            all_images = oversampled[:args.cap]
            # Deduplicate filenames by adding suffix
            seen = {}
            unique_images = []
            for fname in all_images:
                if fname not in seen:
                    seen[fname] = 0
                    unique_images.append(fname)
                else:
                    seen[fname] += 1
                    base, ext = os.path.splitext(fname)
                    new_name = f"{base}_dup{seen[fname]}{ext}"
                    unique_images.append(new_name)
            all_images = unique_images

        # Shuffle and split
        random.shuffle(all_images)
        split_idx = int(len(all_images) * args.train_ratio)
        train_images = all_images[:split_idx]
        test_images = all_images[split_idx:]

        # Create directories
        train_cat_dir = os.path.join(train_dir, cat)
        test_cat_dir = os.path.join(test_dir, cat)
        os.makedirs(train_cat_dir, exist_ok=True)
        os.makedirs(test_cat_dir, exist_ok=True)

        # Link or copy files
        def place_file(fname, dest_dir):
            # For oversampled duplicates, resolve to original filename
            original_fname = fname.split("_dup")[0] + ".jpg" if "_dup" in fname else fname
            src = os.path.join(cat_source, original_fname)
            dst = os.path.join(dest_dir, fname)
            if args.copy:
                shutil.copy2(src, dst)
            else:
                os.symlink(os.path.abspath(src), dst)

        for f in train_images:
            place_file(f, train_cat_dir)
        for f in test_images:
            place_file(f, test_cat_dir)

        total_train += len(train_images)
        total_test += len(test_images)

        note = ""
        if args.cap > 0 and original_count > args.cap:
            note = f" (downsampled from {original_count})"
        elif args.oversample and args.cap > 0 and original_count < args.cap:
            note = f" (oversampled from {original_count})"

        print(f"  {cat:12s}: {len(train_images):5d} train + {len(test_images):5d} test "
              f"= {len(all_images):5d}{note}")

    print()
    print(f"Total: {total_train} train + {total_test} test = {total_train + total_test}")
    print()
    print(f"Ready for Create ML:")
    print(f"  Training Data: {train_dir}")
    print(f"  Testing Data:  {test_dir}")
    print()
    print("Next steps:")
    print("  1. Open Xcode → Xcode menu → Open Developer Tool → Create ML")
    print("  2. New Document → Image Classification")
    print("  3. Drag TrainingData/ into Training Data")
    print("  4. Drag TestingData/ into Testing Data")
    print("  5. Enable augmentations (Flip, Rotate, Crop, Blur, Noise)")
    print("  6. Train!")


if __name__ == "__main__":
    main()

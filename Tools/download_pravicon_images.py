#!/usr/bin/env python3
"""
Download icon images from pravicon.com.

Reads the details JSON and downloads images for each entry.
Supports both thumbnails (~10KB) and full-size (~1MB) images.
Resume-safe: skips already-downloaded files.
Parallel downloads with --workers for speed.

Usage:
    # Download all thumbnails with 4 parallel workers (~15-20 min)
    python3 Tools/download_pravicon_images.py --workers 4

    # Download full-size images
    python3 Tools/download_pravicon_images.py --full-size --workers 4

    # Download both thumbnails and full-size
    python3 Tools/download_pravicon_images.py --full-size --thumbnails --workers 4

    # Limit to N images per entry (e.g., first 5)
    python3 Tools/download_pravicon_images.py --max-per-entry 5

    # Only specific categories
    python3 Tools/download_pravicon_images.py --categories saints,theotokos
"""
import argparse
import json
import os
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed


BASE_URL = "https://pravicon.com"


def download_file(url: str, dest: str, retries: int = 3) -> int | None:
    """Download a file. Returns file size in bytes on success, None on failure."""
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": "RussianOrthodoxReader/1.0 (icon catalog builder)",
                "Accept": "image/jpeg,image/png,image/*",
            })
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = resp.read()
                with open(dest, "wb") as f:
                    f.write(data)
                return len(data)
        except Exception as e:
            if attempt < retries - 1:
                time.sleep(2 * (attempt + 1))
            else:
                return None
    return None


def thumb_to_full(thumb_path: str) -> str:
    """Convert thumbnail path to full-size path: /images/icons/8/8800_t.jpg -> /images/icons/8/8800.jpg"""
    return thumb_path.replace("_t.jpg", ".jpg")


def image_id_from_path(thumb_path: str) -> str:
    """Extract numeric image ID from path: /images/icons/8/8800_t.jpg -> 8800"""
    basename = os.path.basename(thumb_path)
    return basename.replace("_t.jpg", "").replace(".jpg", "")


# Thread-safe stats
class Stats:
    def __init__(self):
        self._lock = threading.Lock()
        self.downloaded = 0
        self.skipped = 0
        self.failed = 0
        self.bytes = 0

    def add_download(self, size: int):
        with self._lock:
            self.downloaded += 1
            self.bytes += size

    def add_skip(self):
        with self._lock:
            self.skipped += 1

    def add_fail(self):
        with self._lock:
            self.failed += 1

    def snapshot(self):
        with self._lock:
            return self.downloaded, self.skipped, self.failed, self.bytes


def do_download(url: str, dest: str, stats: Stats) -> bool:
    """Single download task for the thread pool."""
    if os.path.exists(dest):
        stats.add_skip()
        return True
    size = download_file(url, dest)
    if size is not None:
        stats.add_download(size)
        return True
    else:
        stats.add_fail()
        return False


def main():
    parser = argparse.ArgumentParser(description="Download pravicon.com icon images")
    parser.add_argument("--details", type=str, default=None, help="Input details JSON")
    parser.add_argument("--output-dir", type=str, default=None, help="Output image directory")
    parser.add_argument("--workers", type=int, default=4,
                        help="Parallel download threads (default 4, use 1 for sequential)")
    parser.add_argument("--max-per-entry", type=int, default=0,
                        help="Max images per entry (0 = all available)")
    parser.add_argument("--full-size", action="store_true",
                        help="Download full-size images (default: thumbnails only)")
    parser.add_argument("--thumbnails", action="store_true",
                        help="Also download thumbnails (when used with --full-size)")
    parser.add_argument("--categories", type=str, default=None,
                        help="Comma-separated categories to download (e.g. saints,theotokos)")
    parser.add_argument("--start-from-icon", type=int, default=0,
                        help="Start from this icon_id (for resuming a specific point)")
    args = parser.parse_args()

    # If neither --full-size nor --thumbnails, default to thumbnails
    download_thumbs = True
    download_full = args.full_size
    if args.full_size and args.thumbnails:
        download_thumbs = True
    elif args.full_size and not args.thumbnails:
        download_thumbs = False

    script_dir = os.path.dirname(os.path.abspath(__file__))
    if args.details is None:
        args.details = os.path.join(script_dir, "data", "pravicon_details.json")
    if args.output_dir is None:
        args.output_dir = os.path.join(script_dir, "data", "pravicon_images")

    filter_categories = None
    if args.categories:
        filter_categories = set(args.categories.split(","))

    with open(args.details, "r", encoding="utf-8") as f:
        details = json.load(f)
    print(f"Loaded {len(details)} entries")

    # Create output directories
    subdirs = []
    if download_thumbs:
        subdirs.append("thumbs")
    if download_full:
        subdirs.append("full")
    for sub in subdirs:
        for cat in ("saints", "theotokos", "christ", "angels"):
            os.makedirs(os.path.join(args.output_dir, sub, cat), exist_ok=True)

    # Build the full list of download jobs: (url, dest_path)
    jobs: list[tuple[str, str]] = []
    entry_images: dict[int, list[str]] = {}  # icon_id -> [img_ids] for manifest

    for entry in details:
        icon_id = entry.get("icon_id")
        category = entry.get("category", "saints")
        thumbnails = entry.get("thumbnails", [])

        if not thumbnails or entry.get("error"):
            continue
        if icon_id < args.start_from_icon:
            continue
        if filter_categories and category not in filter_categories:
            continue

        limit = args.max_per_entry if args.max_per_entry > 0 else len(thumbnails)
        img_ids = []

        for thumb_path in thumbnails[:limit]:
            img_id = image_id_from_path(thumb_path)
            img_ids.append(img_id)

            if download_thumbs:
                dest = os.path.join(args.output_dir, "thumbs", category, f"{img_id}.jpg")
                jobs.append((f"{BASE_URL}{thumb_path}", dest))

            if download_full:
                full_path = thumb_to_full(thumb_path)
                dest = os.path.join(args.output_dir, "full", category, f"{img_id}.jpg")
                jobs.append((f"{BASE_URL}{full_path}", dest))

        entry_images[icon_id] = img_ids

    # Count how many already exist
    already_exist = sum(1 for _, dest in jobs if os.path.exists(dest))
    to_download = len(jobs) - already_exist
    print(f"Total jobs: {len(jobs)} ({already_exist} already exist, {to_download} to download)")
    print(f"Workers: {args.workers}")

    if to_download == 0:
        print("Nothing to download!")
        return

    stats = Stats()
    start_time = time.time()

    try:
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            futures = {
                pool.submit(do_download, url, dest, stats): (url, dest)
                for url, dest in jobs
            }

            done_count = 0
            for future in as_completed(futures):
                done_count += 1
                # Progress every 500 completed jobs
                if done_count % 500 == 0:
                    dl, skip, fail, nbytes = stats.snapshot()
                    elapsed = time.time() - start_time
                    rate = dl / elapsed if elapsed > 0 else 0
                    mb = nbytes / (1024 * 1024)
                    pct = done_count / len(jobs) * 100
                    print(f"[{done_count}/{len(jobs)}] ({pct:.0f}%) "
                          f"dl={dl} skip={skip} fail={fail} "
                          f"size={mb:.1f}MB rate={rate:.0f}/s", flush=True)

    except KeyboardInterrupt:
        print("\nInterrupted!")

    # Save manifest
    manifest_path = os.path.join(args.output_dir, "manifest.json")
    manifest = {}
    for entry in details:
        icon_id = entry.get("icon_id")
        if icon_id in entry_images:
            manifest[str(icon_id)] = {
                "category": entry.get("category", ""),
                "name": entry.get("name", ""),
                "images": entry_images[icon_id],
            }
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    dl, skip, fail, nbytes = stats.snapshot()
    elapsed = time.time() - start_time
    mb = nbytes / (1024 * 1024)
    print(f"\nDone in {elapsed:.0f}s.")
    print(f"  Downloaded:  {dl}")
    print(f"  Skipped:     {skip} (already exist)")
    print(f"  Failed:      {fail}")
    print(f"  New data:    {mb:.1f} MB")
    print(f"  Manifest:    {manifest_path}")

    # Total disk usage
    total_size = 0
    file_count = 0
    for root, _, files in os.walk(args.output_dir):
        for fname in files:
            if fname.endswith(".jpg"):
                total_size += os.path.getsize(os.path.join(root, fname))
                file_count += 1
    print(f"  Total on disk: {file_count} files, {total_size / (1024 * 1024):.1f} MB")


if __name__ == "__main__":
    main()

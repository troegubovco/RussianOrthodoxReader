#!/usr/bin/env python3
"""
Build the icons SQLite database from scraped data and downloaded images.

Produces a rich SQLite database suitable for both app bundling and ML workflows:
  - Full metadata (name, category, feast days, keywords, biography)
  - Image references with source URLs and local file paths
  - FTS5 full-text search on name, keywords, and biography
  - Keyword normalization table for filtering/faceting

Usage:
    python3 Tools/build_icons_db.py
    python3 Tools/build_icons_db.py --output Tools/data/icons.sqlite
    python3 Tools/build_icons_db.py --embed-thumbs  # embed thumbnail bytes in DB
"""
import argparse
import json
import os
import re
import sqlite3


def create_schema(conn: sqlite3.Connection):
    conn.executescript("""
        -- Main icons table
        CREATE TABLE IF NOT EXISTS icons (
            icon_id         INTEGER PRIMARY KEY,
            name            TEXT NOT NULL,
            category        TEXT NOT NULL,     -- saints, theotokos, christ, angels
            feast_days_json TEXT,              -- JSON array of dates
            keywords_csv    TEXT,              -- comma-separated keywords
            biography       TEXT,
            total_images    INTEGER DEFAULT 0, -- total on pravicon.com
            scraped_images  INTEGER DEFAULT 0, -- how many URLs we captured
            source_url      TEXT,              -- pravicon.com URL
            representative_image_id INTEGER    -- selected build-time thumbnail for app UI
        );

        -- Individual images with source URLs and local file references
        CREATE TABLE IF NOT EXISTS images (
            image_id        INTEGER PRIMARY KEY,  -- numeric ID from pravicon (e.g., 18994)
            icon_id         INTEGER NOT NULL,
            source_thumb    TEXT NOT NULL,         -- pravicon thumbnail URL path
            source_full     TEXT NOT NULL,         -- pravicon full-size URL path
            local_thumb     TEXT,                  -- local file path (thumbs/category/id.jpg)
            local_full      TEXT,                  -- local file path (full/category/id.jpg)
            ordinal         INTEGER DEFAULT 0,     -- position in the entry's image list
            feature_row     INTEGER,               -- row in the binary embedding matrix
            feature_source  TEXT,                  -- full | thumb
            FOREIGN KEY (icon_id) REFERENCES icons(icon_id)
        );

        -- Optional: embed thumbnail bytes directly in DB for portable ML datasets
        CREATE TABLE IF NOT EXISTS image_blobs (
            image_id    INTEGER PRIMARY KEY,
            thumb_jpg   BLOB,
            FOREIGN KEY (image_id) REFERENCES images(image_id)
        );

        -- Normalized keywords for faceted search / ML labels
        CREATE TABLE IF NOT EXISTS keywords (
            keyword_id  INTEGER PRIMARY KEY AUTOINCREMENT,
            keyword     TEXT NOT NULL UNIQUE
        );

        CREATE TABLE IF NOT EXISTS icon_keywords (
            icon_id     INTEGER NOT NULL,
            keyword_id  INTEGER NOT NULL,
            PRIMARY KEY (icon_id, keyword_id),
            FOREIGN KEY (icon_id) REFERENCES icons(icon_id),
            FOREIGN KEY (keyword_id) REFERENCES keywords(keyword_id)
        );

        -- Indexes
        CREATE INDEX IF NOT EXISTS idx_icons_category ON icons(category);
        CREATE INDEX IF NOT EXISTS idx_icons_name ON icons(name);
        CREATE INDEX IF NOT EXISTS idx_icons_representative_image ON icons(representative_image_id);
        CREATE INDEX IF NOT EXISTS idx_images_icon_id ON images(icon_id);
        CREATE INDEX IF NOT EXISTS idx_images_feature_row ON images(feature_row);
        CREATE INDEX IF NOT EXISTS idx_icon_keywords_keyword ON icon_keywords(keyword_id);
    """)


def create_fts(conn: sqlite3.Connection):
    """Create FTS5 virtual table for full-text search."""
    conn.executescript("""
        CREATE VIRTUAL TABLE IF NOT EXISTS icons_fts USING fts5(
            name, keywords_csv, biography,
            content='icons',
            content_rowid='icon_id'
        );

        -- Populate FTS from icons table
        INSERT INTO icons_fts(rowid, name, keywords_csv, biography)
            SELECT icon_id, name, keywords_csv, COALESCE(biography, '') FROM icons;

        -- Triggers to keep FTS in sync if icons are updated
        CREATE TRIGGER IF NOT EXISTS icons_ai AFTER INSERT ON icons BEGIN
            INSERT INTO icons_fts(rowid, name, keywords_csv, biography)
                VALUES (new.icon_id, new.name, new.keywords_csv, COALESCE(new.biography, ''));
        END;

        CREATE TRIGGER IF NOT EXISTS icons_ad AFTER DELETE ON icons BEGIN
            INSERT INTO icons_fts(icons_fts, rowid, name, keywords_csv, biography)
                VALUES ('delete', old.icon_id, old.name, old.keywords_csv, COALESCE(old.biography, ''));
        END;

        CREATE TRIGGER IF NOT EXISTS icons_au AFTER UPDATE ON icons BEGIN
            INSERT INTO icons_fts(icons_fts, rowid, name, keywords_csv, biography)
                VALUES ('delete', old.icon_id, old.name, old.keywords_csv, COALESCE(old.biography, ''));
            INSERT INTO icons_fts(rowid, name, keywords_csv, biography)
                VALUES (new.icon_id, new.name, new.keywords_csv, COALESCE(new.biography, ''));
        END;
    """)


def extract_image_id(thumb_path: str) -> int | None:
    """Extract numeric image ID: /images/icons/8/8800_t.jpg -> 8800"""
    m = re.search(r"/(\d+)_t\.jpg$", thumb_path)
    return int(m.group(1)) if m else None


def main():
    parser = argparse.ArgumentParser(description="Build icons SQLite database")
    parser.add_argument("--details", type=str, default=None, help="Input details JSON")
    parser.add_argument("--images-dir", type=str, default=None, help="Downloaded images directory")
    parser.add_argument("--output", type=str, default=None, help="Output SQLite path")
    parser.add_argument("--embed-thumbs", action="store_true",
                        help="Embed thumbnail JPEG bytes into the DB (adds ~300MB)")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(script_dir)

    if args.details is None:
        args.details = os.path.join(script_dir, "data", "pravicon_details.json")
    if args.images_dir is None:
        args.images_dir = os.path.join(script_dir, "data", "pravicon_images")
    if args.output is None:
        args.output = os.path.join(script_dir, "data", "icons.sqlite")

    with open(args.details, "r", encoding="utf-8") as f:
        details = json.load(f)
    print(f"Loaded {len(details)} entries from {args.details}")

    # Remove existing DB
    if os.path.exists(args.output):
        os.remove(args.output)

    conn = sqlite3.connect(args.output)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    create_schema(conn)

    # Collect all unique keywords
    all_keywords: dict[str, int] = {}  # keyword -> keyword_id

    icons_count = 0
    images_count = 0
    blobs_count = 0
    errors = 0

    for entry in details:
        icon_id = entry.get("icon_id")
        if not icon_id or entry.get("error"):
            errors += 1
            continue

        name = entry.get("name", "")
        category = entry.get("category", "")
        feast_days = entry.get("feast_days", [])
        keywords = entry.get("keywords", [])
        biography = entry.get("biography")
        thumbnails = entry.get("thumbnails", [])
        total_images = entry.get("total_images", 0)

        # Insert icon
        conn.execute(
            "INSERT OR REPLACE INTO icons "
            "(icon_id, name, category, feast_days_json, keywords_csv, biography, "
            " total_images, scraped_images, source_url) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                icon_id, name, category,
                json.dumps(feast_days, ensure_ascii=False),
                ", ".join(keywords),
                biography,
                total_images,
                len(thumbnails),
                f"https://pravicon.com/icon-{icon_id}",
            ),
        )
        icons_count += 1

        # Insert normalized keywords
        for kw in keywords:
            kw_normalized = kw.strip()
            if not kw_normalized:
                continue
            if kw_normalized not in all_keywords:
                conn.execute("INSERT OR IGNORE INTO keywords (keyword) VALUES (?)", (kw_normalized,))
                row = conn.execute("SELECT keyword_id FROM keywords WHERE keyword = ?",
                                   (kw_normalized,)).fetchone()
                all_keywords[kw_normalized] = row[0]
            conn.execute("INSERT OR IGNORE INTO icon_keywords (icon_id, keyword_id) VALUES (?, ?)",
                         (icon_id, all_keywords[kw_normalized]))

        # Insert images
        for j, thumb_path in enumerate(thumbnails):
            img_id = extract_image_id(thumb_path)
            if img_id is None:
                continue

            full_path = thumb_path.replace("_t.jpg", ".jpg")
            local_thumb = f"thumbs/{category}/{img_id}.jpg"
            local_full = f"full/{category}/{img_id}.jpg"

            # Check if local files exist
            thumb_exists = os.path.exists(os.path.join(args.images_dir, local_thumb))
            full_exists = os.path.exists(os.path.join(args.images_dir, local_full))

            conn.execute(
                "INSERT OR REPLACE INTO images "
                "(image_id, icon_id, source_thumb, source_full, local_thumb, local_full, ordinal) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    img_id, icon_id,
                    thumb_path, full_path,
                    local_thumb if thumb_exists else None,
                    local_full if full_exists else None,
                    j,
                ),
            )
            images_count += 1

            # Optionally embed thumbnail bytes
            if args.embed_thumbs and thumb_exists:
                thumb_file = os.path.join(args.images_dir, local_thumb)
                with open(thumb_file, "rb") as tf:
                    blob = tf.read()
                conn.execute(
                    "INSERT OR REPLACE INTO image_blobs (image_id, thumb_jpg) VALUES (?, ?)",
                    (img_id, blob),
                )
                blobs_count += 1

    # Build FTS index
    print("Building FTS index...")
    create_fts(conn)

    conn.commit()

    # Print stats
    kw_count = conn.execute("SELECT COUNT(*) FROM keywords").fetchone()[0]
    icon_kw_count = conn.execute("SELECT COUNT(*) FROM icon_keywords").fetchone()[0]

    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()

    db_size = os.path.getsize(args.output)
    print(f"\nDone. Built {args.output}")
    print(f"  Icons:           {icons_count}")
    print(f"  Image records:   {images_count}")
    print(f"  Unique keywords: {kw_count}")
    print(f"  Keyword links:   {icon_kw_count}")
    print(f"  Embedded blobs:  {blobs_count}")
    print(f"  Errors skipped:  {errors}")
    print(f"  DB size:         {db_size / (1024 * 1024):.1f} MB")

    # Category breakdown
    conn2 = sqlite3.connect(args.output)
    for row in conn2.execute(
        "SELECT category, COUNT(*), SUM(scraped_images) FROM icons GROUP BY category ORDER BY category"
    ):
        print(f"    {row[0]:12s}: {row[1]:5d} icons, {row[2]:6d} image URLs")

    # Top keywords
    print(f"\n  Top 15 keywords:")
    for row in conn2.execute(
        "SELECT k.keyword, COUNT(*) as cnt FROM icon_keywords ik "
        "JOIN keywords k ON ik.keyword_id = k.keyword_id "
        "GROUP BY k.keyword ORDER BY cnt DESC LIMIT 15"
    ):
        print(f"    {row[1]:5d}  {row[0]}")

    conn2.close()


if __name__ == "__main__":
    main()

# Icon Identification Feature — Initial Prompt

Copy everything below this line into a new Claude Code chat:

---

I'm building an icon identification feature for my Russian Orthodox Reader iOS app (SwiftUI, iOS 16+). The goal is: **user takes a photo of an icon → app identifies which specific icon it is** from a database of 3,158 icons (saints, Theotokos, Christ, angels) with 32,054 images total.

## What I already have

### Scraped data (from pravicon.com)
- `Tools/data/pravicon_details.json` — 3,158 icon entries with metadata (name, category, feast days, keywords, biography)
- `Tools/data/pravicon_images/full/` — 32,037 full-size images (~13GB), organized as `full/{category}/{image_id}.jpg`
- `Tools/data/pravicon_images/thumbs/` — 32,037 thumbnails (~321MB), same structure
- `Tools/data/icons.sqlite` — 11.3MB SQLite database with FTS5 search, normalized keywords, and image references
- `Tools/data/ml_dataset/testing_FS/` — 20% holdout test set of full-size images (6,406 images across 4 categories)

### Database schema (icons.sqlite)
- `icons` table: icon_id, name, category, feast_days_json, keywords_csv, biography, source_url
- `images` table: image_id, icon_id, source_thumb, source_full, local_thumb, local_full, ordinal
- `keywords` + `icon_keywords`: normalized keyword facets (447 unique keywords)
- `icons_fts`: FTS5 full-text search on name, keywords, biography

### App architecture
- SwiftUI with custom TabBar (ZStack-based, not TabView)
- `AppState.swift` — ObservableObject for app-wide state
- `BibleSQLiteRepository.swift` — existing SQLite3 wrapper pattern
- `DictionaryRepository.swift` — existing singleton repository pattern
- Typography via `@Environment(\.userFontSize)` with `AppTypography(base:)`

### What I've learned so far
- A 3-class image **classifier** (saints/theotokos/christ) hit 83% accuracy in Create ML, but classification is the wrong approach for identifying specific icons
- The correct approach is **image similarity / embeddings**: encode all icons as vectors, then at runtime find the closest match to the user's photo
- Apple's Vision framework has `VNGenerateImageFeaturePrintRequest` which produces feature vectors with `computeDistance(to:)` — no custom ML training needed
- The 3-class classifier could still serve as a pre-filter to narrow search space

## What I need built

1. **Pre-compute embeddings**: A build-time Swift script (or Python with coremltools) that processes all 32K images and stores their feature vectors in SQLite or a binary file
2. **Runtime search**: An `IconIdentifier` class that takes a `CGImage`, computes its embedding, and returns the top N closest matches from the database
3. **App integration**: A camera/photo picker view → identification results view showing the matched icon(s) with confidence scores, name, feast days, and biography
4. **Performance**: Search should complete in <1 second on device. Consider using the 3-class classifier as a pre-filter, or spatial indexing (VP-tree / ball tree) for the embedding search

### Key files to reference for patterns
- `RussianOrthodoxReader/Data/BibleSQLiteRepository.swift` — SQLite wrapper pattern
- `RussianOrthodoxReader/Data/DictionaryRepository.swift` — singleton repository pattern
- `RussianOrthodoxReader/DesignSystem.swift` — colors, fonts, typography
- `RussianOrthodoxReader/AppState.swift` — app state management
- `Tools/build_icons_db.py` — current DB builder (may need schema updates for embeddings)

Start by reading the key files above to understand existing patterns, then propose an implementation plan.

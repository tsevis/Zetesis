# Zetesis

<img src="documents/icon.png" width="128" align="right" alt="Zetesis' icon: a black-figure Greek capital Zeta on terracotta, over a meander band.">

A native macOS app that searches inside every book of a large personal library: PDFs, EPUBs,
text files and folders of Markdown with images. Named after *zetesis* (ζήτησις), the ancient
philosophers' word for inquiry: the search that goes on until it finds.

**Version 0.1.0.** SwiftUI, macOS 15 or later. The interface is in Greek.

## What it does

- **Full-text search over every page.** Results arrive while you type. Each one names the pages
  where the words appear and shows the passages around them. `"two words"` searches a phrase,
  `geom*` a prefix, `OR` gives alternatives and `-word` excludes a word. Accents and case are ignored.
- **A reader that opens at the page.** It opens the PDF at the page that matched, with the words
  highlighted, and lists every other matching page beside it. Books without a PDF show the indexed
  text of the page instead.
- **Topics.** The sidebar groups books by topic. New books get a topic automatically, from the
  books they resemble, and are marked ✨ until you confirm the topic or change it. `_ΘΕΜΑΤΑ/` in the
  library holds the same grouping as symlinks. Nothing is moved.
- **Export.** Every book that matches a search can be saved as one Markdown file, with its best
  passages and `file://` links to the exact PDF pages.
- **Always current.** While the app is open, a book copied into the library is indexed once the copy
  has finished. A LaunchAgent, switched on in Settings, does the same while the app is closed. Only
  new or changed books are processed.
- **Works without the disk.** The index lives on the internal disk, so search still works when the
  library's external drive is unplugged. Opening files needs the drive.

## How it is built

- `Engine/` (Python 3.10+, standard library only). It scans the library, extracts text per page
  with `pdftotext` from poppler, classifies new books and keeps the SQLite FTS5 index up to date.
  The app copies it into `~/Library/Application Support/Zetesis/Engine` and runs it there.
- `Zetesis/` (Swift). It reads the index directly through the system SQLite.
- **Design for large libraries.**
  - A page's rowid encodes its book (`book << 17 | n`). Ranking books therefore only reads the FTS
    doclist and never looks a page up.
  - Books are scored by a book-level BM25 over their matching pages.
  - Snippets are fetched only for the result rows on screen.
  - Page text is stored deflate-compressed.
  - The inventory re-lists only the folders whose modification time changed.
  - A full rebuild writes a new index file and moves a pointer, so the app never reads a file that is
    being replaced.

Working data stays in the library, in `_SEARCH/`: the inventory, `topics.json` and the text cache.
The index is in `~/Library/Application Support/Zetesis/`.

## Build

```bash
brew install xcodegen poppler
xcodegen generate
xcodebuild -scheme Zetesis -configuration Release -derivedDataPath build/dd build
```

`python3 Scripts/make-icon.py` redraws the icon.

## Tests

```bash
xcodebuild test -scheme Zetesis -destination 'platform=macOS' -derivedDataPath build/dd -only-testing:ZetesisTests
```

They are hostless and never open a window.

## Release

Signed with Developer ID, notarized and stapled by the shared script in `biblioteca`:

```bash
APPLE_TEAM_ID=<your Team ID> ../biblioteca/Scripts/sign-and-notarize.sh build/dd/Build/Products/Release/Zetesis.app
```

The signed app and a DMG are written to `build/dd/Build/Products/Release/signed/`.

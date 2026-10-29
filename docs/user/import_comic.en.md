# Import Comic

## Introduction

VeneraPlus can import comics from local directories, comic archives, PDF files,
and image-based EPUB files. Imported content is normalized into the existing
local image-comic layout so all reader modes, progress tracking, and split-spread
features continue to work.

Local comics are located under `Library` -> `Local Comics`. Imported comics
can be browsed, sorted, and read directly there.

Supported comic image extensions are `jpg`, `jpeg`, `jpe`, `png`, `webp`,
`gif`, and `avif`.

## Restore Local Downloads

If you migrated the app and kept the local download folder but lost `local.db`,
you can restore the local database by scanning the current local path.

- Open `Library` -> `Local Comics` -> top bar `Import` -> `Restore local downloads`.
- The app scans the current local storage path and rebuilds entries.
- It does not copy files or add favorites.
- Duplicates (same title or directory) are skipped.

Make sure the local storage path in `Settings → Storage and Sync` points to the folder that contains
the downloaded comics before running this.

## Comic Directory

A directory considered as a comic directory only if it follows one of the following two types of structure:

**Without Chapter**

```
comic_directory
├── cover.[ext]
├── img1.[ext]
├── img2.[ext]
├── img3.[ext]
├── ...
```

**With Chapter**

```
comic_directory
├── cover.[ext]
├── chapter1
│   ├── img1.[ext]
│   ├── img2.[ext]
│   ├── img3.[ext]
│   ├── ...
├── chapter2
│   ├── img1.[ext]
│   ├── img2.[ext]
│   ├── img3.[ext]
│   ├── ...
├── ...
```

The file name can be anything, but the extension must be a valid image extension.

The page order is determined by the file name. App will sort the files by name and display them in that order.

Cover image is optional. 
If there is a file named `cover.[ext]` in the directory, it will be considered as the cover image.
Otherwise, the first image will be considered as the cover image.

The name of directory will be used as comic title. And the name of chapter directory will be used as chapter title.

## Archive

VeneraPlus supports importing comics from archive files.

Archive files are intended for import, export, backup, migration, and distribution. They must follow [Comic Book Archive](https://en.wikipedia.org/wiki/Comic_book_archive_file) format.

Currently, VeneraPlus supports the following archive formats:
- `.cbz`
- `.cb7`
- `.zip`
- `.7z`

An archive may contain images directly, or it may contain one top-level folder.
If the top-level folder contains chapter folders, VeneraPlus imports those
folders as chapters.

```text
Cat's Eye.cbz
└── Cat's Eye
    ├── cover.jpg
    ├── Volume 01
    │   ├── 001.jpg
    │   └── 002.jpg
    └── Volume 02
        ├── 001.jpg
        └── 002.jpg
```

If there is no `cover.[ext]` in the root folder, the first image from the first
chapter is used as the cover.

## PDF and Image-based EPUB

Open `Library` -> `Local Comics` -> top bar `Import` and select either a PDF comic file or an image-based
EPUB file. Both formats are converted into app-managed local image comics during
import; the original document is not streamed by the reader.

### PDF

- Open `Library` -> `Local Comics` -> top bar `Import` -> `PDF comic files` to select one or more PDFs. Each file becomes a separate comic, and the destination favorites folder is selected once for the batch.
- **Background Task Management**: PDF imports run sequentially in a background queue as app-managed tasks. After starting an import, you can close the progress dialog, return to previous views, or read other comics without interrupting the process. You can reopen the task status dialog from the `Library` -> `Local Comics` page (task icon button or narrow screen overflow menu); completed tasks never hijack current navigation.
- **Cancellation & Safe Cleanup**: Cancelling stops remaining queued files (queued tasks are disposed immediately without preparation); in-progress rendering or saving finishes safely before cleaning up unfinished directory artifacts. Successfully imported comics are preserved and never rolled back by late cancellations.
- **Session Boundary & Exit Limits**: Tasks exist only within the current application session. Keep the app alive during import; resuming tasks after application exit or process termination across restarts is not supported. On Android, files that cannot be accessed directly are prepared in temporary storage one by one and released immediately after conversion.
- **Storage Migration & Directory Ownership Protection**:
  - Background imports are protected by `LocalStorageGuard` during rendering and registration. Changing the local storage path (`setNewPath`) and local download recovery scans are rejected while an import is active; conversely, imports safely wait if storage migration is already underway.
  - Import sessions synchronously allocate and claim exclusive destination directories before rendering begins, preventing conflicts with concurrent CBZ restorations, directory copies, or other imports sharing the same title. Task cancellation cleans only its own designated directory without damaging data from other operations.
- Each PDF page is rendered to JPEG in order, and the first page is also used as the cover.
- The result is a flat comic without chapters. Its title defaults to the PDF file name.
- Pages are rendered at roughly three times their PDF point size with a 3000-pixel longest-edge limit to balance clarity, memory, and storage use.
- Encrypted or password-protected PDF files are not currently supported.
- Import creates a new image copy, so additional local storage is required.

### Image-based EPUB

- Fixed-layout EPUB files may use direct raster-image spine items or XHTML/SVG wrappers containing `img` or SVG `image` references.
- Page order follows the EPUB spine. Title, author, and cover metadata are preserved when available.
- Multiple valid navigation entries are preserved as chapters. Files without meaningful chapter navigation are imported as flat comics.
- Original raster images are copied without recompression.
- Text-based EPUB files, directly rendered SVG pages, external image references, and paths outside the EPUB root are rejected instead of silently dropping content.

MOBI, AZW, and AZW3 are not supported. Convert them externally to an image-based
EPUB, PDF, or CBZ before importing.

Document import never overwrites an existing comic with the same title.

## WebDAV and Cloud Online Libraries

Online libraries provide a reading channel separate from local import/export and comic archive backup, using WebDAV or a configured cloud account.

Online reading supports remote image directories, single-comic ZIP/CBZ files, image-based EPUB files, and PDF files. Directory comics list folders and load images on demand; ZIP/CBZ and image-based EPUB files supply images directly without extraction on the server, while PDF files render the requested original pages. A single-comic CBZ exported by VeneraPlus (or legacy VeneraNext) can retain its title, author, tags, and chapters, while EPUB uses OPF book metadata and navigation. See [Multi-cloud storage](multi_cloud.en.md) for account and directory setup.

The **Sync comic library config** switch in WebDAV Comic Library settings is off by default. When enabled, DataSync/Appdata `.venera` files include the library URL, username, password, remote path, automatic-update switch, and update interval. The receiving device must also enable this switch locally before those fields are imported. Credentials are stored in the remote `.venera` file, so enable this only for trusted WebDAV storage and accounts.

### Plain Directory Mode

Recommended structure:

```text
/venera_comics/
└── Cat's Eye
    ├── cover.jpg
    ├── Volume 01
    │   ├── 001.jpg
    │   └── 002.jpg
    └── Volume 02
        ├── 001.jpg
        └── 002.jpg
```

Plain directory rules:

- The comic title defaults to the comic folder name.
- Child directories are chapters. Root-level images can also form a single-chapter comic.
- Pages and chapters are sorted by file name. Zero-padded names such as `0001.jpg` and `0002.jpg` are recommended.
- The preferred cover is a root image whose base name is `cover`. Supported extensions are `jpg`, `jpeg`, `png`, `webp`, `gif`, `jpe`, and `avif`. Without one, the app tries the first root page, then `cover.*` or the first page in the first readable chapter.
- Neither `metadata.json` nor `ComicInfo.xml` is required.

### Automatic Bangumi Scraping

After Bangumi is connected and **Automatic metadata scraping** is enabled in Settings (disabled by default), WebDAV library synchronization searches Bangumi for comics that do not have `metadata.json`. Before searching, the app removes explicitly labeled trailing author hints such as `Author: [Tsukasa Hojo]` or `作者：【北条司】`, plus known release annotations such as `语言：[Chinese]`, `版本[无修正]`, `[DL版]`, and `汉化者：[Group]`. Unknown unlabeled bracketed content remains part of the title. The cleaned title must exactly match the Bangumi Chinese or original title. If several subjects have the same title, the author hint must uniquely match the subject infobox or an author, original-creator, or artist relationship returned by the persons endpoint. Fuzzy or ambiguous results are not written.

On a successful match, the app creates a UTF-8 `metadata.json` with a create-only conditional request, so it cannot replace a file created concurrently by another client. The title uses Bangumi `name_cn`, falling back to `name`; the description uses the subject detail `summary`; authors come from the subject infobox or persons endpoint; tags combine all official `meta_tags` with the top 10 user tags ordered by descending `count`, then deduplicate the result. The WebDAV account must have write access. Automatic scraping never replaces an existing metadata file and does not download the Bangumi cover. Unmatched (`noMatch`) states are retained locally; the app does not re-query Bangumi during routine syncs, forced syncs, or file changes under the same scraper version, retrying only when the scraper version changes or when the user manually binds the subject. Transient network failures are retried after backoff.

When the user manually binds a Bangumi subject from comic details, that explicit selection is authoritative. A `bangumiSubjectId` already stored in `metadata.json` preselects that subject in the binding panel, but does not automatically bind it or create a Bangumi collection. Foreground loading ends as soon as binding succeeds; the app then reads subject details and updates `title`, `author`, `description`, `tags`, and `bangumiSubjectId` in the background. Empty selected values clear stale incorrect fields. Before updating, the app reads the latest metadata and uses its ETag or Last-Modified value as a write precondition; a concurrent conflict triggers a fresh read and merge. Valid `chapters` ranges and unknown extension fields are preserved. If the server supplies neither validator for an existing file, the unsafe overwrite is refused. Transient failures are stored locally with the library, comic, and subject identities, then retried at startup or after backoff. A changed configuration or binding invalidates the old task, and a background failure never undoes the successful progress binding.

Bangumi bindings are isolated by a normalized library identity made from the server URL, username, and remote root path. The password is deliberately excluded, so changing only a password retains bindings, while another server, account, or root cannot reuse bindings for matching relative paths. Selecting **Finished reading** refreshes both the remote collection and subject totals, then submits episode and volume progress together. Higher remote progress and higher values explicitly entered by the user are never reduced.

### Metadata-Marked Nested Layout

For a deeply nested WebDAV library, place `metadata.json` in the comic root to explicitly mark that directory as one comic:

```text
/venera_comics/
└── Category/
    └── Author/
        └── Cat's Eye/
            ├── metadata.json
            ├── cover.jpg
            ├── Chapter 01/
            │   ├── 001.jpg
            │   └── 002.jpg
            └── Chapter 02/
                └── 001.jpg
```

During WebDAV synchronization, the app recursively searches for directories containing `metadata.json` and treats each marked directory as one comic. Its direct child directories become chapters. Once a comic root is found, the app does not expose its chapters or deeper directories as separate comics. Comic IDs use paths relative to the configured WebDAV library path, so same-named comics in different categories do not overwrite one another.

In this mode, the title, author, description, and tags come from `metadata.json`, while chapter names and paths come from direct child directories. A root-level `cover.*` file is used only as the cover. Other root-level images are preserved in an `Images` chapter.

When real chapter directories and `metadata.json` page ranges coexist, the real directory layout takes precedence; page ranges are not matched to directories by position. `chapters[].start` and `chapters[].end` are used for virtual chapters only when the root contains flat images and no chapter directories, which preserves the extracted CBZ layout.

Synchronization performs bounded recursive discovery for unmarked nested libraries. A directory with ordinary root images is a comic. The WebDAV library determines comic boundaries using `metadata.json` and directory structure: `metadata.json` remains the strongest boundary with top priority, and child metadata is never bypassed by chapter naming heuristics. If a directory contains no root images and no metadata, it is recognized as a comic root when its direct leaf child directories match chapter naming conventions. When a category directly contains multiple flat single-volume comics (which are structurally isomorphic to a comic with multiple chapters), the app disambiguates them using chapter naming patterns so non-chapter subdirectories remain individual comics. In all modes, chapter directories are validated for readable comic pages: empty subdirectories or directories containing only a cover image are excluded from chapter lists and will never be selected as comic covers. If discovery encounters unrecoverable read errors or reaches safety limits (recursion depth or directory count), the sync operation fails closed and preserves the previous successful directory index without committing partial or speculative results. For complex or ambiguous hierarchies, placing `metadata.json` in each comic root is strongly recommended.

> If an older version mistakenly discovered chapter folders as individual comics and generated `metadata.json` files inside them, delete those erroneous chapter-level `metadata.json` files manually before resynchronizing; the app never deletes remote metadata files automatically.

### Extracted CBZ Enhanced Mode

A single-comic CBZ exported by VeneraPlus (or legacy VeneraNext) normally has a flat image layout after extraction:

```text
/venera_comics/
└── Cat's Eye
    ├── metadata.json
    ├── ComicInfo.xml
    ├── cover.jpg
    ├── 0001.jpg
    ├── 0002.jpg
    ├── 0003.jpg
    └── 0004.jpg
```

`metadata.json` template:

```json
{
  "title": "Cat's Eye",
  "author": "Tsukasa Hojo",
  "description": "Three sisters run a café while searching for the truth about their missing father.",
  "tags": ["Action", "Manga"],
  "chapters": [
    {"title": "Volume 01", "start": 1, "end": 2},
    {"title": "Volume 02", "start": 3, "end": 4}
  ],
  "bangumiSubjectId": 123456
}
```

Field rules:

| Field | Type | Description |
|---|---|---|
| `title` | string | Comic title; an empty string falls back to the folder name |
| `author` | string | Author; may be empty |
| `description` | string | Comic description; may be empty; Bangumi scraping reads it from subject detail `summary` |
| `tags` | string array | Comic tags; may be empty |
| `bangumiSubjectId` | positive integer or `null` | Bangumi Subject ID written by automatic scraping or manual binding |
| `chapters` | array or `null` | Chapter ranges; root images form one chapter when this is `null` or empty |
| `chapters[].title` | string | Non-empty chapter display name |
| `chapters[].start` | integer | Inclusive first page, starting at 1 |
| `chapters[].end` | integer | Inclusive last page |

Chapter ranges must be ordered, non-overlapping, non-reversed, and within the actual number of root pages. `cover.*` is not included in page numbering. Extra metadata fields are allowed for forward compatibility. Remote URLs, scripts, and local absolute paths are not read from metadata.

`metadata.json` must use UTF-8; its file name is matched case-insensitively. `ComicInfo.xml` remains in the exported CBZ for compatibility with other readers, while the VeneraPlus WebDAV library currently uses `metadata.json` as its enhanced metadata source.

When metadata is missing and Bangumi is connected, the app first attempts the conservative automatic match described above and otherwise falls back to plain directory mode. Automatic scraping does not replace an existing file that is unreadable, malformed, has invalid field types, or contains invalid chapter ranges; the comic remains visible using the parseable content or directory fallback. After an explicit Bangumi binding, a conditionally merged update can repair title, author, description, and tags when the file is still a parseable JSON object, while salvaging structurally valid `chapters`. An unparseable file is never silently replaced.

This `metadata.json` is the single-comic CBZ metadata format. It is not the comic-list format inside a `.venera-comics` batch export, and the two formats are not interchangeable.

### On-Demand ZIP/CBZ, Image-based EPUB, and PDF Reading

Place `.zip`, `.cbz`, image-based `.epub`, or `.pdf` files in an online library's configured recognition directories. Each file appears as one comic. ZIP/CBZ archives may contain images directly, a single top-level folder, or chapter folders. An optional single-comic `metadata.json` uses the fields and chapter-range rules above. EPUB page order and chapters follow the book structure and navigation; PDF pages are read and rendered in their original order.

Image directories, ZIP/CBZ files, image-based EPUB files, and PDF files can coexist. An archive inside a comic directory appears as a separate comic without turning the image comic or its chapters into categories. For example, a book folder containing `cover.png`, a ZIP with the same name, and `全1卷/` keeps the folder name as the image comic's title and `全1卷` as its chapter; the ZIP is listed separately. Page totals count actual comic pages, excluding covers and archive files from image-directory totals. Chapters not yet scanned are inspected when comic details are opened.

```text
/venera_comics/
├── Cat's Eye.cbz
│   └── Cat's Eye/
│       ├── metadata.json
│       ├── cover.jpg
│       ├── Volume 01/
│       │   ├── 001.jpg
│       │   └── 002.jpg
│       └── Volume 02/
│           └── 001.jpg
└── Another comic.zip
    ├── 0001.jpg
    └── 0002.jpg
```

ZIP/CBZ and EPUB reading fetches the archive tail and central directory as needed, then metadata and the required image entries. Covers load when needed and are cached; reading pages also reuse the image cache. The full archive does not need to be downloaded or extracted first.

#### Image-based EPUB

The app locates the OPF through `META-INF/container.xml` and expands comic pages in OPF manifest and spine reading order, **not image file-name order**. Supported spine items include direct raster images and static XHTML `img` or SVG wrapper `image` references to images within the book. Multiple images in one document follow document order, repeated image references retain their reading positions, and `linear="no"` non-body items and blank pages are skipped.

Multiple valid chapter markers from an EPUB 3 nav table of contents or EPUB 2 NCX create chapters at the corresponding spine-document boundaries. Without explicit divisions, the app provides a full-book entry instead of guessing chapters from image counts. An OPF-declared cover takes priority, and an explicit cover page is not counted again as a body page. Without a cover declaration, the first body image is used. Basic title, author, description, and tags come from OPF and can be overridden by sidecar fields.

Initial parsing reads only the required container, OPF, navigation, and XHTML/SVG control documents; reading these entries does not prefetch neighboring images. Covers and body images load when displayed and reuse the same account's request queue, range cache, and image cache. Text-based EPUBs, pages with body text, scripts or complex layouts, directly drawn SVG content, and DRM/encrypted books are unsupported. External images, `data:` images, and paths escaping the book are rejected without silently discarding text or downloading the entire archive.

#### PDF

Ordinary readable PDFs are supported, including image, text, and vector pages. The app renders page content rather than extracting embedded images. Reading order and page totals retain the PDF's original numbering: **page 1 is both the cover and body page 1**. The title defaults to the file name. Embedded PDF title and author fields are not read automatically; use a sidecar or manual Bangumi binding to supply them.

Multiple bookmarks pointing to different valid pages form chapters at their destination pages. Cover or introductory pages before the first bookmark remain included. Without usable divisions, the app provides a full-book entry. A sibling `Book.pdf.metadata.json` can override fields such as title and author or define one-based chapter ranges over the original PDF pages, including the first page. For example, a 16-page PDF can use:

```json
{
  "title": "Comic",
  "chapters": [
    {"title": "Cover and introduction", "start": 1, "end": 2},
    {"title": "Chapter 1", "start": 3, "end": 16}
  ]
}
```

Opening reads the required document structures and first-page information. Jumping to a later page may also require the PDF engine to read preceding pages' structures and dimensions. Only requested pages are rendered; the app does not render the entire book in advance. Rendering follows the local PDF import settings: three times the original dimensions, capped at a 3000-pixel longest edge, then JPEG encoding at quality 92. Reads and rendered images reuse the account request queue, range cache, and image cache.

Encrypted or password-protected PDFs are currently unsupported, and PDF JavaScript is not executed. The file service must support HTTP Range. Read or rendering failures produce an error without automatically downloading the entire PDF.

#### ZIP/CBZ Volume and Chapter Directory

Archive details always provide a clickable reading directory. Valid `chapters` page ranges from sidecar or embedded metadata take priority. Without explicit ranges, image directories inside the archive form chapters in natural order. Nested paths such as `Volume 01/Chapter 01/` are grouped by their parent path, and chapter buttons also show the comic page count.

A single explicit volume or chapter folder, such as `全1卷/` or `Volume 03/`, keeps its name. For flat images or a book-name wrapper folder, an explicit volume or chapter marker in the archive file name is used; otherwise the entry is named “Full book.” Root images alongside other chapters remain an “Images” chapter. Display groups preserve the original chapter order, image identities, and reading positions.

A flat archive containing several chapters can use explicit sidecar page ranges without repacking. For example, an 80-page comic can use the following in `Comic.cbz.metadata.json`:

```json
{
  "chapters": [
    {"title": "Chapter 01", "start": 1, "end": 32},
    {"title": "Chapter 02", "start": 33, "end": 64},
    {"title": "Extra", "start": 65, "end": 80}
  ]
}
```

Pages are numbered from 1 over the naturally ordered comic images, excluding `cover.*`. Numbered image names or a Bangumi episode total alone do not cause the app to guess chapter boundaries or split pages into fixed-size chapters.

#### Archive Sidecar Metadata

ZIP/CBZ, image-based EPUB, and PDF files can have UTF-8 JSON sidecars in the same directory. Each name is the **complete file name plus `.metadata.json`**, retaining the `.zip`, `.cbz`, `.epub`, or `.pdf` extension:

```text
/venera_comics/
├── Book.zip
├── Book.zip.metadata.json
├── Book.cbz
├── Book.cbz.metadata.json
├── Book.epub
├── Book.epub.metadata.json
├── Book.pdf
├── Book.pdf.metadata.json
└── Book/
    ├── metadata.json
    └── 001.jpg
```

`Book.zip.metadata.json`, `Book.cbz.metadata.json`, `Book.epub.metadata.json`, and `Book.pdf.metadata.json` each belong to their matching comic file. The image directory's `Book/metadata.json` continues to describe that directory separately.

The sidecar is a JSON object using the same field types as the single-comic metadata format above. It may contain only selected fields:

```json
{
  "title": "Cat's Eye",
  "bangumiSubjectId": 123456
}
```

Sidecar fields with valid types and ranges take precedence. Omitted fields continue to use the ZIP/CBZ archive's embedded `metadata.json`, the EPUB's basic OPF metadata, or valid PDF bookmark chapters, so changing only the title preserves existing authors, tags, and chapters.

`chapters` uses one-based page ranges: natural order for ZIP/CBZ, excluding separate `cover.*` images; spine order for EPUB, excluding explicit cover pages; and original PDF numbering, including the first page. The first body image still counts as a page when it is also used as the fallback cover. Ranges must be ordered, non-overlapping, and within the actual page count. Without a sidecar, existing metadata remains supported. A missing title falls back to the file name; EPUB and PDF page order still follow the spine and original page numbering, respectively.

After Bangumi is connected and automatic scraping is enabled, a ZIP/CBZ is searched by its file name without the extension when its index is first loaded on demand and neither sidecar nor embedded metadata exists. Directory discovery does not read the full archive for scraping. The conservative matching rules above still apply, and a successful match creates only the sibling sidecar file.

Manual Bangumi binding from ZIP/CBZ, image-based EPUB, or PDF comic details writes the title, author, description, tags, and subject ID to the matching sidecar, including `Book.epub.metadata.json` and `Book.pdf.metadata.json`. The app does not repack archives, rewrite PDFs, or modify embedded `metadata.json` or OPF files. New sidecars use create-only requests; updates retain ETag or Last-Modified write preconditions and preserve valid chapter ranges and unknown extension fields. Transient failures use the background retry queue and do not undo a successful progress binding. The account needs write access to the directory containing the sidecar.

#### Range Reads and Caching

Libraries on the same cloud account share an archive read queue with at most four concurrent requests and at least 150 milliseconds between request starts. The visible page takes priority over covers and preloads; an existing preload is promoted when that page becomes visible. HTTP 429 responses pause the shared queue according to `Retry-After`, or use delays of 1, 2, and 4 seconds when the header is missing or invalid. Each range read retries at most twice, and queued reads can be cancelled.

Paged reading prioritizes decoding the next two pages and the previous page in advance, with the forward page count capped by the configured preload count. The rest of the preload window only caches image files. The preload count follows comic-specific, device-specific, then global settings.

For small ZIP/CBZ and EPUB image entries, the local header and compressed payload are combined into aligned range requests, each at most 2 MiB. An account-wide 16 MiB memory range cache reuses nearby entries; larger images still use exact on-demand reads. This reduces request bursts and small transfers. Account and IP limits remain subject to the storage provider's rules.

The remote file server must actually support HTTP Range and return valid partial responses. Being able to list files or merely advertising Range support is insufficient. If the server ignores Range, returns the full file, or supplies an invalid range, the app reports an error without silently falling back to a full download. Cloud download links, proxies, and file servers reached through redirects must also satisfy this requirement.

The underlying ZIP/ZIP64 reader supports Store (uncompressed) and Deflate. Encrypted archives, split archives, and other compression methods are rejected. 7z/CB7 files cannot be read directly online; extract them to image directories on the server first. Archive backup and restore remain separate features.

End-to-end checks of image-based EPUB and PDF reading across platforms and real cloud providers have not been completed. Existing ZIP/CBZ verification applies only to the scenarios already checked and does not establish compatibility for other formats. Range compatibility depends on the actual responses from the storage service.

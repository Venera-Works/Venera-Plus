# Project Structure

Chinese version: [project_structure.zh.md](project_structure.zh.md)

This document is the English companion for the repository structure rules. The Chinese document is the default maintenance entry and contains the full boundary checklist used during structure refactors.

## General Principles

- `app_shell/` contains app shell entry points, such as authentication, home page composition, and the main navigation shell (organizing Home / Library / Explore destinations and the `LibraryPage` container).
- `app_runtime/` contains runtime assembly, such as startup initialization, update checks, debug reload, and headless command entry points.
- Business code should be grouped by feature domain under `features/<domain>/`.
- Do not add new source files under `pages/`; app-level entry points belong in `app_shell/`, and business pages belong in the corresponding feature domain.
- `foundation/` contains cross-domain application foundations, including app state, initialization protocols, navigation and startup settings contracts (`navigation_settings.dart`), async queues, Dart extensions, constants, logging, localization, file system helpers, image processing, image provider bases, reading-history metadata contracts, platform channels, and shared data infrastructure.
- `components/` contains reusable UI components. Components that only serve one business domain should live inside that feature domain.
- `network/` contains general network, cache, request, and file transfer infrastructure. `network/webdav.dart` owns shared WebDAV endpoints, authentication, client creation, and remote path rules. Business-specific download tasks and API wrappers should remain in their owning feature domain.

## Feature Domains

`lib/features` is the main home for business code. Current domains include:

- `bangumi/`: Bangumi access-token connection, subject binding, episode/volume progress upload, rating edits, and device-local retry state.
- `comic_source/`: comic source models, parsing, categories, source management, favorites mapping, tag translation, and source translation.
- `comic_storage/`: archive metadata, image file rules, and local filesystem layout detection shared by local directories, CBZ, and WebDAV.
- `comic_widgets/`: cross-domain comic display widgets such as cards, lists, and rating controls.
- `comic_details/`: comic detail page and its chapters, comments, favorites, cover, and thumbnail modules.
- `discovery/`: explore and discovery pages (unifying comic source browse and categories views), category comic lists, and ranking pages; standalone `CategoriesPage` is retired in favor of source-bound category exploration.
- `favorites/`: reading view (`ReadingFavoritesView`), local favorites, network favorites, favorite folders, and favorite actions; manages the unified reading folder (`readingFolder`) binding shared with automatic update checks.
- `follow_updates/`: background update check service and update state management; updates are integrated into reading folder automatic checks rather than a standalone page or home summary.
- `history/`: reading history, history page, image favorite models, image favorite manager, and image favorite provider (reading record entry point lives in Library).
- `image_favorites/`: image favorite page, gallery, and photo view UI (display entry point lives in Library).
- `local_comics/`: local library, downloads, and import/export tools under `import_export/` (browsing and management entry points live in Library).
- `reader/`: reader page, gestures, chapters, image loading, waterfall flow, clipboard image handling, and reader-only platform interactions.
- `search/`: search page, result page, aggregate search, and search query filters.
- `settings/`: settings pages, reader settings, reusable setting controls, and structured setting destinations (grouped by Reading & Browsing, Sources & Data, and System; personal content moved to Library, obsolete standalone setting classes cleaned up).
- `sync/`: WebDAV data sync, top bar `SyncActionButton`, app data import/export, and local comic backup/restore.
- `webdav_library/`: WebDAV comic library online reading source for remote directory image structures.

New domains should generally follow this shape:

```text
lib/features/<domain>/
  <domain>.dart
  <domain>_page.dart
  ...
test/features/<domain>/
  <domain>_test.dart
```

External modules should prefer stable feature entry files instead of importing implementation files directly. For example:
- `features/bangumi/bangumi.dart` for Bangumi models, API, service, settings, and progress UI.
- `features/comic_source/comic_source.dart` for comic source models, service, tag translation, and source management.
- `features/comic_details/comic_details.dart` for `ComicPage`.
- `features/discovery/discovery.dart` for unified `ExplorePage`, category comic list, and ranking pages.
- `features/favorites/favorites.dart` for `ReadingFavoritesView`, favorites manager, and favorite pages.
- `features/follow_updates/follow_updates.dart` for background update check services.
- `features/history/history.dart` for history manager, image favorite provider, and history page.
- `features/image_favorites/image_favorites.dart` for image favorite page and sort types.
- `features/local_comics/local_comics.dart` for local library, downloads, and import/export tools.
- `features/reader/reader.dart` for reader capabilities, loading entry, chapter comments, and chapter-completion events.
- `features/search/search.dart` for search page, result page, aggregate search, and query filters.
- `features/settings/settings.dart` for `SettingsPage` and structured setting section widgets (including `ReadingSettings`, `AppearanceSettings`, `BrowsingAndFavoritesSettings`, `SourcesAndServicesSettings`, `StorageAndSyncSettings`, `PrivacyAndSecuritySettings`, etc.).
- `features/sync/sync.dart` for `SyncActionButton` and data synchronization.
- `features/comic_storage/comic_storage.dart` for archive metadata and file rules.
- `features/webdav_library/webdav_library.dart` for the WebDAV online comic library source.

## App Shell And Runtime

`app_shell/` owns app-level page composition:

- `main_page.dart`: main navigation shell, displaying the top-right action buttons (Sync, Search, Settings) across all screen sizes.
- `home_page.dart`: home page, mounting `favorites.ReadingFavoritesView` directly with pull-to-refresh for currently reading comics.
- `auth_page.dart`: local authentication page.

Feature domains must not depend on `app_shell/`.

`app_runtime/` owns startup and runtime modes:

- `init.dart`: startup initialization and callback registration.
- `headless.dart`: headless command mode.

Feature domains must not depend on `app_runtime/`.

`app_runtime/` also owns runtime connections between feature domains. Comic-source data synchronization is registered through a callback, the WebDAV comic source is registered through a runtime source provider, and reader chapter-completion events are connected to one-way Bangumi progress uploads through a callback. The `comic_source/` and `reader/` domains must not depend directly on `sync/`, `webdav_library/`, or `bangumi/` for those integrations.

Cross-domain comic display widgets declare only the state and provider interfaces needed for rendering. Favorite state, history state, local comic covers, and favorite display preferences are injected by `app_runtime/`; `comic_widgets/` must not import those feature implementations directly.

## Tests

Tests should mirror source directories where possible:

- `lib/features/<domain>/` maps to `test/features/<domain>/`.
- `lib/foundation/` maps to `test/foundation/`.
- `lib/network/` maps to `test/network/`.
- `lib/components/` maps to `test/components/`.
- `lib/app_runtime/` maps to `test/app_runtime/`.
- `lib/routing/` maps to `test/routing/`.
- `tool/` maps to `test/tool/`.

For platform smoke and native integration testing:

- `test/integration/`: platform and native integration scenarios (executed explicitly only; entry files must not end in `_test.dart`, e.g. `platform_smoke.dart`, ensuring isolation from standard `flutter test --coverage` discovery).
- `test/driver/`: host-side integration test drivers and screenshot/artifact verification (e.g. `platform_smoke_driver.dart`, also without a `_test.dart` suffix).
- For execution instructions and driver arguments, see the quality checks section in [Build and Development](../development/build.en.md#quality-checks).

When moving source files, move or update the matching tests and fix package imports.

## Migration Checklist

Each structure migration should:

- Use `git mv` to preserve history.
- Update package and relative imports.
- Use `rg` to confirm old paths are gone.
- Run `python .github/scripts/check_structure_imports.py`.
- Update `CHANGELOG.md`.
- Run `flutter analyze`.
- Run relevant tests for the touched domains.

## Boundary Checks

`.github/scripts/check_structure_imports.py` scans Dart imports and exports under `lib/` and prevents dependency direction regressions. The main guarded rules are:

Run `python .github/scripts/check_structure_imports.py --print-feature-dependencies` to inspect the current feature-to-feature import counts. The report identifies candidates for incremental cleanup; it does not require eliminating every cross-feature dependency at once.

- Do not reintroduce source files under retired `pages/` or `utils/` paths.
- `features/`, `routing/`, `foundation/`, `network/`, `utils/`, and `components/` must not depend on `app_shell/`.
- `app_shell/`, `features/`, `routing/`, `foundation/`, `network/`, `utils/`, and `components/` must not depend on `app_runtime/`.
- `foundation/`, `network/`, `utils/`, and `components/` must not depend on `features/` or `pages/`.
- `features/comic_source/` must not depend directly on `features/history/`, `features/sync/`, or `features/webdav_library/`; shared history metadata contracts belong in `foundation/history_contract.dart`, while synchronization and runtime sources are injected by `app_runtime/`.
- `features/comic_widgets/` must not depend directly on `features/favorites/`, `features/history/`, or `features/local_comics/`; tile state, cover providers, favorite display preferences, and state listeners are injected by `app_runtime/`.
- `foundation/app.dart` must remain the `App` singleton entry and must not re-export UI extension buckets.
- Feature domains with stable entries must not be bypassed by external implementation imports.
- Retired `part` libraries in reader, settings, history, favorites, comic details, comic source, and image favorites must not be reintroduced.

For the full and authoritative checklist, use [project_structure.zh.md](project_structure.zh.md).

# Changelog

Notable changes to `codex-pet-limit-rings` are recorded here.

## Unreleased

### Added

- Hover readouts now show a subtle reset countdown beneath the remaining percentage when reset data is available.

### Changed

- Reset countdown text uses compact proportional styling so hour/minute labels stay readable without making the capsule feel busy.
- Rings now follow pet drags from the live Codex overlay window at drag-time, reducing visible lag when moving the pet.

### Fixed

- Cross-display pet drags bridge brief live-overlay coordinate gaps from the mouse-to-pet offset instead of waiting for persisted pet state to catch up.
- Live pet-window tracking now identifies Codex by its `com.openai.codex` bundle identifier, so current builds whose visible application name is `ChatGPT` remain compatible while older `Codex`-named builds continue to work.

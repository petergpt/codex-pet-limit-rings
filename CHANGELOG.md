# Changelog

Notable changes to `codex-pet-limit-rings` are recorded here.

## Unreleased

### Added

- Hover readouts now show a subtle reset countdown beneath the remaining percentage when reset data is available.

### Changed

- Reset countdown text uses compact proportional styling so hour/minute labels stay readable without making the capsule feel busy.
- Rings now follow pet drags from the live Codex overlay window at drag-time, reducing visible lag when moving the pet.
- Compact pet sizing keeps thinner rings outside the visible mascot on smaller MacBook displays.
- The companion stays resident while Codex is closed and reattaches when Codex starts again.

### Fixed

- Cross-display pet drags bridge brief live-overlay coordinate gaps from the mouse-to-pet offset instead of waiting for persisted pet state to catch up.
- Login installation explicitly clears a stale disabled-service flag before loading the LaunchAgent.

# Editable preview loop — v1.1.1

User-approved behavior: floating preview → editor → Done → same floating preview → reopen and adjust existing annotations.

## Design
- Each floating preview retains its original item, stable session ID and lazily created EditorDocument. Keep the unmodified base image, annotation IDs, crop, padding and undo history in memory.
- Open at most one editor per session. Hide only that session's preview while editing, and restore its original fixed-size panel on close.
- Done commits active text input, persists a new PNG, replaces the preview item, then closes the owning editor. A failed save keeps the editor and prior preview intact.
- Red close / Command-W retains the draft; the preview continues to show the most recent successful save. Explicit preview dismissal, preview eviction and app exit end the session. Library PNG files do not become editable project files.
- Library editing joins a matching live preview session or creates a preview for the return path. Closed/evicted panels are never resurrected by an editor callback.

## Tasks
- [x] Add regression tests for document reuse, output dimensions, undo, isolation, failed saves and duplicate editor windows.
- [x] Implement preview/session ownership and Done workflow.
- [x] Run tests, independent review, build and native capture → edit → Done → re-edit → save checks.
- [x] Package v1.1.1, publish GitHub release and update the existing public download Site.
- [x] Verify downloaded package hash and public page, document receipts.

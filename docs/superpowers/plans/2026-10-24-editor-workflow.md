# Editor workflow improvements Implementation Plan

> **For agentic workers:** Use the approved scope below; implementation and release are authorized by the user. Track completed steps here.

**Goal:** Improve editing and floating-preview continuity, verify the real workflow, and publish HS Shot 1.1.0 plus the existing public download site.

**Architecture:** Keep the SwiftUI/AppKit app and local storage. Replace only the matching visible quick-access preview after a successful edited-image library save. Extend the editor's existing annotation model for in-session text/style/endpoint changes and persist preferred style via UserDefaults.

**Tech Stack:** Swift, SwiftUI, AppKit, XCTest, static HTML/CSS/JS, GitHub Releases, Sites.

**Spec:** User approved the three recommendations in this conversation: (1) saved edits reflected in the lower-left preview, (2) revise placed text/arrows and selected annotation color/width, (3) remember color, stroke width, independent font size and padding.

## Constraints and decisions
- Preserve 210×150-point floating previews, image-only idle appearance, hover controls, original captures, and local-only processing.
- Existing main checkout is clean and is the user's explicitly authorized main/push destination. Reuse it and the existing Sites repository; no new Site.
- Editing preferences survive opening another image and relaunch. Defaults are unchanged for users without preferences. Tests use isolated defaults suites and do not alter real preferences.
- Editing text, arrow endpoints, and styles supports Undo/Redo; cancel text editing restores the previous text. A selected annotation supplies inspector values without overwriting saved defaults just from selection.
- A failed save does not change the preview. Do not resurrect dismissed previews. Multiple open editors keep their own source-to-preview relationship.
- Scope excludes persistent editable project files, autosave, zoom, OCR search, and changing capture shortcuts.
- Existing 85-second guide remains a basic-operation guide; add a clear 1.1.0 feature section/instructions and update download/version references.

## Tasks
1. [x] Editor annotations and style preferences: modify AnnotationCanvas.swift and EditorWindow.swift; add a focused preferences file if useful; regression tests for text correction/cancel, arrow endpoints, selected style Undo/Redo, font size, persistence and invalid values.
2. [x] Preview continuity: AppModel.swift / AppDelegate.swift, focused state model if useful; tests for successful saves, failed saves, repeated saves, closed previews and original preservation.
3. [x] Integrate and review: full Swift test suite, independent review, resolve findings. Bump to 1.1.0 / build 3 and build Universal app once source is final.
4. [x] Real macOS checks: permission status, area capture, fixed lower-left preview, text correction/arrow adjustment/style changes, save reflected in preview, copied/exported output, settings remembered across editor and app relaunch.
5. [x] Package exact tested binary, verify extracted contents, publish new GitHub Release and PKG/SHA256, update existing public Site, verify public downloads match, record evidence and push docs.

## Review focus
- Cancelled text edit and Undo/Redo preserve original annotation identity and contents.
- Endpoint dragging moves only the intended endpoint and retains valid geometry.
- Selecting old annotations does not change future preferred styles.
- Save failure and dismissed previews do not show a false successful replacement.
- Unusual stored settings are clamped or safely defaulted; no user library data is modified by tests.

## Progress
- 2026-10-24: Plan created from approved recommendation scope. Main/source and public Site update already authorized; no new approval needed.

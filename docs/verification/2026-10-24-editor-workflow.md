# HS Shot 1.1.0 verification

Verified on 2026-10-24 on an Apple Silicon Mac. Version 1.1.0, build 3.

## Automated checks and review

- `swift test --scratch-path .build/editor-v110-tests`: 57 tests, 0 failures (11:33 JST).
- New regressions cover placed text correction/cancellation, arrow and line endpoint changes, selected annotation styles and Undo/Redo, independent font size, isolated preferences, invalid persisted values, and repeated preview replacements after successful saves. Failed persistence does not replace the preview or selection.
- Independent editor and preview reviews found no remaining confirmed important defects. The suggested physical double-click check with the Text tool still selected passed on the release app.
- `git diff --check`, Universal release build, `lipo -archs` (arm64/x86_64), and strict ad hoc code-signature verification passed. Swift reports existing-style method-reference Sendable conversion warnings in the inspector bindings; build succeeds.

## Actual app workflow

The release app ran with an isolated test library. Existing screen-recording permission was valid; no permission reset was required. No normal user captures were included in the test media.

1. Used the actual area-selection overlay to capture a fictitious instructional image, producing a 2260×1300 PNG.
2. Opened the lower-left preview, added an arrow and text, selected the arrow and dragged only its endpoint. Checked Undo/Redo and changed the selected arrow to red with a 6 px stroke.
3. Double-clicked placed text while the Text tool was active, changed it to `ここを修正`, and committed with Enter. A subsequent text edit was cancelled with Escape, keeping the committed text and two annotations.
4. Changed font size independently (37, then 38 px), added 64 px padding, and saved twice. The corresponding visible preview showed the latest annotation and retained its 210×150-point frame. Opening that preview again loaded the edited image.
5. Quit and relaunched the app, then opened another editor. Red, 6 px stroke, 38 px font, and 64 px padding were retained. Restored the standard blue/5/35/0 values after testing.
6. Exported the edited image as a 2388×1428 PNG through the native save panel and copied/pasted it back into the isolated library. All RGBA bytes match the latest edited library image.
7. Repeated area capture on a safe portion of the download-page guide (1320×590), added a rectangle, saved, and opened the updated preview's context menu. Direct preview PNG saving produced the exact same file bytes as the edited library entry; direct preview copy followed by paste produced identical RGBA pixels.
8. Verified all 17 existing user-library files against the pre-test SHA-256 inventory and confirmed the user-library count remains 17.

Local, untracked evidence is in `.build/verification-v110/`: `result.json`, `editor-final.png`, `preview-edited.png`, `HS-Shot-1.1.0-verified.png`, and `preview-direct-save.png`. User-library inventories stay local and are not published.

## Package

`./scripts/build-pkg.sh` packaged the exact tested app without rebuilding or resigning it. Expanded payload comparison and strict code-signature verification passed. There are no installer scripts. pkgbuild emitted its existing `write: Permission denied` diagnostics while reading metadata, returned success, and the entire extracted app matched the tested bundle.

- Artifact: `HS-Shot-1.1.0.pkg`
- SHA-256: `09c7ccc2348a677d53c116c575907d741dea320edca3691706096535f6702b14`
- Target installation path: `/Applications/HS Shot.app`

This is an unsigned, unnotarized development pre-release. Intel execution and a privileged PKG installation were not performed. Saved PNGs are flattened; individual annotation editing is available while the original editor remains open.

## Publication

Publication receipts and public download verification will be added after deployment.

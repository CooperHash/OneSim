# Fold first-click no-op reproduction

Date: 2026-11-09 local time on CooperMac-mini.
AVD: Pixel_Fold_API_36, current serial emulator-5554.

1. In the original running build, real Unfold button changed cmd device_state print-state to 2 and wm size to 2208x1840. The rendered device widened.
2. Real Fold button changed state to 0 and size to 1080x2092. The rendered device became tall/narrow.
3. Quit only AndroidLab and reopen while keeping the emulator folded and running.
4. The real toolbar incorrectly displayed Fold while Android still reported state 0 / 1080x2092.
5. Click that Fold button once. Toolbar text changed to Unfold, but Android state remained 0, dimensions remained 1080x2092, and the rendered shape did not change.

Cause: isFolded was initialized to false and never synchronized on attach/refresh. The action optimistically toggled it and ignored command errors.

Host screenshot access currently returns macOS's miniature window preview. The tall/narrow versus broad screen-shape change is visible, but this does not establish precise pointer hit testing within the guest. Toolbar actions are verified through the app's accessibility buttons and Android's separate read-only status commands.

## Separate physical-panel control found during verification

A guest-only Unfold command returned state 2 and `wm size` 2208x1840, but the host hinge remained 0 degrees and the screenshot stream still returned 1080x2092. This proved that guest posture alone is insufficient visual verification.

The emulator console lists `fold` and `unfold`. An awaited `adb emu unfold` returned OK, changed the hinge to 180 degrees, and switched the screenshot stream to 2208x1840. The final implementation therefore checks the console acknowledgement before commanding and polling the guest state. It no longer races an unacknowledged physical-model gRPC call against a guest override.

## Changes

- Read actual posture on reconnect/refresh and again before choosing the toggle target.
- Resolve CLOSED/OPENED identifiers from supported state names rather than assuming identifiers across AVDs.
- Await the physical emulator command and reject missing OK, KO replies, nonzero exits, command failures and timeouts.
- Poll guest posture before publishing success. Keep the button disabled and prevent guest pointer interactions during the transition.
- Show command errors, serialize transitions, guard stale completions by session generation, and preserve in-flight fold confirmation during ordinary screenshot reconnects.
- Preserve the earlier frame/input/GPU performance changes and folded ADB compatibility path.


## Final validation

Final running process: PID 97009; UUID 46D8631E-95AE-3F39-9FCE-C85C6B900D7A matched build/AndroidLab.app/Contents/MacOS/AndroidLab. See running-final.sample.txt.

- Release test suite: 21 passed, 0 failures; package build succeeded. Existing Swift/NIO migration warnings remain.
- Real Fold button: Waiting control disabled during the operation, then Unfold. Guest state 0, hinge 0 degrees, guest size and screenshot stream both 1080x2092. Rendered window preview visibly switched to tall/narrow screen.
- Quit only the viewer while folded and reopen: initial settled button correctly reads Unfold, with the same emulator still running.
- First Unfold click after reattachment: state 2, hinge 180 degrees, guest size and screenshot stream both 2208x1840. Preview visibly widened, button changed to Fold.
- Another Fold click: state 0 and 1080x2092 again. Left the app and AVD running folded, with Unfold showing.
- Read-only SurfaceFlinger check still reports Apple M4 / Metal host graphics.

Detailed measurements: final-fold.log, final-unfold.log and final-repeat-fold.log. The host capture limitation to miniature window previews remains; those previews establish broad screen-shape switching, not fine-grained touch accuracy. Guest posture and actual stream dimensions were independently measured. The previous folded input compatibility path is unchanged.

No emulator data or user changes were deleted. No commits, pushes, or simulator data resets were performed. source-before.tar.gz preserves this task's starting sources; fold-fix.patch records the exact changes.

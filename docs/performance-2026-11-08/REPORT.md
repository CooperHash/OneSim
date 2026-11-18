# AndroidLab simulator performance, 2026-11-08

## Environment and preservation

- CooperMac-mini, Apple M4, 24 GiB RAM, macOS 27.2; existing Pixel_Fold_API_36 AVD, 2208 × 1840.
- Source directory is not a Git repository. No commits or pushes were made.
- Original source/build inputs: `source-before.tar.gz`; original executable: `AndroidLab-before`.
- Original Fold configuration: `Pixel_Fold_API_36-config-before.ini`.
- No AVD data, apps, accounts or snapshots were deleted. No screen resolution or animation-speed reduction was used.
- The only persistent AVD configuration changes are `hw.gpu.enabled=no → yes` and `hw.gpu.mode=auto → host`, for Pixel_Fold_API_36 only.

## Measured causes and changes

1. The separate emulator window read a runtime from AppModel's dictionary but did not observe that runtime. It refreshed mostly with the approximately 2.3-second device-list poll. The window now observes DeviceRuntime directly.
2. Frame rendering allocated an NSImage and redrew/scaled on CPU. It now presents CGImage through CALayer with implicit animations disabled.
3. The previous wall-clock 30 Hz filter discarded additional frames and did not bound queued main-thread presentations. A one-in-flight/one-latest mailbox now prevents obsolete-frame buildup. NIO reassembly no longer allocates byte arrays for every network fragment. Quarter-turn rotation uses Accelerate and is checked against original pixel ordering.
4. Device discovery ran synchronous adb and filesystem work on the main actor every two seconds. It now performs the scan off-main with a bounded adb timeout.
5. Mouse input previously waited until mouse-up, then spawned adb and replayed a swipe. The new input path has a separate persistent HTTP/2 stream, ordered press/move/release, move coalescing and bounded pending events. Existing adb gesture fallback is used only if the stream is unavailable before a gesture starts. Toolbar navigation stays on adb for AVD compatibility.
6. Both HTTP/2 clients installed their pipeline after TCP connect. A live input probe reproduced `ReceivedBadSettings`: the server preface was lost before its SETTINGS ACK arrived. Pipelines are now installed in the bootstrap initializer, before reads start. The repaired live probe remained connected for 25 seconds and stopped cleanly.
7. The Fold was using SwiftShader software graphics despite host CPU virtualization working. After the two backed-up GPU changes and a normal restart, SurfaceFlinger reports `Google (Apple)`, `Apple M4`, `Metal`.

## Repeatable benchmark

`scroll-benchmark.py` opens Android Settings and performs 30 alternating 350 ms swipes with a 250 ms pause. Pass the serial as its first argument (default emulator-5554; after restart emulator-5556). Both manager and separate emulator windows were open. Builds are release builds with only optional counters enabled.

Counters measure CGImage delivery and ScreenSurface assignment, not optical input-to-photon latency or compositor-presented FPS. The stream only updates when Android produces changes; idle/initialization samples are excluded. Sampling is five seconds and this was one run per configuration, not a statistical hardware benchmark.

| Configuration | Representative steady window updates/s | Largest update gap in these windows |
|---|---:|---:|
| Original UI, software GPU | 0.44, 0.44, 0.44 | 2298–2345 ms |
| Optimized UI, same software GPU | 20.60, 18.19, 17.27 | 304–327 ms |
| Optimized UI, Apple M4 GPU | 58.33, 59.97, 60.03 | 97 ms during warmup, 40–42 ms steady |

The GPU run retained native 2208×1840 RGBA frames, about 948–976 MB/s. It did not trade resolution for the result. Maximum gaps in the software benchmark include its deliberately spaced swipes.

Eight baseline adb Home command executions took 29.7–98.0 ms, median 72.2 ms. This is subprocess completion time only, not full tap-to-display latency. No equivalent end-to-end latency reduction is claimed for gRPC without optical measurement.

Before the last folded-only compatibility guard was packaged, after the viewer reload, the same 30-swipe script on Settings’ Files App info page yielded 58.19, 57.67 and 58.53 surface updates/s with 46.9–51.0 ms maximum gaps in steady samples. This is an additional functional stress check, not an identical-content comparison with the earlier main Settings run. See `final-host-*`.

Raw counts and command timing are saved in the `baseline-*`, `optimized-software-*` and `optimized-host-*` files alongside this report.

## Validation

- Initial `swift test`: 13 tests passed. Final `swift test -c release`: 14 tests passed, including a cached-frame rotation regression plus protobuf/bounds validation, all four accelerated rotations and panel mappings, loopback HTTP/2 persistent input framing, move coalescing, down/up ordering, and unsupported-RPC reporting.
- `./build.sh release`: passed. Existing Swift 6 migration/deprecated NIO API warnings remain; they are not reported as a warning-free build.
- Live benchmark, original and optimized display, normal emulator stop/start and Apple M4 renderer: verified.
- Authorized viewer reload succeeded. Final running PID 52904, UUID `7D85F9B1-5C40-38A3-B036-A969ECC5AAB7`, matched the packaged binary (`running-final.sample.txt`). Normal launch has opt-in performance logging disabled. The emulator remained `emulator-5556` and was left unfolded and running. Direct touch navigation and dragging in unfolded mode, 90-degree rotation and rotated row targeting, folded upright display and unfolded recovery were checked. Android device state changed CLOSED then OPENED.
- Further folded input testing found a backend coordinate normalization mismatch: a local center point near (540,1046) generated raw (7983,18609), matching primary 2208×1840 dimensions instead of secondary 1080×2092. Explicit TouchEvent display ID 1 reproduced the mismatch. Folded gestures therefore use the existing Android logical-coordinate adb path; unfolded gestures retain direct gRPC. This intentionally retains mouse-up replay latency while folded rather than mis-targeting user input. The fallback build passed all 14 release tests and was loaded. Its final pointer-level folded recheck was blocked by macOS exposing only a miniature window preview (`windowNotFoundAtPosition`); toolbar Fold/Unfold/Home remained operable. Do not claim that last folded pointer check passed. Earlier adb logical-coordinate swipes did operate correctly on the folded screen.

## Rollback

Preserve any newer edits before restoring from `source-before.tar.gz`. The old executable and original Fold configuration are included for an explicit rollback. AVD user data must not be removed. GPU changes can be reverted by restoring just the two `hw.gpu` values and restarting the emulator normally.

## Final artifacts

- Runnable app: `build/AndroidLab.app`.
- Final release tests: `final-release-tests.log` (14 passed, 2026-11-08 23:51 local).
- Final package: `final-package.log`.
- Additional frame metrics: `final-host-metrics.log` and `final-host-timing.json`.
- Folded backend diagnosis: `folded-input-validation.txt`.

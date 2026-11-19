import Foundation
import IOSurface
import ObjectiveC

/// Registers SimulatorKit framebuffer callbacks on every `com.apple.framebuffer.display`
/// descriptor of a SimDevice and forwards the visible IOSurface. Foldable simulators can
/// expose both folded and unfolded panels at once, with the inactive panel black.
///
/// One instance == one device. Caller owns the surface and may use it as `CALayer.contents`
/// to render at the device's native refresh rate with zero pixel copies.
///
/// Derived from baguette (Apache 2.0).
final class SimulatorFramebuffer: @unchecked Sendable {
  enum FramebufferError: Error, CustomStringConvertible {
    case ioUnavailable
    case noFramebuffer
    case callbackUnavailable

    var description: String {
      switch self {
      case .ioUnavailable: "SimDevice has no `io` (SimDeviceIOClient)."
      case .noFramebuffer: "No `com.apple.framebuffer.display` port on the device."
      case .callbackUnavailable: "registerScreenCallbacksWithUUID:… selector missing."
      }
    }
  }

  private let device: NSObject
  private let onFrame: @Sendable (IOSurface) -> Void
  private let onActiveSurface: (@Sendable (IOSurface) -> Void)?
  private let queue = DispatchQueue(label: "SimulatorView.framebuffer", qos: .userInteractive)

  private var ioClient: NSObject?
  private var descriptors: [NSObject] = []
  private var callbackUUIDs: [ObjectIdentifier: NSUUID] = [:]
  private var preferredInnerDisplay: Bool?
  private var selectedSurface: IOSurfaceID?
  private var panelWakeDeadline: DispatchTime?
  private var panelWakeRetry: DispatchWorkItem?

  init(
    device: NSObject,
    onFrame: @escaping @Sendable (IOSurface) -> Void,
    onActiveSurface: (@Sendable (IOSurface) -> Void)? = nil
  ) {
    self.device = device
    self.onFrame = onFrame
    self.onActiveSurface = onActiveSurface
  }

  func setPreferredInnerDisplay(_ preferInner: Bool?) {
    queue.async { [weak self] in
      guard let self else { return }
      if self.preferredInnerDisplay != preferInner {
        self.preferredInnerDisplay = preferInner
        self.selectedSurface = nil
        self.panelWakeRetry?.cancel()
        self.panelWakeRetry = nil
        self.panelWakeDeadline = preferInner == nil ? nil : .now() + .seconds(2)
        self.captureLatest()
      }
    }
  }

  func start() throws {
    guard
      let io = device.perform(NSSelectorFromString("io"))?
        .takeUnretainedValue() as? NSObject
    else {
      throw FramebufferError.ioUnavailable
    }
    ioClient = io
    try wireFramebuffer()
  }

  func stop() {
    queue.sync { stopOnCaptureQueue() }
  }

  private func stopOnCaptureQueue() {
    panelWakeRetry?.cancel()
    panelWakeRetry = nil
    panelWakeDeadline = nil
    let unregSel = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
    for desc in descriptors {
      if let uuid = callbackUUIDs[ObjectIdentifier(desc)], desc.responds(to: unregSel) {
        desc.perform(unregSel, with: uuid)
      }
    }
    descriptors.removeAll()
    callbackUUIDs.removeAll()
    ioClient = nil
  }

  deinit {
    // Best-effort cleanup; deinit can't await main-actor isolation so we just unhook.
    let unregSel = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
    for desc in descriptors {
      if let uuid = callbackUUIDs[ObjectIdentifier(desc)], desc.responds(to: unregSel) {
        desc.perform(unregSel, with: uuid)
      }
    }
  }

  // MARK: - private

  private func wireFramebuffer() throws {
    guard let io = ioClient else { throw FramebufferError.ioUnavailable }
    io.perform(NSSelectorFromString("updateIOPorts"))

    guard let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] else {
      throw FramebufferError.noFramebuffer
    }

    let pidSel = NSSelectorFromString("portIdentifier")
    let descSel = NSSelectorFromString("descriptor")
    let surfSel = NSSelectorFromString("framebufferSurface")

    var candidates: [NSObject] = []
    for port in ports where port.responds(to: pidSel) {
      guard let pid = port.perform(pidSel)?.takeUnretainedValue(),
        "\(pid)" == "com.apple.framebuffer.display",
        port.responds(to: descSel),
        let desc = port.perform(descSel)?.takeUnretainedValue() as? NSObject,
        desc.responds(to: surfSel)
      else { continue }
      candidates.append(desc)
    }
    guard !candidates.isEmpty else { throw FramebufferError.noFramebuffer }
    descriptors = candidates
    for desc in candidates {
      try registerCallbacks(on: desc)
    }
    queue.async { [weak self] in self?.captureLatest() }
  }

  private func registerCallbacks(on desc: NSObject) throws {
    let regSel = NSSelectorFromString(
      "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:"
        + "surfacesChangedCallback:propertiesChangedCallback:"
    )
    guard desc.responds(to: regSel) else { throw FramebufferError.callbackUnavailable }

    let uuid = NSUUID()
    callbackUUIDs[ObjectIdentifier(desc)] = uuid

    // Capture the serial queue locally so the SimulatorKit-side block doesn't have to
    // weakly re-resolve `self.queue` (which Swift 6 strict concurrency flags as a
    // captured-var-of-self in concurrently-executing code).
    let queue = self.queue
    let frame: @convention(block) () -> Void = { [weak self] in
      queue.async { [weak self] in self?.captureLatest() }
    }
    let surfaces: @convention(block) () -> Void = { [weak self] in
      queue.async { [weak self] in self?.captureLatest() }
    }
    let props: @convention(block) () -> Void = { [weak self] in
      queue.async { [weak self] in self?.captureLatest() }
    }

    guard let imp = class_getMethodImplementation(type(of: desc), regSel) else {
      throw FramebufferError.callbackUnavailable
    }
    typealias Fn =
      @convention(c) (
        AnyObject, Selector, AnyObject, AnyObject, AnyObject, AnyObject, AnyObject
      ) -> Void
    unsafeBitCast(imp, to: Fn.self)(
      desc, regSel,
      uuid, queue as AnyObject,
      frame as AnyObject, surfaces as AnyObject, props as AnyObject
    )
  }

  private func captureLatest() {
    let surfSel = NSSelectorFromString("framebufferSurface")
    let surfaces: [IOSurface] = descriptors.compactMap { desc in
      guard let object = desc.perform(surfSel)?.takeUnretainedValue() else { return nil }
      return unsafeDowncast(object, to: IOSurface.self)
    }
    if surfaces.count == 1 {
      onActiveSurface?(surfaces[0])
      onFrame(surfaces[0])
      return
    }
    // After a preferred panel has visibly woken, the runtime performs further
    // selection. Avoid a memory lock on every ordinary frame for that panel.
    if let selectedSurface,
       let visible = surfaces.first(where: { IOSurfaceGetID($0) == selectedSurface }) {
      onActiveSurface?(visible)
      onFrame(visible)
      return
    }
    var preferredCandidate: IOSurface?
    var best: IOSurface?
    var bestActivity = -1
    var bestArea = 0
    for surf in surfaces {
      let area = IOSurfaceGetWidth(surf) * IOSurfaceGetHeight(surf)
      let activity = visiblePixelScore(surf)
      if activity > 0 {
        onActiveSurface?(surf)
        if let preferInner = preferredInnerDisplay, (area >= 4_000_000) == preferInner {
          preferredCandidate = surf
        }
      }
      if activity > 0, activity > bestActivity || (activity == bestActivity && area > bestArea) {
        best = surf
        bestActivity = activity
        bestArea = area
      }
    }
    if let preferredCandidate {
      selectedSurface = IOSurfaceGetID(preferredCandidate)
      panelWakeRetry?.cancel()
      panelWakeRetry = nil
      panelWakeDeadline = nil
      onFrame(preferredCandidate)
    } else {
      if let best { onFrame(best) }
      retryWhilePanelWakes()
    }
  }

  // Backlight changes can update the same IOSurface without a swap callback.
  private func retryWhilePanelWakes() {
    guard let deadline = panelWakeDeadline, DispatchTime.now() < deadline,
          panelWakeRetry == nil else { return }
    let retry = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.panelWakeRetry = nil
      self.captureLatest()
    }
    panelWakeRetry = retry
    queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: retry)
  }

  /// A sparse CPU read distinguishes the lit panel from the black inactive panel.
  /// Geometry alone picks the unfolded panel even while a Duo is folded.
  private func visiblePixelScore(_ surface: IOSurface) -> Int {
    guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return 0 }
    defer { IOSurfaceUnlock(surface, .readOnly, nil) }
    let base = IOSurfaceGetBaseAddress(surface)
    let width = IOSurfaceGetWidth(surface)
    let height = IOSurfaceGetHeight(surface)
    let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    var score = 0
    for row in 1...9 {
      let y = height * row / 10
      for column in 1...9 {
        let x = width * column / 10
        let offset = y * bytesPerRow + x * 4
        score += Int(max(bytes[offset], bytes[offset + 1], bytes[offset + 2]))
      }
    }
    return score
  }
}

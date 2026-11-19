import Foundation
import IOSurface

/// Receives live surfaces without creating a window or a Metal drawable.
@MainActor
public final class SimulatorFrameFeed {
  public let udid: String
  private var framebuffer: SimulatorFramebuffer?
  private let runtime: CoreSimulatorRuntime
  private let resolver: SimDeviceResolver
  public private(set) var surface: IOSurface?
  private var activeSurfaces: [Bool: IOSurface] = [:]
  private var observers: [UUID: @MainActor (IOSurface) -> Void] = [:]
  private let input: HIDInput
  private var inputScreenID: UInt32?
  private var preparingInput = false

  public init(udid: String) throws {
    self.udid = udid
    let runtime = CoreSimulatorRuntime()
    try runtime.load()
    let resolver = SimDeviceResolver(runtime: runtime)
    guard let device = resolver.resolve(udid: udid) else {
      throw SimKitError.deviceNotFound(udid: udid)
    }
    self.runtime = runtime
    self.resolver = resolver
    input = HIDInput(udid: udid, resolver: resolver, runtime: runtime)
    let framebuffer = SimulatorFramebuffer(device: device, onFrame: { [weak self] surface in
      Task { @MainActor in
        guard let self, self.framebuffer != nil else { return }
        self.surface = surface
      }
    }, onActiveSurface: { [weak self] surface in
      Task { @MainActor in self?.receivedActiveSurface(surface) }
    })
    do {
      try framebuffer.start()
    } catch let error as SimulatorFramebuffer.FramebufferError {
      switch error {
      case .ioUnavailable: throw SimKitError.ioUnavailable
      case .noFramebuffer: throw SimKitError.noFramebuffer
      case .callbackUnavailable: throw SimKitError.callbackRegistrationFailed
      }
    }
    self.framebuffer = framebuffer
  }

  func makeInput() -> HIDInput {
    HIDInput(udid: udid, resolver: resolver, runtime: runtime)
  }

  func observeActiveSurfaces(_ observer: @escaping @MainActor (IOSurface) -> Void) -> UUID {
    let id = UUID()
    observers[id] = observer
    activeSurfaces.values.forEach(observer)
    return id
  }

  func removeObserver(_ id: UUID) {
    observers[id] = nil
  }

  private func receivedActiveSurface(_ surface: IOSurface) {
    guard framebuffer != nil else { return }
    let inner = IOSurfaceGetWidth(surface) * IOSurfaceGetHeight(surface) >= 4_000_000
    activeSurfaces[inner] = surface
    observers.values.forEach { $0(surface) }
  }

  public func preferInnerDisplay(_ inner: Bool) {
    framebuffer?.setPreferredInnerDisplay(inner)
  }

  public func prepareInput() {
    guard !preparingInput else { return }
    preparingInput = true
    let input = input
    Task.detached(priority: .userInitiated) { input.prepareConnection() }
  }

  /// HID on the raw panel is independent of whether a native simulator canvas is on screen.
  public func sendTouch(_ phase: GesturePhase, normalized point: CGPoint, screenID: UInt32) -> Bool {
    if inputScreenID != screenID {
      input.targetPanel(screenId: screenID)
      inputScreenID = screenID
    }
    return input.touch1(phase: phase, at: SimulatorPoint(x: point.x, y: point.y),
                        size: SimulatorSize(width: 1, height: 1), edge: nil)
  }

  public func press(_ button: DeviceButton) -> Bool {
    input.button(button, duration: 0)
  }

  public func typeText(_ text: String) {
    for character in text {
      guard let pair = KeyboardKey.decompose(character: character) else { continue }
      _ = input.key(pair.key, modifiers: pair.modifiers, duration: 0)
    }
  }

  public func stop() {
    framebuffer?.stop()
    framebuffer = nil
    surface = nil
    activeSurfaces.removeAll()
  }
}

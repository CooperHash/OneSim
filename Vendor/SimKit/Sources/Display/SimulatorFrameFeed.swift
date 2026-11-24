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

  private var triedHardwareKeyboard = false

  /// Use the same host keyboard type that SimulatorKit reports for this Mac.
  public func connectHardwareKeyboard() {
    guard !triedHardwareKeyboard else { return }
    triedHardwareKeyboard = true
    guard let device = resolver.resolve(udid: udid),
          let typeSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IndigoHIDGetKeyboardType") else { return }
    let selector = NSSelectorFromString("setHardwareKeyboardEnabled:keyboardType:error:")
    guard device.responds(to: selector), let method = device.method(for: selector) else { return }
    typealias SetKeyboard = @convention(c) (NSObject, Selector, Bool, UInt8, UnsafeMutablePointer<NSError?>?) -> Bool
    let hostType = unsafeBitCast(typeSymbol, to: (@convention(c) () -> UInt8).self)()
    let connected = unsafeBitCast(method, to: SetKeyboard.self)(device, selector, true, hostType, nil)
    // SimLab interprets the host input method before emitting US-layout HID usages.
    // A guest IME would otherwise compose the same keystrokes a second time.
    let language = NSSelectorFromString("setKeyboardLanguage:error:")
    if connected, device.responds(to: language), let select = device.method(for: language) {
      typealias SetLanguage = @convention(c) (NSObject, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> Bool
      _ = unsafeBitCast(select, to: SetLanguage.self)(device, language, "en_US", nil)
    }
  }

  func makeInput() -> HIDInput {
    HIDInput(udid: udid, resolver: resolver, runtime: runtime)
  }

  public func observeActiveSurfaces(_ observer: @escaping @MainActor (IOSurface) -> Void) -> UUID {
    let id = UUID()
    observers[id] = observer
    activeSurfaces.values.forEach(observer)
    return id
  }

  public func removeObserver(_ id: UUID) {
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

import Foundation
import IOSurface

/// Receives live surfaces without creating a window or a Metal drawable.
@MainActor
public final class SimulatorFrameFeed {
  private let framebuffer: SimulatorFramebuffer

  public init(udid: String, receive: @escaping @MainActor (IOSurface) -> Void) throws {
    let runtime = CoreSimulatorRuntime()
    try runtime.load()
    guard let device = SimDeviceResolver(runtime: runtime).resolve(udid: udid) else {
      throw SimKitError.deviceNotFound(udid: udid)
    }
    framebuffer = SimulatorFramebuffer(device: device, onFrame: { surface in
      Task { @MainActor in receive(surface) }
    })
    try framebuffer.start()
  }

  public func preferInnerDisplay(_ inner: Bool) {
    framebuffer.setPreferredInnerDisplay(inner)
  }

  public func stop() {
    framebuffer.stop()
  }
}

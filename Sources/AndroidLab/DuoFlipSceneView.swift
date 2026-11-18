import AppKit
import IOSurface
import Metal
import QuartzCore
import SceneKit
import SwiftUI
import simd

/// Active display face selected by the Duo hinge angle with safearea.info's
/// 45° / 55° hysteresis deadband so the phone does not flicker near the threshold.
enum DuoActiveDisplay: Equatable {
    case outer
    case inner

    var title: String { self == .outer ? "Outer display" : "Inner display" }

    static func resolve(angleDegrees: Double, current: DuoActiveDisplay) -> DuoActiveDisplay {
        if angleDegrees <= 45 { return .outer }
        if angleDegrees >= 55 { return .inner }
        return current
    }
}

/// Critically damped spring (omega = 8) from safearea.info (`Hc`) that drives
/// hinge angle transitions between pose presets.
struct DuoHingeSpring {
    static let omega: Double = 8.0
    var angle: Double
    var velocity: Double = 0
    var target: Double

    init(angle: Double = 180) {
        self.angle = angle
        self.target = angle
    }

    mutating func snap(_ value: Double) {
        let clamped = max(0, min(180, value))
        angle = clamped
        target = clamped
        velocity = 0
    }

    /// Advances the spring by `dt` seconds. Returns `true` when settled at `target`.
    mutating func step(dt: Double) -> Bool {
        let clampedDt = max(0, min(0.05, dt))
        let n = Self.omega * clampedDt
        let decay = 1.0 / (1.0 + n + 0.48 * n * n + 0.235 * n * n * n)
        let diff = angle - target
        let a = (velocity + Self.omega * diff) * clampedDt
        velocity = (velocity - Self.omega * a) * decay
        var next = target + (diff + a) * decay
        if (target > angle) != (target >= next) {
            next = target
            velocity = 0
        }
        angle = max(0, min(180, next))
        if abs(angle - target) < 0.05 && abs(velocity) < 0.5 {
            angle = target
            velocity = 0
            return true
        }
        return false
    }

    var isSettled: Bool {
        abs(angle - target) < 0.05 && abs(velocity) < 0.5
    }
}

/// 4D quaternion spring (omega = 2 / 0.18 ≈ 11.11) from safearea.info (`wl`)
/// that smoothly flips the chassis between inner/outer faces and physical rotations.
struct DuoQuaternionSpring {
    static let omega: Float = 2.0 / 0.18
    var current: simd_quatf
    var velocity: SIMD4<Float> = .zero

    init(initial: simd_quatf = Self.targetQuaternion(display: .inner, orientation: .portrait)) {
        self.current = initial
    }

    mutating func snap(_ target: simd_quatf) {
        current = simd_normalize(target)
        velocity = .zero
    }

    /// Advances `current` toward `target` by `dt` seconds.
    /// Returns `true` while still moving, or `false` once settled.
    mutating func step(target: simd_quatf, dt: Double) -> Bool {
        let clampedDt = Float(max(0, min(0.05, dt)))
        let dotProd = simd_dot(current.vector, target.vector)
        let angleDiff = 2.0 * acos(min(1.0, abs(dotProd)))
        if angleDiff <= 0.002 && simd_length(velocity) <= 0.02 {
            snap(target)
            return false
        }
        guard clampedDt > 0 else { return true }
        let tVec = dotProd < 0 ? -target.vector : target.vector
        let cVec = current.vector
        let s = Self.omega * clampedDt
        let decay = 1.0 / (1.0 + s + 0.48 * s * s + 0.235 * s * s * s)
        var nextVec = SIMD4<Float>.zero
        for i in 0..<4 {
            let diff = cVec[i] - tVec[i]
            let a = (velocity[i] + Self.omega * diff) * clampedDt
            velocity[i] = (velocity[i] - Self.omega * a) * decay
            let candidate = tVec[i] + (diff + a) * decay
            if (tVec[i] > cVec[i]) == (candidate <= tVec[i]) {
                nextVec[i] = candidate
            } else {
                velocity[i] = 0
                nextVec[i] = tVec[i]
            }
        }
        if simd_length(nextVec) > 1e-6 {
            current = simd_quatf(vector: simd_normalize(nextVec))
        }
        return true
    }

    static func targetQuaternion(display: DuoActiveDisplay, orientation: IOSDeviceOrientation) -> simd_quatf {
        let s = Float(0.5.squareRoot())
        // Matches safearea.info's `Al(screen, orientation)`:
        // Because `modelNode` is counter-rotated around Z by `-(180 - angle) / 2` so both wings
        // fold symmetrically around the stationary hinge spine, `qOuter` is only a +90° Y rotation
        // (`(0.5, 0.5, -0.5, 0.5)`) away from `qInner` (`(s, 0, 0, s)`). At <=45°, this turns the
        // left outer cover screen directly toward the camera in 3D perspective.
        let base = display == .inner
            ? simd_quatf(ix: s, iy: 0, iz: 0, r: s)
            : simd_quatf(ix: 0.5, iy: 0.5, iz: -0.5, r: 0.5)
        let zAngle = -Float(orientation.clockwiseQuarterTurns) * (.pi / 2)
        let rotZ = simd_quatf(angle: zAngle, axis: SIMD3<Float>(0, 0, 1))
        return simd_normalize(simd_mul(rotZ, base))
    }
}

/// Renders Xcode's V68 Duo model using safearea.info's symmetric hinge kinematics,
/// dual critically-damped springs, studio PBR lighting, and zero-copy 60fps IOSurface
/// Metal screen textures.
@MainActor
final class DuoFlipSceneView: SCNView {
    private static let modelRelativePath = "SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/CoreDevicePopDeviceKitExtension.devicekitplugin/Contents/Resources/V68.usdz"
    private static let fovDegrees: CGFloat = 24.0
    private static let screenPlaneZ: CGFloat = 0.26
    private static let pointsPerNativePixel: CGFloat = 678.0 / 2622.0
    /// 1 USDZ unit in V68.usdz equals 180.86 native simulator pixels (~46.767 workspace points).
    private static let pointsPerModelUnit: CGFloat = 180.86 * pointsPerNativePixel
    /// Vertical offset in `offsetNode` (`g` in safearea.info) as the hinge closes so the
    /// outer screen centers identically to the 2D view at 0°.
    private static let closedCenterShiftY: Double = -4.070

    private struct BoneTrack {
        let node: SCNNode
        let positions: [SIMD3<Float>]
        let orientations: [simd_quatf]
    }

    private var rigNode: SCNNode?
    private var offsetNode: SCNNode?
    private var modelNode: SCNNode?
    private var cameraNode: SCNNode?
    private var leftWingBone: SCNNode?
    private var rightWingBone: SCNNode?
    private var leftWingBindTransform = matrix_identity_float4x4
    private var rightWingBindTransform = matrix_identity_float4x4
    private var boneTracks: [BoneTrack] = []
    private var innerMaterial: SCNMaterial?
    private var outerMaterial: SCNMaterial?
    private var lastInnerSurfaceID: IOSurfaceID?
    private var lastOuterSurfaceID: IOSurfaceID?
    private var lastInnerIsPortraitMounted: Bool?

    private var hingeSpring = DuoHingeSpring(angle: 180)
    private var orientationSpring = DuoQuaternionSpring()
    private var activeDisplay: DuoActiveDisplay = .inner
    private var targetOrientation: IOSDeviceOrientation = .portrait
    private var hasInitializedPose = false
    private var animationTimer: Timer?
    private var lastTickTime: CFTimeInterval = 0

    var onSettled: (@MainActor (Double) -> Void)?

    override init(frame frameRect: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frameRect, options: options)
        backgroundColor = .clear
        allowsCameraControl = false
        antialiasingMode = .multisampling4X
        configureModel()
        idle()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureModel()
        idle()
    }

    deinit { animationTimer?.invalidate() }

    // Always pass pointer events through to DuoPointerView.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateCameraDistance()
        if newSize.width > 1 && newSize.height > 1 {
            applyCurrentPose()
        }
    }

    override func layout() {
        super.layout()
        updateCameraDistance()
    }

    var canAnimate: Bool { modelNode != nil && !boneTracks.isEmpty }

    var isAnimating: Bool { animationTimer != nil }

    var currentAngleDegrees: Double { hingeSpring.angle }

    /// Binds the incoming IOSurface directly as a zero-copy sRGB Metal texture on either
    /// the inner or outer screen material.
    func receive(surface: IOSurface) {
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0 else { return }
        let isInner = width * height >= 4_000_000
        let surfaceID = IOSurfaceGetID(surface)
        var didBindNewTexture = false

        if isInner {
            let portraitMounted = height > width
            if lastInnerSurfaceID != surfaceID || lastInnerIsPortraitMounted != portraitMounted {
                guard let mtlDevice = device ?? MTLCreateSystemDefaultDevice(),
                      let texture = Self.makeTexture(from: surface, width: width, height: height, device: mtlDevice) else { return }
                innerMaterial?.diffuse.contents = texture
                innerMaterial?.diffuse.contentsTransform = portraitMounted ? Self.quarterTurnClockwiseUVTransform : SCNMatrix4Identity
                lastInnerSurfaceID = surfaceID
                lastInnerIsPortraitMounted = portraitMounted
                didBindNewTexture = true
            }
        } else {
            if lastOuterSurfaceID != surfaceID {
                guard let mtlDevice = device ?? MTLCreateSystemDefaultDevice(),
                      let texture = Self.makeTexture(from: surface, width: width, height: height, device: mtlDevice) else { return }
                outerMaterial?.diffuse.contents = texture
                outerMaterial?.diffuse.contentsTransform = SCNMatrix4Identity
                lastOuterSurfaceID = surfaceID
                didBindNewTexture = true
            }
        }

        // Pre-warm the SceneKit drawable whenever a new surface ID arrives or while visible
        // so the very first fold frame already has compiled shaders and up-to-date textures.
        if didBindNewTexture || isAnimating || (hingeSpring.angle > 0.5 && hingeSpring.angle < 179.5) {
            setNeedsDisplay(bounds)
        }
    }

    /// Synchronizes the starting posture and pre-renders a resting frame so there is
    /// zero visual mismatch on the first frame of a fold/unfold transition.
    func syncPoseIfIdle(angleDegrees: Double, orientation: IOSDeviceOrientation) {
        guard !isAnimating else { return }
        let clamped = max(0, min(180, angleDegrees))
        hingeSpring.snap(clamped)
        targetOrientation = orientation
        let quat = DuoQuaternionSpring.targetQuaternion(display: activeDisplay, orientation: orientation)
        orientationSpring.snap(quat)
        hasInitializedPose = true
        updateCameraDistance()
        applyCurrentPose()
    }

    /// Animates (or interactively scrubs) the 3D Duo to `targetAngle` and `orientation`.
    @discardableResult
    func transitionTo(
        angleDegrees targetAngle: Double,
        orientation: IOSDeviceOrientation,
        interactive: Bool = false
    ) -> Bool {
        guard canAnimate else { return false }
        let clamped = max(0, min(180, targetAngle))
        if !hasInitializedPose {
            syncPoseIfIdle(angleDegrees: clamped, orientation: orientation)
        }
        targetOrientation = orientation
        if interactive {
            hingeSpring.snap(clamped)
        } else {
            hingeSpring.target = clamped
        }
        updateCameraDistance()
        applyCurrentPose()
        startAnimationLoopIfNeeded()
        return true
    }

    /// Legacy entrypoint used by simple fold/unfold toggles.
    func start(folding: Bool, orientation: IOSDeviceOrientation = .portrait) -> Bool {
        syncPoseIfIdle(angleDegrees: folding ? 180 : 0, orientation: orientation)
        return transitionTo(angleDegrees: folding ? 0 : 180, orientation: orientation, interactive: false)
    }

    func finish() {
        stopAnimationLoop()
        applyCurrentPose()
    }

    func updateDisplay(_ display: DuoActiveDisplay, visible: Bool) {
        if rendersContinuously != visible {
            rendersContinuously = visible
            isPlaying = visible
        }
        guard display != activeDisplay else { return }
        activeDisplay = display
        if visible {
            startAnimationLoopIfNeeded()
        } else {
            syncPoseIfIdle(angleDegrees: hingeSpring.angle, orientation: targetOrientation)
        }
    }

    private static let innerPlaneY: Float = 0.2493645
    private static let innerHalfWidth: Float = 7.898555
    private static let innerHalfHeight: Float = 5.541209
    private static let outerPlaneY: Float = -0.275370
    private static let outerMinX: Float = -7.972508
    private static let outerMaxX: Float = -0.23393707
    private static let outerHalfHeight: Float = 5.6149645

    /// The 3D screen is perspective-transformed and split at the hinge. Because SceneKit's
    /// CPU `SCNView.hitTest` ignores `SCNSkinner` bone deformations, intersect the camera ray
    /// analytically against the live left/right wing bone planes in bind-pose space.
    func digitizerPoint(at windowPoint: CGPoint, for display: DuoActiveDisplay) -> CGPoint? {
        let local = convert(windowPoint, from: nil)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let point = isFlipped ? CGPoint(x: local.x, y: bounds.maxY - local.y) : local
        guard bounds.contains(point) else { return nil }

        let nearPoint = SIMD3<Float>(unprojectPoint(SCNVector3(point.x, point.y, 0)))
        let farPoint = SIMD3<Float>(unprojectPoint(SCNVector3(point.x, point.y, 1)))
        let rayDir = simd_normalize(farPoint - nearPoint)
        guard rayDir.x.isFinite, rayDir.y.isFinite, rayDir.z.isFinite else { return nil }

        switch display {
        case .inner:
            guard let leftWingBone, let rightWingBone else { return nil }
            var bestT: Float = .infinity
            var bestHit = SIMD3<Float>.zero
            let wings: [(isLeft: Bool, bone: SCNNode, bind: simd_float4x4)] = [
                (true, leftWingBone, leftWingBindTransform),
                (false, rightWingBone, rightWingBindTransform),
            ]
            for wing in wings {
                let worldToBind = wing.bind * simd_inverse(wing.bone.simdWorldTransform)
                let o4 = worldToBind * SIMD4<Float>(nearPoint.x, nearPoint.y, nearPoint.z, 1)
                let d4 = worldToBind * SIMD4<Float>(rayDir.x, rayDir.y, rayDir.z, 0)
                guard abs(d4.y) > 1e-6 else { continue }
                let t = (Self.innerPlaneY - o4.y) / d4.y
                guard t > 0, t < bestT else { continue }
                let hit = SIMD3<Float>(o4.x + t * d4.x, Self.innerPlaneY, o4.z + t * d4.z)
                let inX = wing.isLeft
                    ? (hit.x >= -Self.innerHalfWidth && hit.x <= 0.05)
                    : (hit.x >= -0.05 && hit.x <= Self.innerHalfWidth)
                let inZ = hit.z >= -Self.innerHalfHeight && hit.z <= Self.innerHalfHeight
                if inX && inZ {
                    bestT = t
                    bestHit = hit
                }
            }
            guard bestT < .infinity else { return nil }
            let u = CGFloat((bestHit.x + Self.innerHalfWidth) / (2 * Self.innerHalfWidth))
            let v = CGFloat((bestHit.z + Self.innerHalfHeight) / (2 * Self.innerHalfHeight))
            let clampedU = min(1, max(0, u))
            let clampedV = min(1, max(0, v))
            if lastInnerIsPortraitMounted == false {
                return CGPoint(x: clampedU, y: clampedV)
            }
            return CGPoint(x: clampedV, y: 1 - clampedU)

        case .outer:
            guard let leftWingBone else { return nil }
            let worldToBind = leftWingBindTransform * simd_inverse(leftWingBone.simdWorldTransform)
            let o4 = worldToBind * SIMD4<Float>(nearPoint.x, nearPoint.y, nearPoint.z, 1)
            let d4 = worldToBind * SIMD4<Float>(rayDir.x, rayDir.y, rayDir.z, 0)
            guard abs(d4.y) > 1e-6 else { return nil }
            let t = (Self.outerPlaneY - o4.y) / d4.y
            guard t > 0 else { return nil }
            let hitX = o4.x + t * d4.x
            let hitZ = o4.z + t * d4.z
            guard hitX >= Self.outerMinX, hitX <= Self.outerMaxX,
                  hitZ >= -Self.outerHalfHeight, hitZ <= Self.outerHalfHeight else { return nil }
            let u = CGFloat((Self.outerMaxX - hitX) / (Self.outerMaxX - Self.outerMinX))
            let v = CGFloat((hitZ + Self.outerHalfHeight) / (2 * Self.outerHalfHeight))
            return CGPoint(x: min(1, max(0, u)), y: min(1, max(0, v)))
        }
    }

    private func idle() {
        stopAnimationLoop()
        rendersContinuously = false
        isPlaying = false
    }

    private func startAnimationLoopIfNeeded() {
        lastTickTime = CACurrentMediaTime()
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stepAnimationFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimationLoop() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func stepAnimationFrame() {
        let now = CACurrentMediaTime()
        let dt = max(0, min(0.05, now - lastTickTime))
        lastTickTime = now

        let hingeSettled = hingeSpring.step(dt: dt)
        let targetQuat = DuoQuaternionSpring.targetQuaternion(display: activeDisplay, orientation: targetOrientation)
        let orientationMoving = orientationSpring.step(target: targetQuat, dt: dt)

        applyCurrentPose()

        if hingeSettled && !orientationMoving {
            stopAnimationLoop()
            onSettled?(hingeSpring.angle)
        }
    }

    private func applyCurrentPose() {
        guard let rigNode, let offsetNode, let modelNode else { return }
        let clamped = max(0, min(180, hingeSpring.angle))
        let frameFloat = (180.0 - clamped) / 180.0 * 120.0
        let i0 = min(120, max(0, Int(floor(frameFloat))))
        let i1 = min(120, i0 + 1)
        let t = Float(frameFloat - Double(i0))

        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        for track in boneTracks {
            track.node.simdPosition = simd_mix(track.positions[i0], track.positions[i1], SIMD3<Float>(repeating: t))
            track.node.simdOrientation = simd_slerp(track.orientations[i0], track.orientations[i1], t)
        }
        // Counter-rotate `modelNode` around Z by `-(180 - angle) / 2` so the hinge spine
        // stays stationary and both wings fold symmetrically toward the viewer.
        let halfFoldRad = -Float((180.0 - clamped) * 0.5 * .pi / 180.0)
        modelNode.simdOrientation = simd_quatf(angle: halfFoldRad, axis: SIMD3<Float>(0, 0, 1))

        let shiftY = Float(Self.closedCenterShiftY * (1.0 - clamped / 180.0))
        offsetNode.simdPosition = SIMD3<Float>(0, shiftY, 0)
        rigNode.simdOrientation = orientationSpring.current
        SCNTransaction.commit()
        SCNTransaction.flush()

        setNeedsDisplay(bounds)
    }

    private func updateCameraDistance() {
        guard let cameraNode else { return }
        let viewHeight = bounds.height > 10 ? bounds.height : 548
        let visibleUnitsY = viewHeight / Self.pointsPerModelUnit
        let halfFovRad = Self.fovDegrees * .pi / 360.0
        let zDist = Self.screenPlaneZ + visibleUnitsY / (2.0 * tan(halfFovRad))
        cameraNode.position = SCNVector3(0, 0, zDist)
    }

    private func configureModel() {
        guard let url = Self.modelURL(),
              let loaded = try? SCNScene(url: url),
              let model = loaded.rootNode.childNode(withName: "root", recursively: false),
              let skeleton = loaded.rootNode.childNode(withName: "lycFlYvVKoCNYIe", recursively: true),
              let key = skeleton.animationKeys.first,
              let foldPlayer = skeleton.animationPlayer(forKey: key) else { return }

        let extractedTracks = Self.extractBoneTracks(from: foldPlayer.animation, skeleton: skeleton)
        guard !extractedTracks.isEmpty else { return }
        skeleton.removeAllAnimations()

        if let leftBone = skeleton.childNode(withName: "pXhjqgUFTJHRqSk", recursively: true),
           let rightBone = skeleton.childNode(withName: "mXxhFfVnnQRwgSU", recursively: true) {
            self.leftWingBone = leftBone
            self.rightWingBone = rightBone
            self.leftWingBindTransform = simd_float4x4(leftBone.convertTransform(SCNMatrix4Identity, to: model))
            self.rightWingBindTransform = simd_float4x4(rightBone.convertTransform(SCNMatrix4Identity, to: model))
        }

        // Match safearea.info's two-group rig: `rigNode` (`h`) holds the orientation quaternion,
        // `offsetNode` (`g`) holds the hinge centering offset, and `model` (`root`) holds the
        // symmetric half-angle counter-rotation.
        let rig = SCNNode()
        rig.name = "simlab-duo-rig"
        let offset = SCNNode()
        offset.name = "simlab-duo-offset"
        loaded.rootNode.addChildNode(rig)
        rig.addChildNode(offset)
        model.removeFromParentNode()
        offset.addChildNode(model)

        self.rigNode = rig
        self.offsetNode = offset
        self.modelNode = model
        self.boneTracks = extractedTracks
        self.innerMaterial = Self.material(named: "CvyXbAGXoolRUYl", in: loaded.rootNode)
        self.outerMaterial = Self.material(named: "YqugYDOqMSOpqyA", in: loaded.rootNode)

        Self.styleMaterials(in: loaded.rootNode)
        Self.configureLighting(in: loaded.rootNode)

        let camera = SCNCamera()
        camera.fieldOfView = Self.fovDegrees
        camera.zNear = 0.1
        camera.zFar = 200
        let camNode = SCNNode()
        camNode.camera = camera
        loaded.rootNode.addChildNode(camNode)
        self.cameraNode = camNode

        loaded.background.contents = NSColor.clear
        scene = loaded
        pointOfView = camNode
        autoenablesDefaultLighting = false
        rendersContinuously = false

        updateCameraDistance()
        syncPoseIfIdle(angleDegrees: 180, orientation: .portrait)
    }

    private static func extractBoneTracks(from animation: SCNAnimation, skeleton: SCNNode) -> [BoneTrack] {
        let caAnim = CAAnimation(scnAnimation: animation)
        guard let group = caAnim as? CAAnimationGroup, let animations = group.animations else { return [] }
        var posMap: [String: [SIMD3<Float>]] = [:]
        var rotMap: [String: [simd_quatf]] = [:]
        for item in animations {
            guard let kf = item as? CAKeyframeAnimation,
                  let keyPath = kf.keyPath,
                  let values = kf.values as? [NSValue],
                  values.count >= 121 else { continue }
            let parts = keyPath.split(separator: ".")
            guard parts.count == 2 else { continue }
            let boneName = String(parts[0].dropFirst())
            let property = String(parts[1])
            if property == "position" {
                posMap[boneName] = (0...120).map { SIMD3<Float>(values[$0].scnVector3Value) }
            } else if property == "orientation" {
                rotMap[boneName] = (0...120).map {
                    let v = values[$0].scnVector4Value
                    return simd_quatf(ix: Float(v.x), iy: Float(v.y), iz: Float(v.z), r: Float(v.w))
                }
            }
        }
        var tracks: [BoneTrack] = []
        tracks.reserveCapacity(posMap.count)
        for (name, positions) in posMap {
            guard let orientations = rotMap[name],
                  let node = (name == skeleton.name ? skeleton : skeleton.childNode(withName: name, recursively: true)) else {
                continue
            }
            tracks.append(BoneTrack(node: node, positions: positions, orientations: orientations))
        }
        return tracks
    }

    private static let screenMatNames: Set<String> = ["CvyXbAGXoolRUYl", "YqugYDOqMSOpqyA"]
    private static let darkBezelMatNames: Set<String> = [
        "PLzJQjJEDhjIwvC", "TzYENmopFAzWHxj", "KQflzzRyzmDVLKR", "HCGQGgQPyxtjDwz", "cVTxCUWyGoaEFOH",
    ]
    private static let decalMatNames: Set<String> = [
        "KIZQkZTTouAhXpd", "cbPOUScIEwDvetK", "tDyevDmZRbbFVYk", "czSdVuSmHDUPduw", "UzUzwPKtObjRjQN",
    ]

    private static func styleMaterials(in node: SCNNode) {
        for material in node.geometry?.materials ?? [] {
            let name = material.name ?? ""
            if screenMatNames.contains(name) {
                material.lightingModel = .constant
                material.diffuse.contents = NSColor(srgbRed: 0.04, green: 0.045, blue: 0.055, alpha: 1)
                material.emission.contents = NSColor.black
            } else if decalMatNames.contains(name) {
                node.isHidden = true
            } else if darkBezelMatNames.contains(name) {
                material.lightingModel = .physicallyBased
                material.diffuse.contents = NSColor(srgbRed: 0.08, green: 0.085, blue: 0.095, alpha: 1)
                material.metalness.contents = 0.25
                material.roughness.contents = 0.42
                material.transparent.contents = NSColor.white
                material.transparency = 1.0
            } else {
                // Match safearea.info's MeshStandardMaterial({ color: 0x45484c, metalness: 0.65, roughness: 0.38 })
                material.lightingModel = .physicallyBased
                material.diffuse.contents = NSColor(srgbRed: 0x45 / 255.0, green: 0x48 / 255.0, blue: 0x4c / 255.0, alpha: 1)
                material.metalness.contents = 0.65
                material.roughness.contents = 0.38
                material.transparent.contents = NSColor.white
                material.transparency = 1.0
                material.isDoubleSided = true
            }
        }
        for child in node.childNodes {
            styleMaterials(in: child)
        }
    }

    private static func configureLighting(in rootNode: SCNNode) {
        // Hemisphere sky fill (#ffffff)
        let skyNode = SCNNode()
        let skyLight = SCNLight()
        skyLight.type = .directional
        skyLight.color = NSColor.white
        skyLight.intensity = 900
        skyNode.light = skyLight
        skyNode.position = SCNVector3(0, 40, 20)
        skyNode.look(at: SCNVector3Zero)
        rootNode.addChildNode(skyNode)

        // Hemisphere ground bounce (#363d50)
        let groundNode = SCNNode()
        let groundLight = SCNLight()
        groundLight.type = .directional
        groundLight.color = NSColor(srgbRed: 0x36 / 255.0, green: 0x3d / 255.0, blue: 0x50 / 255.0, alpha: 1)
        groundLight.intensity = 650
        groundNode.light = groundLight
        groundNode.position = SCNVector3(0, -40, -10)
        groundNode.look(at: SCNVector3Zero)
        rootNode.addChildNode(groundNode)

        // Soft ambient fill
        let ambNode = SCNNode()
        let ambLight = SCNLight()
        ambLight.type = .ambient
        ambLight.color = NSColor(srgbRed: 0.65, green: 0.68, blue: 0.74, alpha: 1)
        ambLight.intensity = 450
        ambNode.light = ambLight
        rootNode.addChildNode(ambNode)

        // Key directional light at (2, 3, 4) matching safearea.info
        let keyNode = SCNNode()
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.color = NSColor.white
        keyLight.intensity = 1600
        keyNode.light = keyLight
        keyNode.position = SCNVector3(20, 30, 40)
        keyNode.look(at: SCNVector3Zero)
        rootNode.addChildNode(keyNode)
    }

    private static var quarterTurnClockwiseUVTransform: SCNMatrix4 {
        var m = SCNMatrix4Identity
        m.m11 = 0; m.m12 = -1
        m.m21 = 1; m.m22 = 0
        m.m41 = 0; m.m42 = 1
        return m
    }

    private static func makeTexture(from surface: IOSurface, width: Int, height: Int, device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
    }

    private static func material(named name: String, in node: SCNNode) -> SCNMaterial? {
        if let found = node.geometry?.materials.first(where: { $0.name == name }) { return found }
        for child in node.childNodes {
            if let found = material(named: name, in: child) { return found }
        }
        return nil
    }

    private static func modelURL() -> URL? {
        var roots = ["/Applications/Xcode.app/Contents"]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            roots.insert(URL(fileURLWithPath: developer).deletingLastPathComponent().path, at: 0)
        }
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        roots += apps.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
            .map { "/Applications/\($0)/Contents" }
        return roots.lazy.map {
            URL(fileURLWithPath: $0).appendingPathComponent(modelRelativePath)
        }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

struct DuoFlipCanvas: NSViewRepresentable {
    let display: DuoActiveDisplay
    let visible: Bool
    let onAttached: @MainActor (DuoFlipSceneView) -> Void

    func makeNSView(context: Context) -> DuoFlipSceneView {
        let view = DuoFlipSceneView(frame: .zero)
        view.updateDisplay(display, visible: visible)
        onAttached(view)
        return view
    }

    func updateNSView(_ view: DuoFlipSceneView, context: Context) {
        view.updateDisplay(display, visible: visible)
    }
}

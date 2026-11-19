import Foundation

@MainActor
final class WebFrameStream {
    private struct Identity: Equatable {
        let stamp: UInt64
        let revision: UInt32?
    }

    private final class Panel {
        let jpegEncoder = WebFrameEncoder()
        let videoEncoder = WebH264Encoder()
        var encodingJPEG = false
        var encodingVideo = false
        var status: WebDeviceStatus?
        var jpegIdentity: Identity?
        var videoIdentity: Identity?
        var jpeg: (bytes: Data, revision: UInt32, videoFallback: Bool)?
        var keyRequests: [ObjectIdentifier: UInt64] = [:]
        var videoFailures = 0
    }

    private let panels = (0..<3).map { _ in Panel() }
    private var servers: [WebMultiSimServer] = []

    func setServers(_ next: [WebMultiSimServer]) {
        for server in next where !servers.contains(where: { $0 === server }) {
            for (index, panel) in panels.enumerated() {
                if let status = panel.status { server.publish(status) }
                if let jpeg = panel.jpeg, jpeg.revision == (panel.status?.revision ?? 0) {
                    server.publish(jpeg.bytes, panel: UInt8(index), revision: jpeg.revision,
                                   videoFallback: jpeg.videoFallback)
                }
            }
        }
        servers = next
    }

    func submit(_ status: WebDeviceStatus, source: WebFrameSource?) {
        let panel = panels[status.panel]
        if panel.status != status {
            panel.status = status
            for server in servers { server.publish(status) }
        }
        guard let source else {
            panel.jpegIdentity = nil
            panel.videoIdentity = nil
            return
        }

        let identity = Identity(stamp: source.stamp, revision: status.revision)
        let demand = servers.map { ($0, $0.demand) }
        let keyRequests = Dictionary(uniqueKeysWithValues: demand.compactMap { server, subscriber -> (ObjectIdentifier, UInt64)? in
            subscriber.videoRequest.map { (ObjectIdentifier(server), $0) }
        })
        let videoFallback = panel.videoFailures >= 3
        if demand.contains(where: { $0.1.jpeg }) || (videoFallback && !keyRequests.isEmpty) {
            encodeJPEG(status, panel: panel, source: source, identity: identity, videoFallback: videoFallback)
        }
        if !keyRequests.isEmpty, !videoFallback {
            encodeVideo(status, panel: panel, source: source, identity: identity, keyRequests: keyRequests)
        }
    }

    private func encodeJPEG(_ status: WebDeviceStatus, panel: Panel, source: WebFrameSource,
                            identity: Identity, videoFallback: Bool) {
        guard !panel.encodingJPEG,
              panel.jpegIdentity != identity || panel.jpeg?.videoFallback != videoFallback else { return }
        panel.jpegIdentity = identity
        panel.encodingJPEG = true
        let encoder = panel.jpegEncoder
        Task { [weak self, weak panel] in
            let jpeg = await Task.detached(priority: .userInitiated) { encoder.encode(source) }.value
            guard let self, let panel else { return }
            panel.encodingJPEG = false
            guard let jpeg, panel.status?.revision == status.revision, panel.jpegIdentity == identity else { return }
            let revision = status.revision ?? 0
            panel.jpeg = (jpeg, revision, videoFallback)
            for server in servers {
                server.publish(jpeg, panel: UInt8(status.panel), revision: revision, videoFallback: videoFallback)
            }
        }
    }

    private func encodeVideo(_ status: WebDeviceStatus, panel: Panel, source: WebFrameSource,
                             identity: Identity, keyRequests: [ObjectIdentifier: UInt64]) {
        guard !panel.encodingVideo else { return }
        let forceKey = panel.keyRequests != keyRequests || panel.videoIdentity?.revision != identity.revision
            || panel.videoIdentity == nil
        guard forceKey || panel.videoIdentity != identity else { return }
        panel.encodingVideo = true
        let encoder = panel.videoEncoder
        Task { [weak self, weak panel] in
            let video = await Task.detached(priority: .userInitiated) { encoder.encode(source, forceKey: forceKey) }.value
            guard let self, let panel else { return }
            panel.encodingVideo = false
            guard let video, !forceKey || video.isKey else {
                panel.videoIdentity = nil
                panel.videoFailures += 1
                return
            }
            guard panel.status?.revision == status.revision else {
                panel.videoIdentity = nil
                return
            }
            panel.videoFailures = 0
            panel.videoIdentity = identity
            panel.keyRequests = keyRequests
            for server in servers {
                server.publishVideo(video, panel: UInt8(status.panel), revision: status.revision ?? 0)
            }
        }
    }
}

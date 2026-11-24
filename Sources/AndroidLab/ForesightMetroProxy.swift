import Foundation
import Network

/// Android's legacy global proxy has no exclusions. Keep Metro local while
/// forwarding other HTTP/CONNECT traffic to the Mac's existing local proxy.
final class ForesightMetroProxy: @unchecked Sendable {
    let upstreamPort: UInt16
    private let queue = DispatchQueue(label: "SimLab.FNProxy")
    private var listener: NWListener?
    private var connections: [UUID: (NWConnection, NWConnection?)] = [:]
    private(set) var port: UInt16?

    init(upstreamPort: UInt16) { self.upstreamPort = upstreamPort }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    self.port = listener.port!.rawValue
                    continuation.resume(returning: self.port!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.start(queue: queue)
        }
    }

    /// Returns a rewritten origin-form request for the exact local Metro server.
    static func metroRequest(_ data: Data) -> Data? {
        guard let range = data.range(of: Data("\r\n".utf8)),
              let line = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] != "CONNECT", let url = URL(string: parts[1]),
              url.scheme == "http", ["localhost", "127.0.0.1", "[::1]"].contains(url.host),
              url.port == ForesightDevConfiguration.port else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let target = path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        return Data("\(parts[0]) \(target) \(parts[2])".utf8) + data[range.lowerBound...]
    }

    private func accept(_ client: NWConnection) {
        let id = UUID()
        connections[id] = (client, nil)
        client.start(queue: queue)
        readRequest(client, id: id, prefix: Data())
    }

    private func readRequest(_ client: NWConnection, id: UUID, prefix: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            let request = prefix + (data ?? Data())
            guard error == nil, !request.isEmpty else { self.close(id); return }
            if request.range(of: Data("\r\n".utf8)) == nil {
                if !done && request.count < 16_384 { self.readRequest(client, id: id, prefix: request) }
                else { self.close(id) }
                return
            }
            let local = Self.metroRequest(request)
            let upstream = NWConnection(host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: local == nil ? self.upstreamPort : 8081)!, using: .tcp)
            self.connections[id] = (client, upstream)
            upstream.start(queue: self.queue)
            upstream.send(content: local ?? request, completion: .contentProcessed { error in
                if error != nil { self.close(id) }
                else { self.pipe(client, to: upstream, id: id) }
            })
            self.pipe(upstream, to: client, id: id)
        }
    }

    private func pipe(_ source: NWConnection, to destination: NWConnection, id: UUID) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            guard error == nil, let data, !data.isEmpty else { self.close(id); return }
            destination.send(content: data, completion: .contentProcessed { error in
                if error != nil || done { self.close(id) }
                else { self.pipe(source, to: destination, id: id) }
            })
        }
    }

    private func close(_ id: UUID) {
        guard let pair = connections.removeValue(forKey: id) else { return }
        pair.0.cancel()
        pair.1?.cancel()
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for id in Array(self.connections.keys) { self.close(id) }
        }
    }
}

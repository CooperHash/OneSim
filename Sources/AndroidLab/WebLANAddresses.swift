import Darwin
import Foundation

enum WebLANAddresses {
    static func available() -> [String] {
        var entries: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&entries) == 0, let entries else { return [] }
        defer { freeifaddrs(entries) }

        var result: [(interface: String, address: String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = entries
        while let entry = current?.pointee {
            current = entry.ifa_next
            guard let name = entry.ifa_name,
                  let address = entry.ifa_addr,
                  address.pointee.sa_family == AF_INET,
                  entry.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING)
            else { continue }

            // macOS names Wi-Fi and Ethernet enN. Skip tunnels, host-only bridges,
            // loopback, and interfaces with a public IPv4 address.
            let interface = String(cString: name)
            guard interface.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let octets = ip.split(separator: ".").compactMap { UInt8($0) }
            guard octets.count == 4 else { continue }
            if octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168) {
                result.append((interface, ip))
            }
        }
        var seen = Set<String>()
        return result.sorted { $0.interface < $1.interface }.map(\.address).filter { seen.insert($0).inserted }
    }
}

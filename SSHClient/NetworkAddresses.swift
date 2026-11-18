import Foundation
import Darwin

enum NetworkAddresses {
    /// Non-secret local interface addresses used to configure the Pi's existing SSH source allowlist.
    static func export() throws {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return }
        defer { freeifaddrs(interfaces) }
        var addresses: [String: String] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name == "en0" || name.hasPrefix("utun") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            addresses[name] = String(cString: host)
        }
        try JSONEncoder().encode(addresses).write(to: URL.documentsDirectory.appending(path: "iphone-network.json"),
                                                  options: [.atomic, .completeFileProtection])
    }
}

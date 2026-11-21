import Darwin
import Foundation

/// Loopback sockets for self-tests: traffic we fully control, that never leaves the machine.
public enum Loopback {
    public struct ListeningSocket: Sendable {
        public var fd: Int32
        public var port: UInt16
    }

    private static func address(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        return address
    }

    /// Listens on 127.0.0.1 at a port the system picks. The caller closes `fd`.
    public static func listen() -> ListeningSocket? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = address(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 64) == 0 else {
            close(fd)
            return nil
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            close(fd)
            return nil
        }
        return ListeningSocket(fd: fd, port: UInt16(bigEndian: address.sin_port))
    }

    /// A port that was free a moment ago, for handing to another program.
    public static func freePort() -> UInt16? {
        guard let listener = listen() else { return nil }
        close(listener.fd)
        return listener.port
    }

    /// Connects, sends `bytes`, reads them on the far side, holds the connection open for
    /// `lifetime` seconds, then closes both ends. Returns how long the connection existed.
    @discardableResult
    public static func flow(to listener: ListeningSocket, bytes: Int = 1024, lifetime: Double = 0) -> Double? {
        let start = DispatchTime.now().uptimeNanoseconds
        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { return nil }
        var address = address(port: listener.port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(client)
            return nil
        }
        let server = accept(listener.fd, nil, nil)
        guard server >= 0 else {
            close(client)
            return nil
        }
        var payload = [UInt8](repeating: 0x5a, count: bytes)
        _ = write(client, payload, payload.count)
        _ = read(server, &payload, payload.count)
        if lifetime > 0 { Thread.sleep(forTimeInterval: lifetime) }
        close(client)
        close(server)
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }
}

import Testing

@testable import SwitchboardCore

@Suite struct IPAddressTests {
    @Test func formatsIPv4() {
        #expect(IPAddress(networkBytes: [10, 0, 0, 36])?.description == "10.0.0.36")
        #expect(IPAddress.v4(0x7f00_0001).isLoopback)
        #expect(IPAddress.v4(0).isUnspecified)
    }

    @Test func formatsIPv6() {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[15] = 1
        let loopback = IPAddress(networkBytes: bytes)
        #expect(loopback?.description == "::1")
        #expect(loopback?.isLoopback == true)

        let documentation: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x2a]
        #expect(IPAddress(networkBytes: documentation)?.description == "2001:db8::2a")
    }

    @Test func roundTripsBytes() {
        let bytes: [UInt8] = [0xfe, 0x80, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8]
        #expect(IPAddress(networkBytes: bytes)?.networkBytes == bytes)
        #expect(IPAddress(networkBytes: [192, 168, 1, 254])?.networkBytes == [192, 168, 1, 254])
    }

    @Test func rejectsOtherLengths() {
        #expect(IPAddress(networkBytes: [1, 2, 3]) == nil)
        #expect(IPAddress(networkBytes: [UInt8](repeating: 0, count: 17)) == nil)
    }
}

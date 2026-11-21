import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardSources

@Suite struct CodeSignatureTests {
    private func temporary(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sb-trust-\(UUID().uuidString)-\(name)")
    }

    @Test func recognisesApplesOwnPrograms() {
        for path in ["/bin/ls", "/usr/bin/ssh", "/System/Applications/Calculator.app"] {
            #expect(CodeSignature.evaluate(path: path) == .init(status: .apple, teamID: nil), "\(path)")
        }
    }

    @Test func callsALocalBuildAdHoc() {
        // The linker signs every arm64 binary it makes, with no identity: this test binary included.
        let own = Bundle(for: Marker.self).executablePath ?? CommandLine.arguments[0]
        #expect(CodeSignature.evaluate(path: own).status == .adHoc, "\(own)")
    }

    @Test func tellsUnsignedFromTamperedWith() throws {
        let script = temporary("script")
        try Data("#!/bin/sh\necho hello\n".utf8).write(to: script)
        defer { try? FileManager.default.removeItem(at: script) }
        #expect(CodeSignature.evaluate(path: script.path).status == .unsigned)

        // An Apple program with one byte of its code changed: signed, and the signature no longer holds.
        let copy = temporary("ls")
        var bytes = try Data(contentsOf: URL(fileURLWithPath: "/bin/ls"))
        defer { try? FileManager.default.removeItem(at: copy) }
        try bytes.write(to: copy)
        #expect(CodeSignature.evaluate(path: copy.path).status == .apple)
        // In the middle of the file, which is not the slice this process would run: every one is checked.
        bytes[bytes.count / 2] ^= 0xff
        try bytes.write(to: copy)
        #expect(CodeSignature.evaluate(path: copy.path).status == .invalid)

        // A link to a program inside an app is judged as the program is.
        let link = temporary("link")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/System/Applications/Calculator.app/Contents/MacOS/Calculator")
        #expect(CodeSignature.evaluate(path: link.path).status == .apple)
        // A file we may not read is unknown, not tampered with.
        let secret = temporary("secret")
        defer { try? FileManager.default.removeItem(at: secret) }
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: secret.path)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: secret.path)
        #expect(CodeSignature.evaluate(path: secret.path).status != .invalid)

        #expect(CodeSignature.evaluate(path: "/nonexistent/program").status == .unknown)
    }

    @Test func remembersVerdictsAndChecksAgainWhenTheFileChanges() throws {
        let cache = TrustCache()
        func wait(_ path: String) -> CodeSignature.Verdict? {
            for _ in 0..<400 {
                if let verdict = cache.verdict(forPath: path) { return verdict }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return nil
        }
        // The first question starts a check and has no answer yet.
        #expect(cache.verdict(forPath: "/bin/ls") == nil)
        #expect(wait("/bin/ls")?.status == .apple)
        #expect(cache.verdict(forPath: "/bin/ls")?.status == .apple)

        let file = temporary("changing")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("#!/bin/sh\n".utf8).write(to: file)
        #expect(wait(file.path)?.status == .unsigned)
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: file.path + ".new")
        _ = try FileManager.default.replaceItemAt(file, withItemAt: URL(fileURLWithPath: file.path + ".new"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        #expect(wait(file.path)?.status == .apple)
    }
}

private final class Marker {}

@Suite struct ReverseResolverTests {
    private func drain(_ resolver: ReverseResolver, expecting count: Int) -> [CaptureObservation] {
        var all: [CaptureObservation] = []
        for _ in 0..<4000 where all.count < count {
            all += resolver.pollCapture(now: 0)
            Thread.sleep(forTimeInterval: 0.005)
        }
        return all + resolver.pollCapture(now: 0)
    }

    @Test func asksOnceForEachAddressAndNoFasterThanItsLimit() {
        let resolver = ReverseResolver(perSecond: 5) { "host-\($0).example" }
        let addresses = (1...20).map { IPAddress("192.0.2.\($0)")! }
        for address in addresses { resolver.request(address, now: 100) }
        #expect(resolver.lookups == 5)
        // The same moment again: still at the limit, and nothing is asked twice.
        for address in addresses { resolver.request(address, now: 100.5) }
        #expect(resolver.lookups == 5)
        // A second later the next five go out, and they are the ones not yet asked.
        for address in addresses { resolver.request(address, now: 101) }
        #expect(resolver.lookups == 10)

        let results = drain(resolver, expecting: 10)
        #expect(results.count == 10)
        var named = Set<String>()
        for case .reverse(let address, let name) in results {
            #expect(name == "host-\(address).example")
            named.insert("\(address)")
        }
        #expect(named == Set((1...10).map { "192.0.2.\($0)" }))
    }

    @Test func leavesLoopbackAndMulticastAloneAndReportsNothingForNoName() {
        let resolver = ReverseResolver(perSecond: 100) { _ in nil }
        for text in ["127.0.0.1", "::1", "224.0.0.251", "ff02::fb"] { resolver.request(IPAddress(text)!, now: 1) }
        #expect(resolver.lookups == 0)
        resolver.request(IPAddress("192.0.2.1")!, now: 1)
        #expect(resolver.lookups == 1)
        Thread.sleep(forTimeInterval: 0.05)
        #expect(resolver.pollCapture(now: 1).isEmpty)
    }
}

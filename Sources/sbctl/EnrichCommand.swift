import Foundation
import SwitchboardCore
import SwitchboardSources
import SwitchboardStore

/// `sbctl geo <address>…` and `sbctl trust <path>…`: ask the enrichment code one question.
enum EnrichCommand {
    static func geo(_ arguments: [String]) -> Int32 {
        let options = Options(arguments: arguments)
        let directory = options.value("--dir").map { URL(fileURLWithPath: $0) }
            ?? LogStore.defaultURL().deletingLastPathComponent().appendingPathComponent("GeoIP")
        let loaded = GeoDatabase.load(directory: directory)
        loaded.problems.forEach { print("could not read \($0)") }
        guard !loaded.database.sources.isEmpty else {
            print("no .mmdb files in \(directory.path)\nrun scripts/fetch-geoip.sh to download the free DB-IP Lite databases")
            return 1
        }
        print("databases: \(loaded.database.sources.joined(separator: ", "))")
        var skip = false
        for argument in arguments {
            if skip {
                skip = false
                continue
            }
            if argument == "--dir" {
                skip = true
                continue
            }
            guard let address = IPAddress(argument) else {
                print("\(argument): not an address")
                continue
            }
            let facts = loaded.database.facts(for: address)
            let place = [facts.city, facts.country].compactMap { $0 }.joined(separator: ", ")
            let network = facts.asn.map { "AS\($0)" + (facts.org.map { " \($0)" } ?? "") } ?? "no network owner"
            let position = facts.latitude.flatMap { latitude in facts.longitude.map { String(format: " (%.2f, %.2f)", latitude, $0) } } ?? ""
            print("\(address): \(AddressClass(address).label) · \(place.isEmpty ? "no location" : place)\(position) · \(network)")
        }
        return 0
    }

    static func trust(_ paths: [String]) -> Int32 {
        guard !paths.isEmpty else {
            print("usage: sbctl trust <path to a program>…")
            return 2
        }
        for path in paths {
            let started = DispatchTime.now().uptimeNanoseconds
            let verdict = CodeSignature.evaluate(path: path)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            print(String(format: "%@  %@%@  (%.1f ms)", verdict.status.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0), path, verdict.teamID.map { "  team \($0)" } ?? "", milliseconds))
        }
        return 0
    }
}

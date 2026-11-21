import Foundation

/// A place on the globe, in degrees.
public struct GeoPoint: Sendable, Equatable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Parses `47.6, -122.3`.
    public init?(_ text: String) {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]),
              abs(latitude) <= 90, abs(longitude) <= 180
        else { return nil }
        self.init(latitude: latitude, longitude: longitude)
    }

    /// Where this Mac probably is, from its time zone alone. Switchboard never asks the
    /// network where it is; this is a guess the user can replace in Settings.
    public static func guess(timeZone: TimeZone = .current) -> GeoPoint {
        if let known = zones[timeZone.identifier] { return GeoPoint(latitude: known.0, longitude: known.1) }
        // A zone not in the table: its offset gives the longitude, and the latitude is a
        // middling northern one, where most people are.
        let hours = Double(timeZone.secondsFromGMT(for: Date()) - (timeZone.isDaylightSavingTime() ? 3600 : 0)) / 3600
        return GeoPoint(latitude: 35, longitude: max(-180, min(180, hours * 15)))
    }

    /// The city each common time zone is named after.
    static let zones: [String: (Double, Double)] = [
        "America/Los_Angeles": (34.05, -118.24), "America/Vancouver": (49.28, -123.12), "America/Denver": (39.74, -104.99),
        "America/Phoenix": (33.45, -112.07), "America/Chicago": (41.88, -87.63), "America/New_York": (40.71, -74.01),
        "America/Toronto": (43.65, -79.38), "America/Halifax": (44.65, -63.57), "America/St_Johns": (47.56, -52.71),
        "America/Anchorage": (61.22, -149.90), "Pacific/Honolulu": (21.31, -157.86), "America/Mexico_City": (19.43, -99.13),
        "America/Bogota": (4.71, -74.07), "America/Lima": (-12.05, -77.04), "America/Santiago": (-33.45, -70.67),
        "America/Sao_Paulo": (-23.55, -46.63), "America/Argentina/Buenos_Aires": (-34.60, -58.38), "America/Caracas": (10.48, -66.90),
        "America/Edmonton": (53.55, -113.49), "America/Winnipeg": (49.90, -97.14), "America/Detroit": (42.33, -83.05),
        "America/Boise": (43.62, -116.20), "America/Puerto_Rico": (18.47, -66.11),
        "Europe/London": (51.51, -0.13), "Europe/Dublin": (53.35, -6.26), "Europe/Lisbon": (38.72, -9.14),
        "Europe/Madrid": (40.42, -3.70), "Europe/Paris": (48.86, 2.35), "Europe/Brussels": (50.85, 4.35),
        "Europe/Amsterdam": (52.37, 4.90), "Europe/Berlin": (52.52, 13.40), "Europe/Zurich": (47.38, 8.54),
        "Europe/Rome": (41.90, 12.50), "Europe/Vienna": (48.21, 16.37), "Europe/Prague": (50.08, 14.44),
        "Europe/Warsaw": (52.23, 21.01), "Europe/Stockholm": (59.33, 18.07), "Europe/Oslo": (59.91, 10.75),
        "Europe/Copenhagen": (55.68, 12.57), "Europe/Helsinki": (60.17, 24.94), "Europe/Athens": (37.98, 23.73),
        "Europe/Istanbul": (41.01, 28.98), "Europe/Kiev": (50.45, 30.52), "Europe/Kyiv": (50.45, 30.52),
        "Europe/Moscow": (55.76, 37.62), "Europe/Bucharest": (44.43, 26.10), "Europe/Budapest": (47.50, 19.04),
        "Africa/Cairo": (30.04, 31.24), "Africa/Lagos": (6.52, 3.38), "Africa/Nairobi": (-1.29, 36.82),
        "Africa/Johannesburg": (-26.20, 28.05), "Africa/Casablanca": (33.57, -7.59),
        "Asia/Dubai": (25.20, 55.27), "Asia/Riyadh": (24.71, 46.68), "Asia/Tehran": (35.69, 51.39),
        "Asia/Jerusalem": (31.77, 35.21), "Asia/Karachi": (24.86, 67.01), "Asia/Kolkata": (22.57, 88.36),
        "Asia/Calcutta": (22.57, 88.36), "Asia/Dhaka": (23.81, 90.41), "Asia/Bangkok": (13.76, 100.50),
        "Asia/Jakarta": (-6.21, 106.85), "Asia/Singapore": (1.35, 103.82), "Asia/Kuala_Lumpur": (3.14, 101.69),
        "Asia/Ho_Chi_Minh": (10.82, 106.63), "Asia/Manila": (14.60, 120.98), "Asia/Hong_Kong": (22.32, 114.17),
        "Asia/Shanghai": (31.23, 121.47), "Asia/Taipei": (25.03, 121.57), "Asia/Seoul": (37.57, 126.98),
        "Asia/Tokyo": (35.68, 139.69), "Asia/Kathmandu": (27.72, 85.32), "Asia/Almaty": (43.24, 76.89),
        "Australia/Perth": (-31.95, 115.86), "Australia/Adelaide": (-34.93, 138.60), "Australia/Brisbane": (-27.47, 153.03),
        "Australia/Sydney": (-33.87, 151.21), "Australia/Melbourne": (-37.81, 144.96), "Pacific/Auckland": (-36.85, 174.76),
        "UTC": (51.48, 0), "GMT": (51.48, 0),
    ]
}

/// Invented but plausible locations and owners for simulated addresses, so the globe and
/// the owner groupings have something to show without a database. Each address always
/// lands in the same place.
public struct SimulatedGeography: AddressEnricher {
    struct Site {
        var city: String
        var country: String
        var latitude: Double
        var longitude: Double
    }

    struct Owner {
        var asn: UInt32
        var org: String
        /// Indexes into `sites`, where this owner has data centres.
        var sites: [Int]
    }

    static let sites: [Site] = [
        Site(city: "Ashburn", country: "US", latitude: 39.04, longitude: -77.49),
        Site(city: "Boardman", country: "US", latitude: 45.84, longitude: -119.70),
        Site(city: "San Jose", country: "US", latitude: 37.34, longitude: -121.89),
        Site(city: "Dallas", country: "US", latitude: 32.78, longitude: -96.80),
        Site(city: "Chicago", country: "US", latitude: 41.88, longitude: -87.63),
        Site(city: "Seattle", country: "US", latitude: 47.61, longitude: -122.33),
        Site(city: "Montréal", country: "CA", latitude: 45.50, longitude: -73.57),
        Site(city: "São Paulo", country: "BR", latitude: -23.55, longitude: -46.63),
        Site(city: "Dublin", country: "IE", latitude: 53.35, longitude: -6.26),
        Site(city: "London", country: "GB", latitude: 51.51, longitude: -0.13),
        Site(city: "Amsterdam", country: "NL", latitude: 52.37, longitude: 4.90),
        Site(city: "Frankfurt am Main", country: "DE", latitude: 50.11, longitude: 8.68),
        Site(city: "Stockholm", country: "SE", latitude: 59.33, longitude: 18.07),
        Site(city: "Paris", country: "FR", latitude: 48.86, longitude: 2.35),
        Site(city: "Mumbai", country: "IN", latitude: 19.08, longitude: 72.88),
        Site(city: "Singapore", country: "SG", latitude: 1.35, longitude: 103.82),
        Site(city: "Tokyo", country: "JP", latitude: 35.68, longitude: 139.69),
        Site(city: "Seoul", country: "KR", latitude: 37.57, longitude: 126.98),
        Site(city: "Sydney", country: "AU", latitude: -33.87, longitude: 151.21),
        Site(city: "Johannesburg", country: "ZA", latitude: -26.20, longitude: 28.05),
        Site(city: "Hong Kong", country: "HK", latitude: 22.32, longitude: 114.17),
    ]

    static let owners: [Owner] = [
        Owner(asn: 16509, org: "Amazon.com, Inc.", sites: [0, 1, 0, 0, 8, 11, 15, 16, 18, 7]),
        Owner(asn: 15169, org: "Google LLC", sites: [2, 4, 5, 3, 13, 10, 16, 15]),
        Owner(asn: 13335, org: "Cloudflare, Inc.", sites: [2, 3, 0, 9, 11, 15, 16, 18, 7, 19]),
        Owner(asn: 8075, org: "Microsoft Corporation", sites: [5, 0, 3, 10, 8, 20, 14]),
        Owner(asn: 714, org: "Apple Inc.", sites: [2, 3, 11, 16]),
        Owner(asn: 20940, org: "Akamai International B.V.", sites: [0, 9, 10, 11, 16, 20]),
        Owner(asn: 54113, org: "Fastly, Inc.", sites: [2, 0, 9, 12, 16]),
        Owner(asn: 32934, org: "Facebook, Inc.", sites: [6, 8, 12, 15]),
        Owner(asn: 14061, org: "DigitalOcean, LLC", sites: [0, 10, 11, 15, 14]),
        Owner(asn: 24940, org: "Hetzner Online GmbH", sites: [11, 11, 12]),
        Owner(asn: 36459, org: "GitHub, Inc.", sites: [0, 2]),
        Owner(asn: 17012, org: "Example Telecom", sites: [17, 19, 7]),
    ]

    public init() {}

    public func facts(for address: IPAddress) -> AddressFacts {
        var facts = AddressFacts()
        guard AddressClass(address) == .public else { return facts }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in address.networkBytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        hash ^= hash >> 29
        // About one address in twenty is in no database, as in real life.
        guard hash % 20 != 7 else { return facts }
        let owner = Self.owners[Int((hash >> 8) % UInt64(Self.owners.count))]
        let site = Self.sites[owner.sites[Int((hash >> 20) % UInt64(owner.sites.count))]]
        facts.asn = owner.asn
        facts.org = owner.org
        facts.country = site.country
        facts.city = site.city
        facts.latitude = site.latitude
        facts.longitude = site.longitude
        return facts
    }
}

/// Gives simulated processes the accounts real ones would run under, so views that group
/// by account have more than one group to show.
public struct SimulatedProcessResolver: ProcessResolver {
    static let system: [String: (String, UInt32)] = [
        "mDNSResponder": ("_mdnsresponder", 65), "apsd": ("root", 0), "tailscaled": ("root", 0),
        "postgres": ("_postgres", 216), "cloudd": ("ops", 501),
    ]

    public init() {}

    public func resolve(pid: Int32, name: String, uniqueID: UInt64?) -> ProcessRecord {
        let (user, uid) = Self.system[name] ?? (name.hasPrefix("worker-") ? ("_build", 270) : ("ops", 501))
        return ProcessRecord(pid: pid, uniqueID: uniqueID, name: name, uid: uid, username: user)
    }
}

import Foundation

// What members say about themselves beyond their Nostr profile: tags and where they are (SPEC
// 19.5). One replaceable event per member on the community relay: kind 30078, d =
// "belfry:profile", content `{"tags":[…],"share":"city"|"country"|"none","place":{…}}`. A place is
// always a city's point from the belfry's list, never the phone's GPS.

/// Where a member says they are: a city's point from the belfry's list, or only a country.
public struct Place: Hashable, Sendable, Identifiable {
    public var country: String
    public var placeId: String?
    public var name: String?
    public var region: String?
    public var lat: Double?
    public var lon: Double?
    public var near: String?

    public init(country: String, id: String? = nil, name: String? = nil, region: String? = nil, lat: Double? = nil, lon: Double? = nil, near: String? = nil) {
        self.country = country
        self.placeId = id
        self.name = name
        self.region = region
        self.lat = lat
        self.lon = lon
        self.near = near
    }

    public var id: String { placeId ?? "country:" + country }
}

public enum Share: String, Sendable, CaseIterable { case city, country, none }

public struct Extras: Hashable, Sendable {
    public var tags: [String]
    public var share: Share
    public var place: Place?
    public var at: Int
}

public enum People {
    static let notTag = Rx("[^\\p{L}\\p{N}_-]")
    static let spaces = Rx("\\s+")
    static let countryRx = Rx("^[A-Z]{2}$")

    /// A tag as stored: lowercase, no `#`, spaces → `-`, letters/digits/`_`/`-` only, at most 32.
    public static func cleanTag(_ t: String) -> String {
        var s = t.jsTrim().lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        s = spaces.replace(s, with: "-")
        s = notTag.replace(s, with: "")
        return s.sliceUnits(32)
    }

    public static func cleanTags(_ tags: [String]) -> [String] {
        var out = [String]()
        for t in tags.map(cleanTag) where !t.isEmpty && !out.contains(t) { out.append(t) }
        return Array(out.prefix(30))
    }

    static func num(_ o: [String: Any], _ k: String, _ max: Double) -> Double? {
        guard let n = o[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        guard v.isFinite, abs(v) <= max else { return nil }
        return (v * 100).rounded() / 100
    }

    public static func parsePlace(_ p: [String: Any], countryOnly: Bool = false) -> Place? {
        guard let country = p["country"] as? String, countryRx.test(country) else { return nil }
        if countryOnly { return Place(country: country) }
        return Place(country: country, id: (p["id"] as? String)?.sliceUnits(40), name: (p["name"] as? String)?.sliceUnits(80),
                     region: (p["region"] as? String)?.sliceUnits(80), lat: num(p, "lat", 90), lon: num(p, "lon", 180), near: p["near"] as? String)
    }

    /// nil when the content is not a JSON object.
    public static func parseExtras(_ content: String, at: Int) -> Extras? {
        guard let c = JSON.parse(content) as? [String: Any] else { return nil }
        let tags = cleanTags((c["tags"] as? [Any] ?? []).compactMap { $0 as? String })
        let share: Share = (c["share"] as? String) == "country" ? .country : (c["share"] as? String) == "none" ? .none : .city
        var place: Place?
        if share != .none, let p = c["place"] as? [String: Any] {
            place = parsePlace(p, countryOnly: share == .country)
            place?.near = nil
        }
        return Extras(tags: tags, share: share, place: place, at: at)
    }

    public static func placeJSON(_ p: Place) -> [String: Any] {
        var o = [String: Any]()
        if let v = p.placeId { o["id"] = v }
        if let v = p.name { o["name"] = v }
        if let v = p.region { o["region"] = v }
        o["country"] = p.country
        if let v = p.lat { o["lat"] = v }
        if let v = p.lon { o["lon"] = v }
        if let v = p.near { o["near"] = v }
        return o
    }

    /// The content of the event that saves my tags and place.
    public static func extrasContent(tags: [String], share: Share, place: Place?) -> String {
        var kept: Place?
        if share != .none, let place { kept = share == .country ? Place(country: place.country) : place }
        var o: [String: Any] = ["tags": cleanTags(tags), "share": share.rawValue]
        if let kept { o["place"] = placeJSON(kept) }
        return JSON.encode(o)
    }

    /// A country named in the reader's language, or its code.
    public static func countryName(_ code: String, locale: Locale = .current) -> String {
        locale.localizedString(forRegionCode: code) ?? code
    }

    /// "Brussels, Belgium" or "Belgium"; "" without a place.
    public static func placeLabel(_ p: Place?, locale: Locale = .current) -> String {
        guard let p else { return "" }
        if let n = p.name, !n.isEmpty { return n + ", " + countryName(p.country, locale: locale) }
        return countryName(p.country, locale: locale)
    }

    public static let countryCodes: [String] = ("AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ " +
        "CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR " +
        "GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP " +
        "KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ " +
        "NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW " +
        "SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ " +
        "UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS XK YE YT ZA ZM ZW").split(separator: " ").map(String.init)

    /// (code, name) of every country, by name.
    public static func countries(locale: Locale = .current) -> [(code: String, name: String)] {
        countryCodes.map { (code: $0, name: countryName($0, locale: locale)) }.sorted { $0.name < $1.name }
    }

    /// The demo's places (the web chat's DEMO_PLACES), for the local-only mode.
    public static let demoPlaces: [Place] = [
        Place(country: "BE", id: "gn:2800866", name: "Brussels", region: "Brussels Capital", lat: 50.85, lon: 4.35),
        Place(country: "GB", id: "gn:2643743", name: "London", region: "England", lat: 51.51, lon: -0.13),
        Place(country: "NL", id: "gn:2759794", name: "Amsterdam", region: "North Holland", lat: 52.37, lon: 4.89),
        Place(country: "NZ", id: "gn:2179537", name: "Wellington", region: "Wellington", lat: -41.29, lon: 174.78),
        Place(country: "ES", id: "gn:3117735", name: "Madrid", region: "Madrid", lat: 40.42, lon: -3.7),
        Place(country: "DE", id: "gn:2950159", name: "Berlin", region: "Berlin", lat: 52.52, lon: 13.41),
    ]

    public static func demoPlaces(_ q: String) -> [Place] {
        let f = fold(q.jsTrim())
        if f.count < 2 { return [] }
        return demoPlaces.filter { fold($0.name ?? "").hasPrefix(f) }
    }
}

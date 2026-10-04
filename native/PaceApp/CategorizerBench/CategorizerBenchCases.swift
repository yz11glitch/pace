#if DEBUG
import Foundation
import PaceCore

/// Fixtures for the Apple Foundation Models first-seen merchant benchmark.
/// An engineering benchmark of Malaysian naming patterns, not a statistically
/// representative sample of Malaysian merchants. Ground truth is conservative:
/// when the right category depends on what was bought, the case accepts
/// abstention (`abstainOr`) or requires it (`abstain`).
nonisolated enum BenchGroup: String, Codable, CaseIterable, Sendable {
    case personal, obvious, local, ambiguous, hard
}

nonisolated enum BenchVariant: String, Codable, CaseIterable, Sendable {
    /// Merchant (and payment method) only: Maybank, TNG and others often give no category.
    case merchantOnly
    /// A payment-app category consistent with the merchant.
    case usefulSource
    /// A payment-app category that is wrong or uninformative.
    case noisySource
}

nonisolated enum BenchExpectation: Codable, Hashable, Sendable {
    /// Any listed category is correct. Abstaining is a coverage miss, not an error.
    case category([String])
    /// The name and context do not identify the business: a committed category is forced.
    case abstain
    /// Depends on the purchase: abstaining is correct, listed categories are tolerated,
    /// anything else committed is wrong.
    case abstainOr([String])

    var label: String {
        switch self {
        case let .category(list): list.joined(separator: " | ")
        case .abstain: "abstain"
        case let .abstainOr(list): "abstain (or \(list.joined(separator: " | ")))"
        }
    }
}

nonisolated struct BenchCase: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let group: BenchGroup
    let variant: BenchVariant
    let merchant: String
    let sourceCategory: String?
    let payment: String?
    let expected: BenchExpectation
    let note: String?
}

nonisolated enum BenchDataset {
    static let version = "my-merchants-v1"

    private static let FD = "Food & Drink", GR = "Groceries", TR = "Transport", SH = "Shopping"
    private static let BU = "Bills & Utilities", HE = "Health", EN = "Entertainment", ED = "Education"
    private static let SV = "Services", TV = "Travel", GD = "Gifts & Donations", OT = "Other"
    private static let qr = "DuitNow QR"

    private static func only(_ list: [String]) -> BenchExpectation { .category(list) }

    private static func c(_ group: BenchGroup, _ merchant: String, _ expected: BenchExpectation,
                          source: String? = nil, noisy: Bool = false, payment: String? = nil,
                          tag: String? = nil, note: String? = nil) -> BenchCase {
        let variant: BenchVariant = source == nil ? .merchantOnly : noisy ? .noisySource : .usefulSource
        func slug(_ text: String) -> String {
            String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }).split(separator: "-").joined(separator: "-")
        }
        let suffix = [variant == .merchantOnly ? nil : variant.rawValue, source.map(slug), tag]
            .compactMap { $0 }.joined(separator: "/")
        return BenchCase(id: suffix.isEmpty ? slug(merchant) : "\(slug(merchant))/\(suffix)", group: group, variant: variant,
                         merchant: merchant, sourceCategory: source, payment: payment, expected: expected, note: note)
    }

    static let cases: [BenchCase] = personal + obvious + local + ambiguous + hard + sourceVariants

    /// The two modelled on a field capture layouts, plus their merchant-only and misleading-source variants.
    private static let personal: [BenchCase] = [
        c(.personal, "NORTHWIND RESTAURANT", only([FD]), source: "Food & Drink", payment: qr, note: "modelled on a field capture layout"),
        c(.personal, "NORTHWIND RESTAURANT", only([FD]), payment: qr),
        c(.personal, "NORTHWIND RESTAURANT", only([FD]), source: "Wellness", noisy: true, payment: qr,
          note: "IV could read as an IV-drip wellness bar"),
        c(.personal, "KLINIK CONTOH SEJAHTERA", only([HE]), source: "Wellness", payment: qr, note: "modelled on a field capture layout"),
        c(.personal, "KLINIK CONTOH SEJAHTERA", only([HE]), payment: qr),
        c(.personal, "KLINIK CONTOH SEJAHTERA", only([HE]), tag: "no-payment"),
        c(.personal, "KLINIK CONTOH SEJAHTERA", only([HE]), source: "Food & Drink", noisy: true, payment: qr),
    ]

    private static let obvious: [BenchCase] = [
        c(.obvious, "KPJ AMPANG PUTERI SPECIALIST HOSPITAL", only([HE])),
        c(.obvious, "SUNWAY MEDICAL CENTRE", only([HE])),
        c(.obvious, "ZUS COFFEE", only([FD])),
        c(.obvious, "TEALIVE", only([FD])),
        c(.obvious, "MCDONALD'S", only([FD])),
        c(.obvious, "KFC", only([FD])),
        c(.obvious, "STARBUCKS", only([FD])),
        c(.obvious, "SECRET RECIPE", only([FD])),
        c(.obvious, "GRABFOOD", only([FD])),
        c(.obvious, "SHELL", only([TR])),
        c(.obvious, "PETRONAS", only([TR])),
        c(.obvious, "TNB", only([BU]), note: "Tenaga Nasional electricity"),
        c(.obvious, "MAXIS", only([BU])),
        c(.obvious, "UNIFI", only([BU])),
        c(.obvious, "AIR SELANGOR", only([BU])),
        c(.obvious, "INDAH WATER KONSORTIUM", only([BU])),
        c(.obvious, "NETFLIX", only([EN, BU])),
        c(.obvious, "GOLDEN SCREEN CINEMAS", only([EN])),
        c(.obvious, "UNIQLO", only([SH])),
        c(.obvious, "MR DIY", only([SH])),
        c(.obvious, "IKEA", only([SH])),
        c(.obvious, "H&M", only([SH])),
        c(.obvious, "LAZADA", only([SH])),
        c(.obvious, "SHOPEE", only([SH])),
        c(.obvious, "CARING PHARMACY", only([HE])),
        c(.obvious, "BIG PHARMACY", only([HE])),
        c(.obvious, "WATSONS", only([HE, SH])),
        c(.obvious, "GUARDIAN", only([HE, SH]), note: "pharmacy / health-and-beauty chain in Malaysia"),
        c(.obvious, "99 SPEEDMART", only([GR])),
        c(.obvious, "JAYA GROCER", only([GR])),
        c(.obvious, "MYDIN", only([GR, SH])),
        c(.obvious, "LOTUS'S", only([GR])),
        c(.obvious, "GIANT HYPERMARKET", only([GR])),
        c(.obvious, "AIRASIA", only([TV])),
        c(.obvious, "MALAYSIA AIRLINES", only([TV])),
        c(.obvious, "SKYFARE", only([TV])),
        c(.obvious, "RAPID KL", only([TR])),
        c(.obvious, "PLUS MALAYSIA BERHAD", only([TR]), note: "highway tolls"),
        c(.obvious, "UNICEF MALAYSIA", only([GD])),
        c(.obvious, "TAYLOR'S UNIVERSITY", only([ED])),
        c(.obvious, "KUMON", only([ED])),
    ]

    private static let local: [BenchCase] = [
        // Restaurants, mamak, kopitiam, hawkers
        c(.local, "RESTORAN NASI KANDAR PELITA", only([FD])),
        c(.local, "MAMAK CORNER BANGSAR", only([FD])),
        c(.local, "KOPITIAM AH HOCK", only([FD])),
        c(.local, "KEDAI KOPI WAI SIK KAI", only([FD])),
        c(.local, "RESTORAN KIM LIAN KEE", only([FD])),
        c(.local, "GERAI ROTI CANAI MAK LIMAH", only([FD])),
        c(.local, "WARUNG PAK ALI", only([FD])),
        c(.local, "NASI LEMAK TANGLIN", only([FD])),
        c(.local, "BAK KUT TEH SENG HUAT KLANG", only([FD])),
        c(.local, "KEDAI MAKAN SELERA KAMPUNG", only([FD])),
        // Clinics and pharmacies
        c(.local, "KLINIK DR HAMIDAH", only([HE])),
        c(.local, "POLIKLINIK MEDIVIRON", only([HE])),
        c(.local, "KLINIK PERGIGIAN SMILE DENTAL", only([HE])),
        c(.local, "KLINIK KESIHATAN SELAYANG", only([HE])),
        c(.local, "HOSPITAL PANTAI KUALA LUMPUR", only([HE])),
        c(.local, "FARMASI ALPRO", only([HE])),
        // Petrol
        c(.local, "PETRON", only([TR])),
        c(.local, "BHPETROL", only([TR])),
        c(.local, "STESEN MINYAK PETRONAS SS2", only([TR])),
        c(.local, "SETEL", only([TR]), note: "Petronas fuel-payment app"),
        // Groceries and convenience
        c(.local, "PASAR RAYA SAKAN", only([GR])),
        c(.local, "KEDAI RUNCIT AH SENG", only([GR])),
        c(.local, "NSK TRADE CITY", only([GR])),
        c(.local, "SAYUR SEGAR ENTERPRISE", only([GR]), note: "sayur segar = fresh vegetables"),
        c(.local, "PANDAMART", only([GR])),
        c(.local, "7-ELEVEN", only([GR, FD])),
        c(.local, "FAMILYMART", only([FD, GR])),
        c(.local, "KK SUPER MART", only([GR, FD])),
        // Telcos and utilities
        c(.local, "U MOBILE", only([BU])),
        c(.local, "HOTLINK PREPAID RELOAD", only([BU])),
        c(.local, "SABAH ELECTRICITY SDN BHD", only([BU])),
        c(.local, "RANHILL SAJ", only([BU]), note: "Johor water utility"),
        // Transport
        c(.local, "KTM KOMUTER", only([TR])),
        c(.local, "SMART SELANGOR PARKING", only([TR])),
        c(.local, "SUNWAY PYRAMID PARKING", only([TR])),
        c(.local, "INDRIVE", only([TR])),
        c(.local, "KLIA EKSPRES", only([TR, TV])),
        // E-commerce and shopping
        c(.local, "TEMU", only([SH])),
        c(.local, "PADINI", only([SH])),
        c(.local, "SENHENG", only([SH])),
        c(.local, "DAISO", only([SH])),
        c(.local, "POPULAR BOOKSTORE", only([SH, ED])),
        // Entertainment
        c(.local, "MBO CINEMAS", only([EN])),
        c(.local, "RED BOX KARAOKE", only([EN])),
        c(.local, "SUNWAY LAGOON", only([EN])),
        // Education
        c(.local, "SEKOLAH KEBANGSAAN TAMAN MEGAH", only([ED])),
        c(.local, "TADIKA SERI BINTANG", only([ED]), note: "tadika = kindergarten"),
        c(.local, "PUSAT TUISYEN BESTARI", only([ED])),
        // Travel
        c(.local, "TRAVELOKA", only([TV])),
        c(.local, "HOTEL SENTRAL KUALA LUMPUR", only([TV])),
        c(.local, "BUSONLINETICKET.COM", only([TV, TR])),
        // Services
        c(.local, "KEDAI GUNTING RAMBUT RAJA", only([SV]), note: "barber"),
        c(.local, "CLEANPRO EXPRESS LAUNDRY", only([SV])),
        c(.local, "POS MALAYSIA", only([SV])),
        c(.local, "PERCETAKAN DAN FOTOSTAT MAJU", only([SV]), note: "printing and photocopy"),
        c(.local, "SERVIS KERETA AUTO JAYA", only([TR, SV])),
        // Gifts and donations
        c(.local, "LEMBAGA ZAKAT SELANGOR", only([GD])),
        c(.local, "TABUNG MASJID AL-HIDAYAH", only([GD])),
        c(.local, "KEDAI BUNGA FLORIST ROSE", only([GD, SH])),
    ]

    /// Names that do not reveal the business: the model must abstain.
    private static let ambiguous: [BenchCase] = [
        c(.ambiguous, "ABC GLOBAL SDN BHD", .abstain),
        c(.ambiguous, "MJ VENTURES SDN BHD", .abstain),
        c(.ambiguous, "SYARIKAT LIM & SONS", .abstain),
        c(.ambiguous, "PERNIAGAAN AHMAD", .abstain, note: "perniagaan = business/trading"),
        c(.ambiguous, "RJ TRADING", .abstain),
        c(.ambiguous, "KH HOLDINGS BERHAD", .abstain),
        c(.ambiguous, "SKY BLUE 2020 PLT", .abstain),
        c(.ambiguous, "M S A ENTERPRISE", .abstain),
        c(.ambiguous, "GLOBAL NETWORK SOLUTIONS", .abstain),
        c(.ambiguous, "KEDAI 88", .abstain, note: "kedai = shop"),
        c(.ambiguous, "888 TRADING", .abstain),
        c(.ambiguous, "A1 SOLUTIONS SDN BHD", .abstain),
        c(.ambiguous, "PUSAT NIAGA JAYA", .abstain),
        c(.ambiguous, "CT HAMZAH ENTERPRISE", .abstain),
        c(.ambiguous, "TAN AH KOW", .abstain, payment: qr, note: "DuitNow QR to an individual"),
        c(.ambiguous, "NURUL AIN BINTI ISMAIL", .abstain, payment: qr),
        c(.ambiguous, "MUHAMMAD HAFIZ BIN ROSLI", .abstain, payment: qr),
        c(.ambiguous, "WONG KAR WEI", .abstain, payment: qr),
        c(.ambiguous, "S. RAJENDRAN A/L SUBRAMANIAM", .abstain, payment: qr),
        c(.ambiguous, "IPAY88", .abstain, note: "payment gateway"),
        c(.ambiguous, "RAZER MERCHANT SERVICES", .abstain, note: "payment gateway"),
        c(.ambiguous, "SENANGPAY", .abstain, note: "payment gateway"),
        c(.ambiguous, "BILLPLZ", .abstain, note: "payment gateway"),
        c(.ambiguous, "DUITNOW QR", .abstain, payment: qr, note: "rail label captured instead of a payee"),
    ]

    private static let hard: [BenchCase] = [
        // Brands whose category depends on the purchase
        c(.hard, "SUNWAY", .abstain, note: "malls, hospital, university, theme park"),
        c(.hard, "GENTING", .abstainOr([EN, TV])),
        c(.hard, "AEON", .abstainOr([GR, SH])),
        c(.hard, "GRAB", .abstainOr([TR, FD])),
        c(.hard, "TOUCH N GO", .abstainOr([TR]), note: "tolls or wallet reload"),
        c(.hard, "SHOPEEPAY", .abstainOr([SH])),
        c(.hard, "BOOST", .abstain, note: "e-wallet"),
        c(.hard, "APPLE.COM/BILL", .abstainOr([BU, EN, SH])),
        c(.hard, "GOOGLE PLAY", .abstainOr([EN, SH])),
        c(.hard, "PETRONAS MESRA", .abstainOr([TR, GR, FD]), note: "station convenience store"),
        c(.hard, "SHELL SELECT", .abstainOr([TR, GR, FD]), note: "station convenience store"),
        c(.hard, "MYNEWS", .abstainOr([GR, FD, SH])),
        c(.hard, "SWITCH", .abstainOr([SH]), note: "Apple reseller; name alone reveals nothing"),
        c(.hard, "COWAY", .abstainOr([BU, SH, SV]), note: "water-purifier rental"),
        c(.hard, "ETIQA TAKAFUL", .abstainOr([BU, SV]), note: "insurance: no Pace category"),
        c(.hard, "KLINIK HAIWAN SEGAR", .abstainOr([HE, SV, OT]), note: "veterinary clinic"),
        c(.hard, "MAJLIS BANDARAYA PETALING JAYA", .abstainOr([BU, TR]), note: "assessment tax or parking"),
        c(.hard, "JABATAN PENGANGKUTAN JALAN", only([TR, BU]), note: "road tax, licences"),
        c(.hard, "PTPTN", only([ED, BU]), note: "student-loan repayment"),
        c(.hard, "ASTRO", only([BU, EN])),
        c(.hard, "ANYTIME FITNESS", only([HE, EN])),
        c(.hard, "SUBWAY", only([FD]), note: "sandwich chain; Malaysia has no subway transit brand"),
        c(.hard, "AIRASIA RIDE", only([TR])),
        // Noisy casing, OCR-like spacing and punctuation
        c(.hard, "KL1NIK LIM K0H PIT", only([HE])),
        c(.hard, "Z U S  C O F F E E", only([FD])),
        c(.hard, "MC DONALDS", only([FD])),
        c(.hard, "PETRONAS-SS2", only([TR])),
        c(.hard, "tealive @ sunway pyramid", only([FD])),
        c(.hard, "99SPEEDMART 1234", only([GR])),
        c(.hard, "TNB-BILL PAYMENT", only([BU])),
        c(.hard, "UNIQL0", only([SH])),
        c(.hard, "CARINGPHARMACY-PJ", only([HE])),
        c(.hard, "Mr.D.I.Y.", only([SH])),
        c(.hard, "KFC(M) HOLDINGS BHD", only([FD])),
        // Abbreviations
        c(.hard, "RSTRN SRI PETALING", only([FD]), note: "rstrn = restoran"),
        c(.hard, "KEDAI MKN ALI", only([FD]), note: "mkn = makan"),
        c(.hard, "KLN PERGIGIAN DR TAN", only([HE]), note: "klinik pergigian = dental clinic"),
        c(.hard, "MAXIS BROADBAND S/B", only([BU])),
        c(.hard, "PERNIAGAAN RUNCIT SITI", only([GR]), note: "runcit = sundry goods"),
        c(.hard, "STSN MNYK PETRONAS", only([TR]), note: "stesen minyak = petrol station"),
    ]

    /// Source-category variants of merchants that already appear merchant-only above,
    /// so the same merchant can be compared with no, useful and misleading source categories.
    private static let sourceVariants: [BenchCase] = [
        c(.obvious, "ZUS COFFEE", only([FD]), source: "Food & Drink"),
        c(.obvious, "ZUS COFFEE", only([FD]), source: "Shopping", noisy: true),
        c(.obvious, "TNB", only([BU]), source: "Utilities"),
        c(.obvious, "TNB", only([BU]), source: "Transfer", noisy: true),
        c(.obvious, "SHELL", only([TR]), source: "Petrol"),
        c(.obvious, "SHELL", only([TR]), source: "Shopping", noisy: true),
        c(.obvious, "MR DIY", only([SH]), source: "Shopping"),
        c(.obvious, "MR DIY", only([SH]), source: "Wellness", noisy: true),
        c(.obvious, "WATSONS", only([HE, SH]), source: "Health & Beauty"),
        c(.obvious, "WATSONS", only([HE, SH]), source: "Food & Drink", noisy: true),
        c(.obvious, "AIRASIA", only([TV]), source: "Travel"),
        c(.obvious, "AIRASIA", only([TV]), source: "Shopping", noisy: true),
        c(.obvious, "99 SPEEDMART", only([GR]), source: "Groceries"),
        c(.obvious, "99 SPEEDMART", only([GR]), source: "Transport", noisy: true),
        c(.obvious, "NETFLIX", only([EN, BU]), source: "Entertainment"),
        c(.obvious, "NETFLIX", only([EN, BU]), source: "Shopping", noisy: true),
        c(.obvious, "CARING PHARMACY", only([HE]), source: "Wellness"),
        c(.obvious, "CARING PHARMACY", only([HE]), source: "Groceries", noisy: true),
        c(.obvious, "UNIQLO", only([SH]), source: "Shopping"),
        c(.obvious, "UNIQLO", only([SH]), source: "Food & Drink", noisy: true),
        c(.local, "KLINIK DR HAMIDAH", only([HE]), source: "Wellness", payment: qr),
        c(.local, "KLINIK DR HAMIDAH", only([HE]), source: "Food & Drink", noisy: true, payment: qr),
        c(.local, "RESTORAN NASI KANDAR PELITA", only([FD]), source: "Food & Drink"),
        c(.local, "RESTORAN NASI KANDAR PELITA", only([FD]), source: "Groceries", noisy: true),
        // A useful source category resolves a purchase-dependent brand.
        c(.hard, "GRAB", only([TR]), source: "Transport"),
        c(.hard, "GRAB", only([FD]), source: "Food & Drink"),
        c(.hard, "AEON", only([GR]), source: "Groceries"),
        // Opaque names: the source category is the only evidence.
        c(.ambiguous, "ABC GLOBAL SDN BHD", only([FD]), source: "Food & Drink", note: "source is the only evidence"),
        c(.ambiguous, "MJ VENTURES SDN BHD", only([GR]), source: "Groceries", note: "source is the only evidence"),
        c(.ambiguous, "KEDAI 88", only([GR]), source: "Groceries", note: "source is the only evidence"),
        c(.ambiguous, "TAN AH KOW", only([FD]), source: "Food & Drink", payment: qr,
          note: "hawker on a personal DuitNow QR"),
        c(.ambiguous, "ABC GLOBAL SDN BHD", .abstain, source: "Others", noisy: true, note: "uninformative source"),
        c(.ambiguous, "NURUL AIN BINTI ISMAIL", .abstain, source: "Transfer", noisy: true, payment: qr,
          note: "uninformative source"),
    ]

    /// Guards against fixture typos: ids must be unique and every expected
    /// category must be one of Pace's actual expense categories.
    static var problems: [String] {
        let allowed = Set(EntryRules.categoryChoices(for: .expense))
        var issues: [String] = []
        var seen: Set<String> = []
        for item in cases {
            if !seen.insert(item.id).inserted { issues.append("duplicate id \(item.id)") }
            let listed: [String] = switch item.expected {
            case let .category(list), let .abstainOr(list): list
            case .abstain: []
            }
            if case .category([]) = item.expected { issues.append("\(item.id): empty expectation") }
            for name in listed where !allowed.contains(name) { issues.append("\(item.id): unknown category \(name)") }
        }
        return issues
    }
}
#endif

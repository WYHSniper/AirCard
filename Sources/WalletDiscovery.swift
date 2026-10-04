import Foundation

struct WalletCachedCard: Codable, Identifiable {
    let id: String
    let name: String
    let source: String
    let activationID: String?
    /// Last digits of the account, or of the device token when Wallet withholds
    /// the account suffix. Several cards can share a product name, so this is
    /// what separates one "Platinum Card" from the next.
    let suffix: String?
    let suffixKind: String?
    /// Device Account Number ending, and the date the card was added. Read only
    /// when name + account ending still leave two rows identical.
    let deviceSuffix: String?
    let addedAt: String?

    init(id: String, name: String, source: String, activationID: String? = nil, suffix: String? = nil, suffixKind: String? = nil, deviceSuffix: String? = nil, addedAt: String? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.activationID = activationID
        self.suffix = suffix
        self.suffixKind = suffixKind
        self.deviceSuffix = deviceSuffix
        self.addedAt = addedAt
    }
}

enum CardSuffix {
    static func label(_ suffix: String?) -> String? {
        guard let suffix, !suffix.isEmpty else { return nil }
        return "•••• " + suffix
    }

    static func help(_ kind: String?) -> String {
        kind == "device" ? "Device Account Number ending — Wallet reports no card number ending for this card."
                         : "Card number ending, from this Mac's Wallet cache."
    }

    /// Second and third identifiers, shown under the card ending on every row.
    /// Two cards can legitimately share a product name and the last four of the
    /// card number; the device ending and the add date are independent of both,
    /// and the row turns these orange when such a collision actually happens.
    static func tiebreakers(deviceSuffix: String?, accountSuffix: String?, addedAt: String?) -> [String] {
        var lines: [String] = []
        if let device = deviceSuffix, device != accountSuffix {
            lines.append("Device •••• " + device)
        }
        if let added = addedAt { lines.append("Added " + added) }
        return lines
    }
}

struct WalletCatalog: Codable {
    var paymentStatus: String
    var payments: [WalletCachedCard]
    var memberships: [WalletCachedCard]
    var warnings: [String]
    var cacheUpdatedAt: String?

    static let empty = WalletCatalog(paymentStatus: "unavailable", payments: [], memberships: [], warnings: [], cacheUpdatedAt: nil)

    func name(for id: String) -> String? { card(for: id)?.name }

    func card(for id: String) -> WalletCachedCard? {
        (payments + memberships).first(where: { $0.id == id })
    }

    func payment(forActivationID id: String) -> WalletCachedCard? {
        payments.first { $0.activationID?.caseInsensitiveCompare(id) == .orderedSame }
    }

    func pending(confirmedIDs: Set<String>, source: String) -> [WalletCachedCard] {
        let entries = source == "payment" ? payments : memberships
        var seen = Set<String>()
        return entries.filter { !confirmedIDs.contains($0.id) && seen.insert($0.id).inserted }
    }
}

struct WalletSavedCard: Codable, Equatable {
    let id: String
    var confirmed: Bool = false
    var imagePath: String? = nil
    var selected: Bool = true

    static func unique(_ entries: [WalletSavedCard]) -> [WalletSavedCard] {
        var result: [WalletSavedCard] = []
        var indices: [String: Int] = [:]
        for entry in entries {
            if let index = indices[entry.id] {
                result[index].confirmed = result[index].confirmed || entry.confirmed
                if result[index].imagePath == nil { result[index].imagePath = entry.imagePath }
            } else {
                indices[entry.id] = result.count
                result.append(entry)
            }
        }
        return result
    }
}

// A bare base64-like token in a Wallet log is not proof of a card.
// Require a pass/cache path, and preserve first appearance across the line.
enum WalletScanParser {
    static let cardReferences = [
        try! NSRegularExpression(pattern: #"/([-A-Za-z0-9_+=]{20,64})\.(?:pkpass|cache|pkcache)(?=[/\s\"'\),]|$)"#),
        try! NSRegularExpression(pattern: #"/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,64})(?=[/\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"PDCardFileManager:\s*writing card\s+([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"PDPassLibrary:\s*wrote pass\s+([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"VerificationCheck\.([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"selected pass uniqueID\s*:\s*\"?([-A-Za-z0-9_+=]{20,64})\"?"#, options: .caseInsensitive),
        // iOS 26 stopped logging the pass file paths this parser was built on.
        // PassKitUI names the pass it is rendering instead, which is the one
        // per-pass signal still emitted when a card is opened or tapped.
        try! NSRegularExpression(pattern: #"Dashboard loading\s*\([^)]*\)\s*:\s*([-A-Za-z0-9_+=]{20,64})\s*-"#, options: .caseInsensitive),
    ]
    static let inSessionList = try! NSRegularExpression(
        pattern: #"(?:passIDs\[InSession\]|_inSessionLimitedPassIDs)\s*[:=]\s*(?:\{\s*)?\(([^)]*)\)"#,
        options: .caseInsensitive
    )
    static let cardID = try! NSRegularExpression(pattern: #"(?<![-A-Za-z0-9_+=])[-A-Za-z0-9_+=]{20,64}(?![-A-Za-z0-9_+=])"#)
    static let activation = try! NSRegularExpression(
        pattern: #"setActivePaymentApplet.{0,4096}?requestedApplet\s*:.{0,4096}?identifier\s*=\s*([A-Fa-f0-9]{10,64})\b"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    static let placeholders: Set<String> = ["OM6NYhwXMZrAw0sRUjR62wmF4ZQ=", "M6nDwZrkYbFlsodLgCbvyFZQ1cc=", "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=", "hwAtAmHKYwsQrJbT5cTNDsaxVME="]

    static func cardIDs(in line: String) -> [String] {
        let lineRange = NSRange(line.startIndex..., in: line)
        var candidates = cardReferences.flatMap { regex in
            regex.matches(in: line, range: lineRange).compactMap { match -> (Int, String)? in
                guard let range = Range(match.range(at: 1), in: line) else { return nil }
                return (match.range.location, String(line[range]))
            }
        }
        for listMatch in inSessionList.matches(in: line, range: lineRange) {
            let listRange = listMatch.range(at: 1)
            candidates += cardID.matches(in: line, range: listRange).compactMap { match in
                guard let range = Range(match.range, in: line) else { return nil }
                return (match.range.location, String(line[range]))
            }
        }
        candidates.sort { $0.0 < $1.0 }
        var seen = Set<String>()
        return candidates.compactMap { _, id in
            guard !placeholders.contains(id), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    static func activationIDs(in line: String) -> [String] {
        activation.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: line) else { return nil }
            return String(line[range]).uppercased()
        }
    }
}

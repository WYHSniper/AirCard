import Foundation

@main
struct WalletDiscoveryTests {
    static func main() throws {
        let a = String(repeating: "A", count: 27) + "="
        let b = String(repeating: "B", count: 27) + "="
        let c = String(repeating: "C", count: 27) + "="
        let line = "Wallet /Cards/\(b).cache/Preview /Cards/\(a).pkpass/en.lproj /Cards/\(b).pkcache/FrontFace"
        precondition(WalletScanParser.cardIDs(in: line) == [b, a])
        precondition(WalletScanParser.cardIDs(in: "passd identifier \(a)").isEmpty)
        precondition(WalletScanParser.cardIDs(in: "/Cards/<private>.pkpass").isEmpty)
        let ios27Line = "nfcd: passIDs[InSession]: {(\"\(c)\")} passIDs[global]: {(\"\(a)\")}"
        precondition(WalletScanParser.cardIDs(in: ios27Line) == [c])
        let sessionCards = (0..<12).map { String(format: "%020dAAAAAAA=", $0) }
        let sessionList = sessionCards.map { "\"\($0)\"" }.joined(separator: ", ")
        let batchedIOS27Line = "nfcd: passIDs[InSession]: {(\(sessionList))} passIDs[global]: {(\"\(a)\")}"
        precondition(WalletScanParser.cardIDs(in: batchedIOS27Line) == sessionCards)
        precondition(WalletScanParser.cardIDs(in: "nfcd: passIDs[global]: {(\"\(a)\")}").isEmpty)
        // iOS 26 formats, taken from a real capture on iOS 26.6.2.
        let dashboard = "Passbook(PassKitUI): Dashboard loading (0xc5b496800): \(a) - m:NO, sm:YES, em:NO, b:YES"
        precondition(WalletScanParser.cardIDs(in: dashboard) == [a])
        precondition(WalletScanParser.cardIDs(in: "Dashboard loading (0xc5b496800): <private> - m:NO").isEmpty)
        let limited = "nfcd: -[NFExpressModeManager _updateExpressConfigWithInSessionSet:globalSet:]:1932 _inSessionLimitedPassIDs={(     \"\(c)\" )}, _globalLimitedPassIDs={(     \"\(a)\" )}, hasActiveSession=1,"
        precondition(WalletScanParser.cardIDs(in: limited) == [c], "Only the in-session list is evidence of this scan")
        precondition(WalletScanParser.cardIDs(in: "nfcd: _inSessionLimitedPassIDs=(null), _globalLimitedPassIDs=(null),").isEmpty)
        precondition(WalletScanParser.cardIDs(in: "Wallet /Passes/Cards/\(a)/FrontFace") == [a])
        precondition(WalletScanParser.cardIDs(in: "PDCardFileManager: writing card \(b)") == [b])
        precondition(WalletScanParser.cardIDs(in: "PDPassLibrary: wrote pass \(a)") == [a])
        precondition(WalletScanParser.cardIDs(in: "VerificationCheck.\(c)") == [c])
        precondition(WalletScanParser.cardIDs(in: "updated selected pass uniqueID: \(b)") == [b])
        precondition(WalletScanParser.cardIDs(in: "updated selected pass uniqueID: <private>").isEmpty)
        let activation = "A00000000310100100000020"
        let activeLine = "setActivePaymentApplet: x requestedApplet: <NFApplet> { identifier=\(activation) family=0x0 }"
        precondition(WalletScanParser.activationIDs(in: activeLine) == [activation])
        let multilineActivation = "setActivePaymentApplet: x requestedApplet:\n<NFApplet> { identifier = \(activation) family=0x0 }"
        precondition(WalletScanParser.activationIDs(in: multilineActivation) == [activation])
        let cards = [WalletSavedCard(id: b, confirmed: true, imagePath: "/skin-b.png", selected: false),
                     WalletSavedCard(id: a, imagePath: "/skin-a.png"),
                     WalletSavedCard(id: b), WalletSavedCard(id: a, confirmed: true)]
        let unique = WalletSavedCard.unique(cards)
        precondition(unique.map(\.id) == [b, a])
        precondition(unique[0].imagePath == "/skin-b.png" && !unique[0].selected)
        precondition(unique[1].imagePath == "/skin-a.png" && unique[1].confirmed)
        let restored = try JSONDecoder().decode([WalletSavedCard].self, from: JSONEncoder().encode(unique))
        precondition(restored == unique)
        let catalog = WalletCatalog(paymentStatus: "matched", payments: [
            WalletCachedCard(id: a, name: "Same bank", source: "payment", activationID: activation),
            WalletCachedCard(id: b, name: "Same bank", source: "payment")
        ], memberships: [WalletCachedCard(id: c, name: "Membership", source: "membership")], warnings: [], cacheUpdatedAt: nil)
        precondition(catalog.pending(confirmedIDs: [a], source: "payment").map(\.id) == [b])
        precondition(catalog.pending(confirmedIDs: [a], source: "membership").map(\.id) == [c])
        precondition(catalog.name(for: a) == "Same bank")
        precondition(catalog.payment(forActivationID: activation)?.id == a)
        precondition(catalog.name(for: "missing") == nil)
        // A view reorder must still attach skin B to ID B, never its old offset.
        let skins = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0.imagePath) })
        let reordered = [a, b].map { skins[$0]!! }
        precondition(reordered == ["/skin-a.png", "/skin-b.png"])
        print("Wallet identity, pending counts, deduplication, persistence and path parsing passed")
    }
}

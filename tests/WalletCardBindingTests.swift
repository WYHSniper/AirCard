import SwiftUI

@main
struct WalletCardBindingTests {
    static func main() {
        let first = CardItem(id: "first")
        let second = CardItem(id: "second")
        var storage = [first, second]
        let cards = Binding(get: { storage }, set: { storage = $0 })

        // Reproduce the old index binding using the same test sequence.
        func row(_ snapshot: CardItem, index: Int) -> Binding<CardItem> {
#if LEGACY_INDEX_BINDINGS
            return cards[index]
#else
            return walletCardBinding(in: cards, snapshot: snapshot)
#endif
        }

        let firstRow = row(first, index: 0)
        let secondRow = row(second, index: 1)
        firstRow.isSelected.wrappedValue = false
        precondition(!storage[0].isSelected)

        // The original Clear All crash: a retained binding reads an empty array.
        storage.removeAll()
        precondition(secondRow.wrappedValue.id == second.id)
        storage = [first, second]

        // A retained row must follow its card when a preceding card is deleted.
        storage.removeFirst()
        precondition(secondRow.wrappedValue.id == second.id)
        secondRow.isSelected.wrappedValue = false
        precondition(!storage[0].isSelected)
        firstRow.isSelected.wrappedValue = true
        precondition(!storage[0].isSelected, "Deleted row must not edit its replacement")

        // Clear all while SwiftUI still retains rows and nested bindings.
        let delayedImageWrite = secondRow.customImageURL
        storage.removeAll()
        precondition(secondRow.wrappedValue.id == second.id)
        delayedImageWrite.wrappedValue = URL(fileURLWithPath: "/tmp/late-image.png")
        precondition(storage.isEmpty, "Late callbacks must not resurrect deleted cards")

        // LazyVGrid may construct a row from its previous snapshot after clear.
        let lateRow = row(second, index: 1)
        precondition(lateRow.wrappedValue.id == second.id)
        lateRow.isSelected.wrappedValue = false
        precondition(storage.isEmpty)

        // Scanner appends another card after clear; stale writes must ignore it.
        storage.append(CardItem(id: "new-scan"))
        secondRow.isSelected.wrappedValue = false
        precondition(storage[0].id == "new-scan" && storage[0].isSelected)
        // Two cards of the same product must stay distinguishable by ending.
        let catalog = WalletCatalog(
            paymentStatus: "matched",
            payments: [
                WalletCachedCard(id: "plat-a", name: "Platinum Card", source: "payment", suffix: "1234", suffixKind: "account"),
                WalletCachedCard(id: "plat-b", name: "Platinum Card", source: "payment", suffix: "5678", suffixKind: "account"),
                WalletCachedCard(id: "cash", name: "Apple Cash", source: "payment"),
            ],
            memberships: [], warnings: [], cacheUpdatedAt: nil)
        var platA = CardItem(id: "plat-a", cached: catalog.card(for: "plat-a"), confirmed: true)
        let platB = CardItem(id: "plat-b", cached: catalog.card(for: "plat-b"), confirmed: true)
        precondition(platA.displayName == platB.displayName)
        precondition(platA.suffixLabel == "•••• 1234" && platB.suffixLabel == "•••• 5678",
                     "Same-named cards must show different endings")
        precondition(platA != platB, "Rows differing only by ending must not compare equal")
        precondition(CardItem(id: "cash", cached: catalog.card(for: "cash")).suffixLabel == nil)
        precondition(CardSuffix.help("device") != CardSuffix.help("account"))

        // A later cache read re-points a row at the right account.
        platA.adopt(catalog.card(for: "plat-b"))
        precondition(platA.suffixLabel == "•••• 5678" && platA.id == "plat-a")

        // Two cards sharing BOTH name and card ending fall back to independent
        // identifiers; rows that are already distinct show no extra noise.
        let collided = WalletCatalog(
            paymentStatus: "matched",
            payments: [
                WalletCachedCard(id: "x", name: "Platinum Card", source: "payment", suffix: "1234", suffixKind: "account", deviceSuffix: "4444", addedAt: "2025-01-01"),
                WalletCachedCard(id: "y", name: "Platinum Card", source: "payment", suffix: "1234", suffixKind: "account", deviceSuffix: "7777", addedAt: "2026-01-01"),
            ],
            memberships: [], warnings: [], cacheUpdatedAt: nil)
        let x = CardItem(id: "x", cached: collided.card(for: "x"), confirmed: true)
        let y = CardItem(id: "y", cached: collided.card(for: "y"), confirmed: true)
        precondition(x.identityKey == y.identityKey, "This pair is the case tiebreakers exist for")
        precondition(CardSuffix.tiebreakers(x) != CardSuffix.tiebreakers(y),
                     "Cards sharing name and ending must still differ")
        precondition(CardSuffix.tiebreakers(x) == ["Device •••• 4444", "Added 2025-01-01"])
        precondition(platB.identityKey != x.identityKey)
        // A card whose only ending IS the device ending must not repeat it.
        let transit = CardItem(id: "t", cached: WalletCachedCard(id: "t", name: "Transit", source: "payment", suffix: "4321", suffixKind: "device", deviceSuffix: "4321"))
        precondition(CardSuffix.tiebreakers(transit).isEmpty)

        print("PASS: retained rows, single deletion, clear all, late row creation, delayed image writes, scanner append, same-name card endings")
    }
}

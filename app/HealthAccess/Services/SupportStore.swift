import Foundation
import Observation
import StoreKit

/// The support card at the bottom of Home, through the App Store (StoreKit 2): one non-consumable that removes the
/// card for good, one consumable coffee that leaves it. The entitlement is whatever the App Store says
/// (`Transaction.currentEntitlements`); the settings flag only caches it so the card does not flash on launch.
@MainActor
@Observable
final class SupportStore {
    static let cardProductID = "com.healthaccessmcp.app.support.card"
    static let coffeeProductID = "com.healthaccessmcp.app.support.coffee"

    enum Availability { case loading, ready, unavailable }
    enum Outcome { case cardRemoved, coffee, cancelled, pending }

    private(set) var card: Product?
    private(set) var coffee: Product?
    private(set) var availability = Availability.loading
    /// A verified, unrevoked purchase of the card product exists.
    private(set) var cardRemoved: Bool

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var updates: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        cardRemoved = settings.supportCardRemoved
    }

    /// Loads the two products and the current entitlement, and keeps listening for transactions that finish
    /// elsewhere (Ask to Buy approvals, refunds, a purchase on another device).
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.apply(result)
            }
        }
        Task {
            await load()
            await refreshEntitlements()
        }
    }

    func load() async {
        do {
            let products = try await Product.products(for: [Self.cardProductID, Self.coffeeProductID])
            card = products.first { $0.id == Self.cardProductID }
            coffee = products.first { $0.id == Self.coffeeProductID }
            availability = (card == nil && coffee == nil) ? .unavailable : .ready
        } catch {
            availability = .unavailable
        }
    }

    /// The App Store's answer wins in both directions: a refund puts the card back. When the store did not answer at
    /// all (no products), the cached flag is kept rather than cleared.
    func refreshEntitlements() async {
        var removed = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.cardProductID, transaction.revocationDate == nil {
                removed = true
            }
        }
        if removed {
            set(cardRemoved: true)
        } else if availability == .ready {
            set(cardRemoved: false)
        }
    }

    /// Finishes a purchase the SwiftUI purchase action returned.
    func complete(_ result: Product.PurchaseResult) async throws -> Outcome {
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            if transaction.productID == Self.cardProductID {
                set(cardRemoved: true)
                return .cardRemoved
            }
            return .coffee
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        @unknown default:
            return .cancelled
        }
    }

    /// Settings → Restore purchases: asks the App Store again, for a new phone or a reinstall.
    func restore() async -> Bool {
        try? await AppStore.sync()
        await refreshEntitlements()
        return cardRemoved
    }

    private func apply(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        if transaction.productID == Self.cardProductID {
            set(cardRemoved: transaction.revocationDate == nil)
        }
        await transaction.finish()
    }

    private func set(cardRemoved: Bool) {
        self.cardRemoved = cardRemoved
        settings.supportCardRemoved = cardRemoved
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error): throw error
        case .verified(let value): return value
        }
    }
}

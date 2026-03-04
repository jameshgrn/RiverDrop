import StoreKit
import SwiftUI

private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
    switch result {
    case .unverified(_, let error):
        throw error
    case .verified(let safe):
        return safe
    }
}

@MainActor
final class StoreManager: ObservableObject {
    @Published private(set) var proProduct: Product?
    @Published private(set) var isPro = false
    @Published private(set) var isPurchasing = false
    @Published var errorMessage: String?

    private var transactionTask: Task<Void, Never>?

    static let proProductID = "com.riverdrop.pro"

    init() {
        transactionTask = Task { [weak self] in
            guard let self else { return }
            await listenForTransactions()
        }
        Task { [weak self] in
            guard let self else { return }
            await loadProducts()
            await checkEntitlements()
        }
    }

    deinit {
        transactionTask?.cancel()
    }

    func loadProducts() async {
        errorMessage = nil
        do {
            let products = try await Product.products(for: [Self.proProductID])
            proProduct = products.first
        } catch {
            errorMessage = "Load products failed: \(error.localizedDescription). Suggested fix: check network connection and retry."
        }
    }

    func purchase() async {
        errorMessage = nil
        guard let product = proProduct else {
            errorMessage = "Purchase failed: product not loaded. Suggested fix: wait for products to load and retry."
            return
        }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                isPro = true
            case .userCancelled:
                break
            case .pending:
                errorMessage = "Purchase pending approval. You'll get access once approved."
            @unknown default:
                break
            }
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription). Suggested fix: check Apple ID payment settings and retry."
        }
    }

    func restorePurchases() async {
        errorMessage = nil
        do {
            try await AppStore.sync()
            await checkEntitlements()
        } catch {
            errorMessage = "Restore purchases failed: \(error.localizedDescription). Suggested fix: verify you're signed in with the Apple ID used for the original purchase."
        }
    }

    func checkEntitlements() async {
        var foundPro = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.proProductID,
               transaction.revocationDate == nil
            {
                foundPro = true
                break
            }
        }
        isPro = foundPro
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            if case .verified(let transaction) = result {
                await transaction.finish()
                if transaction.productID == Self.proProductID {
                    isPro = transaction.revocationDate == nil
                }
            }
        }
    }
}

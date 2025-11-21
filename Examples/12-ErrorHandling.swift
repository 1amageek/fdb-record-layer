// Example 12: Error Handling and Best Practices
// This example demonstrates proper error handling, transaction retry logic,
// conflict resolution, and deadlock avoidance.

import Foundation
import FoundationDB
import FDBRecordCore
import FDBRecordLayer

// MARK: - Model Definition

@Recordable
struct Product {
    #PrimaryKey<Product>([\.productID])

    var productID: Int64
    var name: String
    var stock: Int
}

@Recordable
struct Account {
    #PrimaryKey<Account>([\.accountID])

    var accountID: Int64
    var name: String
    var balance: Double
}

// MARK: - Retry Helper Functions

func saveWithRetry<T: Recordable>(
    _ record: T,
    store: RecordStore<T>,
    maxRetries: Int = 3
) async throws {
    var attempt = 0

    while attempt < maxRetries {
        do {
            try await store.save(record)
            return  // Success
        } catch let error as FDB.Error {
            // Retryable errors
            if error.isRetryable {
                attempt += 1
                if attempt >= maxRetries {
                    throw RecordLayerError.internalError("Max retries exceeded: \(error)")
                }

                // Exponential backoff
                let delay = UInt64(pow(2.0, Double(attempt)) * 100_000_000)  // 0.1, 0.2, 0.4s
                print("  ⚠️ Retrying (\(attempt)/\(maxRetries))...")
                try await Task.sleep(nanoseconds: delay)
                continue
            }

            // Non-retryable errors: throw immediately
            throw error
        }
    }
}

// MARK: - Optimistic Concurrency Control

func updateProductStock(
    productID: Int64,
    quantity: Int,
    store: RecordStore<Product>
) async throws {
    var retries = 0
    let maxRetries = 10

    while retries < maxRetries {
        do {
            // Read current stock
            guard var product = try await store.record(for: productID) else {
                throw RecordLayerError.recordNotFound("Product \(productID) not found")
            }

            // Update stock
            product.stock += quantity

            // Save (conflict may occur here)
            try await store.save(product)
            return  // Success

        } catch let error as FDB.Error where error.isRetryable {
            retries += 1
            if retries >= maxRetries {
                throw RecordLayerError.internalError("Failed to update stock after \(maxRetries) retries")
            }

            // Short delay before retry
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
    }
}

// MARK: - Deadlock Avoidance

func transferFunds(
    fromAccountID: Int64,
    toAccountID: Int64,
    amount: Double,
    database: any DatabaseProtocol,
    store: RecordStore<Account>
) async throws {
    // ✅ Always access accounts in consistent order (by ID)
    let (firstID, secondID) = fromAccountID < toAccountID
        ? (fromAccountID, toAccountID)
        : (toAccountID, fromAccountID)

    try await database.withTransaction { transaction in
        // Always read in order: smallest ID first
        var account1 = try await store.record(for: firstID)!
        var account2 = try await store.record(for: secondID)!

        // Apply transaction
        if firstID == fromAccountID {
            account1.balance -= amount
            account2.balance += amount
        } else {
            account1.balance += amount
            account2.balance -= amount
        }

        try await store.save(account1)
        try await store.save(account2)
    }
}

// ❌ Bad example: Random access order (can cause deadlock)
func transferFundsBad(
    fromAccountID: Int64,
    toAccountID: Int64,
    amount: Double,
    store: RecordStore<Account>
) async throws {
    var fromAccount = try await store.record(for: fromAccountID)!  // Deadlock risk
    var toAccount = try await store.record(for: toAccountID)!

    fromAccount.balance -= amount
    toAccount.balance += amount

    try await store.save(fromAccount)
    try await store.save(toAccount)
}

// MARK: - Transaction Scope Best Practices

func updateLastLoginGood(
    userID: Int64,
    database: any DatabaseProtocol,
    store: RecordStore<Account>
) async throws {
    // ✅ Small transaction: only essential operations
    try await database.withTransaction { transaction in
        var account = try await store.record(for: userID)!
        // Update in-memory only (fast)
        try await store.save(account)
    }
}

// ❌ Bad example: Transaction too large
func updateLastLoginBad(
    userID: Int64,
    database: any DatabaseProtocol,
    store: RecordStore<Account>
) async throws {
    try await database.withTransaction { transaction in
        // ❌ External API call (may take >5 seconds)
        // let userData = try await fetchFromExternalAPI(userID)

        var account = try await store.record(for: userID)!
        // account.data = userData
        try await store.save(account)
    }
}

// ✅ Correct: External API outside transaction
func updateLastLoginCorrect(
    userID: Int64,
    database: any DatabaseProtocol,
    store: RecordStore<Account>
) async throws {
    // External API call outside transaction
    // let userData = try await fetchFromExternalAPI(userID)

    try await database.withTransaction { transaction in
        var account = try await store.record(for: userID)!
        // account.data = userData
        try await store.save(account)
    }
}

// MARK: - Example Usage

@main
struct ErrorHandlingExample {
    static func main() async throws {
        // Initialize
        try FDBNetwork.shared.initialize(version: 710)
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        // Product store
        let productSchema = Schema([Product.self])
        let productSubspace = Subspace(prefix: Tuple("examples", "error", "products").pack())
        let productStore = RecordStore<Product>(
            database: database,
            subspace: productSubspace,
            schema: productSchema,
            statisticsManager: NullStatisticsManager()
        )

        // Account store
        let accountSchema = Schema([Account.self])
        let accountSubspace = Subspace(prefix: Tuple("examples", "error", "accounts").pack())
        let accountStore = RecordStore<Account>(
            database: database,
            subspace: accountSubspace,
            schema: accountSchema,
            statisticsManager: NullStatisticsManager()
        )

        print("🛡️ Error handling example initialized")

        // MARK: - Retry Example

        print("\n🔄 Testing retry logic...")
        let newProduct = Product(productID: 1, name: "Test Product", stock: 100)

        do {
            try await saveWithRetry(newProduct, store: productStore)
            print("✅ Product saved successfully (with retry protection)")
        } catch {
            print("❌ Failed after max retries: \(error)")
        }

        // MARK: - Optimistic Concurrency Control

        print("\n🔒 Testing optimistic concurrency control...")
        do {
            try await updateProductStock(productID: 1, quantity: -10, store: productStore)
            print("✅ Stock updated successfully (OCC protected)")

            let updated = try await productStore.record(for: 1)!
            print("   New stock: \(updated.stock)")
        } catch {
            print("❌ Stock update failed: \(error)")
        }

        // MARK: - Deadlock Avoidance

        print("\n🔐 Testing deadlock avoidance...")

        // Create accounts
        let account1 = Account(accountID: 1, name: "Alice", balance: 1000.0)
        let account2 = Account(accountID: 2, name: "Bob", balance: 500.0)
        try await accountStore.save(account1)
        try await accountStore.save(account2)
        print("✅ Created accounts")

        // Safe transfer (ordered access)
        do {
            try await transferFunds(
                fromAccountID: 1,
                toAccountID: 2,
                amount: 100.0,
                database: database,
                store: accountStore
            )
            print("✅ Funds transferred safely (deadlock-free)")

            let updatedAlice = try await accountStore.record(for: 1)!
            let updatedBob = try await accountStore.record(for: 2)!
            print("   Alice: $\(updatedAlice.balance)")
            print("   Bob: $\(updatedBob.balance)")
        } catch {
            print("❌ Transfer failed: \(error)")
        }

        // MARK: - Best Practices Summary

        print("\n📋 Error Handling Best Practices:")
        print("   ✅ Retry transient errors with exponential backoff")
        print("   ✅ Classify errors: retryable vs non-retryable")
        print("   ✅ Use OCC for concurrent updates")
        print("   ✅ Access resources in consistent order (deadlock prevention)")
        print("   ✅ Keep transactions small (<5s, <10MB)")
        print("   ✅ External API calls outside transactions")
        print("   ✅ Log error details for debugging")

        print("\n🎉 Error handling example completed!")
    }
}

import Foundation
import FoundationDB
import FDBRecordLayer

/// Partition example demonstrating multi-tenant architecture
///
/// This example shows:
/// - Using #Directory with .partition layer for tenant isolation
/// - Multi-level partitioning (tenant → channel → messages)
/// - Type-safe partition key handling
/// - Cross-tenant data isolation
/// - Per-tenant analytics

// MARK: - Message Record (Multi-Level Partition)

@Recordable
struct Message {
    // Multi-level partition: tenants/{tenantID}/channels/{channelID}/messages
    #Directory<Message>(
        "tenants",
        Field(\Message.tenantID),
        "channels",
        Field(\Message.channelID),
        "messages",
        layer: .partition
    )

    #Index<Message>([\authorID])
    #Index<Message>([\createdAt])

    @PrimaryKey var messageID: Int64
    var tenantID: String  // First partition key
    var channelID: String  // Second partition key
    var authorID: Int64
    var content: String

    @Default(value: Date())
    var createdAt: Date
}

// MARK: - Main Example

@main
struct PartitionExample {
    static func main() async {
        print("FDB Record Layer - Partition Example")
        print("====================================\n")

        do {
            // Initialize FoundationDB network (once per process)
            try await FDB.startNetwork()
            defer {
                // Ensure network is stopped on exit
                try? FDB.stopNetwork()
            }

            try await runExample()
        } catch {
            print("❌ Error: \(error)")
            print("\nTroubleshooting:")
            print("  1. Ensure FoundationDB is running: brew services start foundationdb")
            print("  2. Check status: fdbcli --exec 'status'")
            print("\nNote: This example exits with code 1 to indicate failure (important for CI/scripts).")
            exit(1)
        }
    }

    static func runExample() async throws {
        // Open database connection
        print("1. Connecting to FoundationDB...")
        let database = try await FDB.open()
        print("   ✓ Connected to FoundationDB\n")

        // Create schema
        print("2. Creating schema...")
        let schema = Schema([Message.self])
        print("   ✓ Schema created with Message type\n")

        // Open record stores for different tenants and channels
        print("3. Opening partitioned record stores...")

        // Tenant A, Channel "general"
        let tenantAGeneralStore = try await Message.store(
            tenantID: "tenant-A",
            channelID: "general",
            database: database,
            schema: schema
        )
        print("   ✓ Opened: tenants/tenant-A/channels/general/messages")

        // Tenant A, Channel "engineering"
        let tenantAEngineeringStore = try await Message.store(
            tenantID: "tenant-A",
            channelID: "engineering",
            database: database,
            schema: schema
        )
        print("   ✓ Opened: tenants/tenant-A/channels/engineering/messages")

        // Tenant B, Channel "general"
        let tenantBGeneralStore = try await Message.store(
            tenantID: "tenant-B",
            channelID: "general",
            database: database,
            schema: schema
        )
        print("   ✓ Opened: tenants/tenant-B/channels/general/messages\n")

        // Create messages for Tenant A, General channel
        print("4. Creating messages in Tenant A / General...")
        let msg1 = Message(
            messageID: 1,
            tenantID: "tenant-A",
            channelID: "general",
            authorID: 101,
            content: "Hello from Tenant A!",
            createdAt: Date()
        )

        let msg2 = Message(
            messageID: 2,
            tenantID: "tenant-A",
            channelID: "general",
            authorID: 102,
            content: "Welcome to the general channel!",
            createdAt: Date()
        )

        try await tenantAGeneralStore.save(msg1)
        try await tenantAGeneralStore.save(msg2)
        print("   ✓ Created 2 messages\n")

        // Create messages for Tenant A, Engineering channel
        print("5. Creating messages in Tenant A / Engineering...")
        let msg3 = Message(
            messageID: 3,
            tenantID: "tenant-A",
            channelID: "engineering",
            authorID: 101,
            content: "Discussing the new feature...",
            createdAt: Date()
        )

        let msg4 = Message(
            messageID: 4,
            tenantID: "tenant-A",
            channelID: "engineering",
            authorID: 103,
            content: "I'll review the PR today",
            createdAt: Date()
        )

        try await tenantAEngineeringStore.save(msg3)
        try await tenantAEngineeringStore.save(msg4)
        print("   ✓ Created 2 messages\n")

        // Create messages for Tenant B, General channel
        print("6. Creating messages in Tenant B / General...")
        let msg5 = Message(
            messageID: 1,  // Same ID as Tenant A, but isolated
            tenantID: "tenant-B",
            channelID: "general",
            authorID: 201,
            content: "Hello from Tenant B!",
            createdAt: Date()
        )

        let msg6 = Message(
            messageID: 2,
            tenantID: "tenant-B",
            channelID: "general",
            authorID: 202,
            content: "Different tenant, different data",
            createdAt: Date()
        )

        try await tenantBGeneralStore.save(msg5)
        try await tenantBGeneralStore.save(msg6)
        print("   ✓ Created 2 messages\n")

        // Query: Get all messages in Tenant A / General
        print("7. Querying Tenant A / General messages...")
        let tenantAGeneralMessages = try await tenantAGeneralStore.query(Message.self)
            .execute()

        print("   ✓ Found \(tenantAGeneralMessages.count) message(s):")
        for msg in tenantAGeneralMessages {
            print("     - ID \(msg.messageID) by author \(msg.authorID): \"\(msg.content)\"")
        }
        print()

        // Query: Get all messages in Tenant A / Engineering
        print("8. Querying Tenant A / Engineering messages...")
        let tenantAEngineeringMessages = try await tenantAEngineeringStore.query(Message.self)
            .execute()

        print("   ✓ Found \(tenantAEngineeringMessages.count) message(s):")
        for msg in tenantAEngineeringMessages {
            print("     - ID \(msg.messageID) by author \(msg.authorID): \"\(msg.content)\"")
        }
        print()

        // Query: Get all messages in Tenant B / General
        print("9. Querying Tenant B / General messages...")
        let tenantBGeneralMessages = try await tenantBGeneralStore.query(Message.self)
            .execute()

        print("   ✓ Found \(tenantBGeneralMessages.count) message(s):")
        for msg in tenantBGeneralMessages {
            print("     - ID \(msg.messageID) by author \(msg.authorID): \"\(msg.content)\"")
        }
        print()

        // Query by author within a partition
        print("10. Querying messages by author 101 in Tenant A / General...")
        let author101Messages = try await tenantAGeneralStore.query(Message.self)
            .where(\.authorID, .equals, Int64(101))
            .execute()

        print("   ✓ Found \(author101Messages.count) message(s) by author 101\n")

        // Demonstrate partition isolation
        print("11. Demonstrating partition isolation...")
        print("   - Tenant A / General has messageID=1 and messageID=2")
        print("   - Tenant B / General ALSO has messageID=1 and messageID=2")
        print("   - They are completely isolated!")

        let tenantAMsg1: Message? = try await tenantAGeneralStore.fetch(by: Int64(1))
        let tenantBMsg1: Message? = try await tenantBGeneralStore.fetch(by: Int64(1))

        if let msgA = tenantAMsg1, let msgB = tenantBMsg1 {
            print("   ✓ Tenant A message: \"\(msgA.content)\"")
            print("   ✓ Tenant B message: \"\(msgB.content)\"")
            print("   ✓ Same ID, different data - perfect isolation!\n")
        }

        // Update a message
        print("12. Updating message...")
        var updatedMsg = msg1
        updatedMsg.content = "Updated: Hello from Tenant A!"
        try await tenantAGeneralStore.save(updatedMsg)
        print("   ✓ Updated message 1 in Tenant A / General\n")

        // Delete a message
        print("13. Deleting message...")
        try await tenantBGeneralStore.delete(by: Int64(2))
        print("   ✓ Deleted message 2 from Tenant B / General\n")

        // Final statistics per partition
        print("14. Final statistics per partition...")
        let finalTenantAGeneral = try await tenantAGeneralStore.query(Message.self).execute()
        let finalTenantAEngineering = try await tenantAEngineeringStore.query(Message.self).execute()
        let finalTenantBGeneral = try await tenantBGeneralStore.query(Message.self).execute()

        print("   ✓ Tenant A / General: \(finalTenantAGeneral.count) messages")
        print("   ✓ Tenant A / Engineering: \(finalTenantAEngineering.count) messages")
        print("   ✓ Tenant B / General: \(finalTenantBGeneral.count) messages\n")

        print("Example completed successfully!")
        print("\nKey Concepts Demonstrated:")
        print("  • Multi-level partitioning (tenant → channel)")
        print("  • Complete data isolation between tenants")
        print("  • Same primary keys across partitions")
        print("  • Type-safe partition key handling")
        print("  • Per-partition queries and analytics")
        print("  • Automatic store() method with partition parameters")
        print("\nUse Cases:")
        print("  • Multi-tenant SaaS applications")
        print("  • Chat/messaging platforms")
        print("  • Document management systems")
        print("  • E-commerce order management")
        print("  • Any application requiring strict tenant isolation")
    }
}

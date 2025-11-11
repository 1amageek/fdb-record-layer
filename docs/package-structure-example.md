# パッケージ構造の具体例

## ディレクトリ構造

```
fdb-record-layer/
├── Package.swift
├── README.md
│
├── Sources/
│   ├── FDBRecordCore/              # 【共通レイヤー】クライアント・サーバー共有
│   │   ├── Protocols/
│   │   │   ├── Record.swift
│   │   │   └── RecordMetadata.swift
│   │   ├── Serialization/
│   │   │   ├── RecordCoder.swift
│   │   │   └── CodingHelpers.swift
│   │   └── Macros.swift            # マクロ定義（API）
│   │
│   ├── FDBRecordCoreMacros/        # 【共通レイヤー】マクロ実装
│   │   ├── RecordMacro.swift       # @Record
│   │   ├── IDMacro.swift           # @ID
│   │   ├── TransientMacro.swift    # @Transient
│   │   ├── DefaultMacro.swift      # @Default
│   │   └── Plugin.swift
│   │
│   ├── FDBRecordServer/            # 【サーバーレイヤー】サーバー専用
│   │   ├── Store/
│   │   │   ├── RecordStore.swift
│   │   │   ├── RecordStoreState.swift
│   │   │   └── Schema.swift
│   │   ├── Index/
│   │   │   ├── IndexManager.swift
│   │   │   ├── IndexDefinition.swift
│   │   │   ├── IndexMaintainer.swift
│   │   │   └── Maintainers/
│   │   │       ├── ValueIndexMaintainer.swift
│   │   │       ├── CountIndexMaintainer.swift
│   │   │       └── SumIndexMaintainer.swift
│   │   ├── Query/
│   │   │   ├── RecordQueryPlanner.swift
│   │   │   ├── QueryPlan.swift
│   │   │   └── QueryExecutor.swift
│   │   ├── Directory/
│   │   │   └── DirectoryConfiguration.swift
│   │   ├── Extensions/
│   │   │   └── Record+Server.swift
│   │   └── Macros.swift            # サーバーマクロ定義（API）
│   │
│   ├── FDBRecordServerMacros/      # 【サーバーレイヤー】サーバーマクロ実装
│   │   ├── ServerIndexMacro.swift  # #ServerIndex
│   │   ├── ServerUniqueMacro.swift # #ServerUnique
│   │   ├── ServerDirectoryMacro.swift # #ServerDirectory
│   │   └── Plugin.swift
│   │
│   └── FDBRecordClient/            # 【クライアントレイヤー】クライアント専用（将来）
│       ├── Sync/
│       │   ├── RecordSyncManager.swift
│       │   └── ConflictResolver.swift
│       └── Cache/
│           └── RecordCache.swift
│
├── Tests/
│   ├── FDBRecordCoreTests/
│   │   ├── MacroTests/
│   │   │   ├── RecordMacroTests.swift
│   │   │   └── IDMacroTests.swift
│   │   └── SerializationTests/
│   │       └── RecordCoderTests.swift
│   │
│   └── FDBRecordServerTests/
│       ├── StoreTests/
│       │   └── RecordStoreTests.swift
│       ├── IndexTests/
│       │   └── IndexManagerTests.swift
│       └── QueryTests/
│           └── QueryPlannerTests.swift
│
└── Examples/
    ├── SharedModels/               # クライアント・サーバー共有モデル
    │   └── Models.swift
    │
    ├── ServerApp/                  # サーバーサイドアプリ
    │   ├── main.swift
    │   └── Models+Server.swift
    │
    └── ClientApp/                  # クライアントアプリ
        └── ContentView.swift
```

---

## FDBRecordCore（共通レイヤー）

### Record.swift

```swift
// Sources/FDBRecordCore/Protocols/Record.swift

/// 永続化可能なレコード型の基本プロトコル
public protocol Record: Identifiable, Codable, Sendable {
    /// プライマリキーの型
    associatedtype ID: Hashable & Codable & Sendable

    /// レコードタイプ名（Protobuf互換性のため）
    static var recordName: String { get }

    /// プライマリキー
    var id: ID { get }

    /// メタデータ記述子（マクロが生成）
    static var __recordMetadata: RecordMetadataDescriptor { get }
}
```

### RecordMetadata.swift

```swift
// Sources/FDBRecordCore/Protocols/RecordMetadata.swift

/// レコードのメタデータ記述子
public struct RecordMetadataDescriptor: Sendable {
    public let recordName: String
    public let primaryKeyPath: AnyKeyPath
    public let fields: [FieldDescriptor]

    public init(
        recordName: String,
        primaryKeyPath: AnyKeyPath,
        fields: [FieldDescriptor]
    ) {
        self.recordName = recordName
        self.primaryKeyPath = primaryKeyPath
        self.fields = fields
    }

    public struct FieldDescriptor: Sendable {
        public let name: String
        public let keyPath: AnyKeyPath
        public let fieldNumber: Int
        public let isTransient: Bool
        public let defaultValue: (any Sendable)?

        public init(
            name: String,
            keyPath: AnyKeyPath,
            fieldNumber: Int,
            isTransient: Bool = false,
            defaultValue: (any Sendable)? = nil
        ) {
            self.name = name
            self.keyPath = keyPath
            self.fieldNumber = fieldNumber
            self.isTransient = isTransient
            self.defaultValue = defaultValue
        }
    }
}
```

### Macros.swift（共通マクロAPI）

```swift
// Sources/FDBRecordCore/Macros.swift

/// クライアント・サーバー共通のレコードマクロ
@attached(member, names: named(id), named(recordName), named(__recordMetadata))
@attached(extension, conformances: Record)
public macro Record() = #externalMacro(module: "FDBRecordCoreMacros", type: "RecordMacro")

/// プライマリキーのマーク
@attached(peer)
public macro ID() = #externalMacro(module: "FDBRecordCoreMacros", type: "IDMacro")

/// トランジェントフィールド
@attached(peer)
public macro Transient() = #externalMacro(module: "FDBRecordCoreMacros", type: "TransientMacro")

/// デフォルト値
@attached(peer)
public macro Default(value: Any) = #externalMacro(module: "FDBRecordCoreMacros", type: "DefaultMacro")
```

---

## FDBRecordServer（サーバーレイヤー）

### Macros.swift（サーバーマクロAPI）

```swift
// Sources/FDBRecordServer/Macros.swift

/// サーバーサイドのインデックス定義
@freestanding(declaration)
public macro ServerIndex<T: Record>(_ indices: [PartialKeyPath<T>]..., name: String? = nil) =
    #externalMacro(module: "FDBRecordServerMacros", type: "ServerIndexMacro")

/// サーバーサイドのユニーク制約
@freestanding(declaration)
public macro ServerUnique<T: Record>(_ constraints: [PartialKeyPath<T>]...) =
    #externalMacro(module: "FDBRecordServerMacros", type: "ServerUniqueMacro")

/// サーバーサイドのディレクトリ設定
@freestanding(declaration)
public macro ServerDirectory<T: Record>(
    _ pathElements: any DirectoryPathElement...,
    layer: DirectoryLayerType = .recordStore
) = #externalMacro(module: "FDBRecordServerMacros", type: "ServerDirectoryMacro")

/// ディレクトリレイヤータイプ
public enum DirectoryLayerType: Sendable {
    case partition
    case recordStore
    case custom(String)
}

/// ディレクトリパス要素
public protocol DirectoryPathElement {
    associatedtype Value
    var value: Value { get }
}

public struct Path: DirectoryPathElement, ExpressibleByStringLiteral {
    public let value: String
    public init(stringLiteral value: String) { self.value = value }
}

extension String: DirectoryPathElement {
    public var value: String { self }
}

public struct Field<Root>: DirectoryPathElement {
    public var value: PartialKeyPath<Root>
    public init(_ keyPath: PartialKeyPath<Root>) { self.value = keyPath }
}
```

### IndexDefinition.swift

```swift
// Sources/FDBRecordServer/Index/IndexDefinition.swift
import FDBRecordCore

/// インデックス定義（サーバー専用）
public struct IndexDefinition<Record: FDBRecordCore.Record>: Sendable {
    public let name: String
    public let type: IndexType
    public let keyPaths: [PartialKeyPath<Record>]

    public enum IndexType: Sendable {
        case value
        case count
        case sum
        case min
        case max
        case unique
    }

    public static func value(
        name: String,
        keyPaths: [PartialKeyPath<Record>]
    ) -> IndexDefinition<Record> {
        IndexDefinition(name: name, type: .value, keyPaths: keyPaths)
    }

    public static func unique(
        name: String,
        keyPaths: [PartialKeyPath<Record>]
    ) -> IndexDefinition<Record> {
        IndexDefinition(name: name, type: .unique, keyPaths: keyPaths)
    }
}
```

### DirectoryConfiguration.swift

```swift
// Sources/FDBRecordServer/Directory/DirectoryConfiguration.swift
import FDBRecordCore

/// ディレクトリ設定（サーバー専用）
public struct DirectoryConfiguration: Sendable {
    public let pathTemplate: [PathElement]
    public let layerType: LayerType

    public enum PathElement: Sendable {
        case literal(String)
        case field(AnyKeyPath)
    }

    public enum LayerType: Sendable {
        case partition
        case recordStore
        case custom(String)
    }

    public init(
        pathTemplate: [PathElement],
        layerType: LayerType = .recordStore
    ) {
        self.pathTemplate = pathTemplate
        self.layerType = layerType
    }
}
```

---

## 使用例

### SharedModels（クライアント・サーバー共通）

```swift
// Examples/SharedModels/Models.swift
import FDBRecordCore

@Record
public struct User {
    @ID public var userID: Int64
    public var email: String
    public var name: String
    public var age: Int

    @Default(value: Date())
    public var createdAt: Date

    @Transient
    public var isLoggedIn: Bool = false

    public init(
        userID: Int64,
        email: String,
        name: String,
        age: Int,
        createdAt: Date = Date(),
        isLoggedIn: Bool = false
    ) {
        self.userID = userID
        self.email = email
        self.name = name
        self.age = age
        self.createdAt = createdAt
        self.isLoggedIn = isLoggedIn
    }
}

@Record
public struct Order {
    @ID public var orderID: Int64
    public var tenantID: String
    public var userID: Int64
    public var amount: Double
    public var status: String

    public init(
        orderID: Int64,
        tenantID: String,
        userID: Int64,
        amount: Double,
        status: String
    ) {
        self.orderID = orderID
        self.tenantID = tenantID
        self.userID = userID
        self.amount = amount
        self.status = status
    }
}
```

### ServerApp（サーバー側）

```swift
// Examples/ServerApp/Models+Server.swift
import FDBRecordCore
import FDBRecordServer
import SharedModels

// ========================================
// User のサーバーサイド拡張
// ========================================
extension User {
    /// インデックス定義
    static let serverIndexes: [IndexDefinition<User>] = {
        #ServerIndex<User>([\.email], name: "email_index")
        #ServerUnique<User>([\.email])
        #ServerIndex<User>([\.name, \.age], name: "name_age_index")
    }()

    /// ディレクトリ設定
    static let serverDirectory: DirectoryConfiguration = {
        #ServerDirectory<User>("app", "users")
    }()

    /// RecordStore を開く
    static func openStore(
        database: any DatabaseProtocol,
        schema: Schema
    ) async throws -> RecordStore<User> {
        let dir = try await database.directoryLayer.createOrOpen(
            path: ["app", "users"],
            type: nil
        )

        return RecordStore(
            database: database,
            subspace: dir.subspace,
            schema: schema,
            indexes: serverIndexes
        )
    }
}

// ========================================
// Order のサーバーサイド拡張（マルチテナント）
// ========================================
extension Order {
    /// インデックス定義
    static let serverIndexes: [IndexDefinition<Order>] = {
        #ServerIndex<Order>([\.userID], name: "user_id_index")
        #ServerIndex<Order>([\.status], name: "status_index")
        #ServerIndex<Order>([\.amount], name: "amount_index")
    }()

    /// ディレクトリ設定（パーティション）
    static let serverDirectory: DirectoryConfiguration = {
        #ServerDirectory<Order>(
            "tenants",
            Field(\.tenantID),
            "orders",
            layer: .partition
        )
    }()

    /// RecordStore を開く（テナント指定）
    static func openStore(
        tenantID: String,
        database: any DatabaseProtocol,
        schema: Schema
    ) async throws -> RecordStore<Order> {
        let dir = try await database.directoryLayer.createOrOpen(
            path: ["tenants", tenantID, "orders"],
            type: .partition
        )

        return RecordStore(
            database: database,
            subspace: dir.subspace,
            schema: schema,
            indexes: serverIndexes
        )
    }
}
```

```swift
// Examples/ServerApp/main.swift
import FDBRecordCore
import FDBRecordServer
import SharedModels
import FoundationDB

let database = try await FDB.connect()
let schema = Schema([User.self, Order.self])

// ユーザーストアを開く
let userStore = try await User.openStore(
    database: database,
    schema: schema
)

// オーダーストアを開く（テナント: "tenant-123"）
let orderStore = try await Order.openStore(
    tenantID: "tenant-123",
    database: database,
    schema: schema
)

// ユーザーを作成
let user = User(
    userID: 1,
    email: "alice@example.com",
    name: "Alice",
    age: 30
)
try await userStore.save(user)

// オーダーを作成
let order = Order(
    orderID: 1001,
    tenantID: "tenant-123",
    userID: 1,
    amount: 199.99,
    status: "pending"
)
try await orderStore.save(order)

// クエリ実行
let users = try await userStore.query(User.self)
    .where(\.email, .equals, "alice@example.com")
    .execute()

print("Found users: \(users)")
```

### ClientApp（クライアント側）

```swift
// Examples/ClientApp/ContentView.swift
import SwiftUI
import FDBRecordCore
import SharedModels

struct UserListView: View {
    @State private var users: [User] = []
    @State private var orders: [Order] = []

    var body: some View {
        NavigationView {
            List {
                Section("Users") {
                    ForEach(users) { user in
                        VStack(alignment: .leading) {
                            Text(user.name)
                                .font(.headline)
                            Text(user.email)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Age: \(user.age)")
                                .font(.caption)
                        }
                    }
                }

                Section("Orders") {
                    ForEach(orders) { order in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Order #\(order.orderID)")
                                    .font(.headline)
                                Text("Status: \(order.status)")
                                    .font(.caption)
                            }
                            Spacer()
                            Text("$\(order.amount, specifier: "%.2f")")
                                .font(.headline)
                        }
                    }
                }
            }
            .navigationTitle("Records")
        }
        .task {
            await loadData()
        }
    }

    func loadData() async {
        do {
            // JSON API からデータを取得
            let usersData = try await fetchUsers()
            users = try JSONDecoder().decode([User].self, from: usersData)

            let ordersData = try await fetchOrders()
            orders = try JSONDecoder().decode([Order].self, from: ordersData)
        } catch {
            print("Error loading data: \(error)")
        }
    }

    func fetchUsers() async throws -> Data {
        // API リクエスト実装
        let url = URL(string: "https://api.example.com/users")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    func fetchOrders() async throws -> Data {
        // API リクエスト実装
        let url = URL(string: "https://api.example.com/orders")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
}

// プレビュー
#Preview {
    UserListView()
}
```

---

## 依存関係グラフ

```
┌─────────────────────────────────────────┐
│         ClientApp（iOS/macOS）          │
│                                         │
│  - SwiftUI Views                        │
│  - Data Fetching (URLSession)           │
└─────────────────────────────────────────┘
                    ↓
        ┌───────────────────┐
        │  SharedModels     │
        │                   │
        │  @Record          │
        │  struct User { }  │
        │  struct Order { } │
        └───────────────────┘
                    ↓
        ┌───────────────────┐
        │  FDBRecordCore    │  ← クライアント・サーバー共通
        │                   │
        │  - @Record        │
        │  - @ID            │
        │  - @Transient     │
        │  - Codable        │
        └───────────────────┘

┌─────────────────────────────────────────┐
│         ServerApp（Backend）            │
│                                         │
│  - API Endpoints                        │
│  - Business Logic                       │
└─────────────────────────────────────────┘
                    ↓
        ┌───────────────────┐
        │  SharedModels     │  ← 同じモデル定義を使用
        │  + Server Extensions │
        │                   │
        │  User.openStore() │
        │  User.serverIndexes │
        └───────────────────┘
                    ↓
        ┌───────────────────┐
        │  FDBRecordServer  │  ← サーバー専用
        │                   │
        │  - RecordStore    │
        │  - IndexManager   │
        │  - QueryPlanner   │
        │  - #ServerIndex   │
        └───────────────────┘
                    ↓
        ┌───────────────────┐
        │  FoundationDB     │
        │  (fdb-swift-bindings) │
        └───────────────────┘
```

---

## まとめ

この構造により：

1. **SharedModels**: クライアント・サーバー間で完全に共有
2. **FDBRecordCore**: 共通のプロトコルとマクロ（依存なし）
3. **FDBRecordServer**: サーバー専用機能（FoundationDB依存）
4. **ClientApp**: FDBRecordCore のみに依存（軽量）

クライアントアプリは FoundationDB や Protobuf などのサーバー依存を一切持たず、純粋な Swift モデル定義を使用できます。

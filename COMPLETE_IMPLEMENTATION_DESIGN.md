# 完全実装設計 - Recordable Macro

## 🎯 目標

**妥協なし**：すべての型を完全サポート

- ✅ Primitive types (Int32, Int64, String, Bool, etc.)
- ✅ Custom types (Nested Recordable structs)
- ✅ Array types (Array<T>, [T])
- ✅ Optional types (T?, Optional<T>)
- ✅ Combinations (Array<T>?, [CustomType], etc.)

---

## 📐 設計原則

### 1. 型システムの完全サポート

すべてのSwift型パターンを認識し、適切に処理：

```swift
// ✅ Primitive
var name: String
var age: Int32

// ✅ Custom (Nested)
var address: Address
var company: Company

// ✅ Array
var tags: [String]
var orders: [Order]

// ✅ Optional
var middleName: String?
var department: Department?

// ✅ Combinations
var phoneNumbers: [String]?
var previousAddresses: [Address]?
var optionalTags: [String?]  // 各要素がOptional
```

### 2. Protobuf仕様への完全準拠

- **Repeated fields**: 配列は繰り返しフィールド（同じfield numberが複数回出現）
- **Optional fields**: フィールドが存在しない場合はデフォルト値またはnil
- **Nested messages**: Length-delimitedエンコーディング
- **Wire types**: 型に応じた適切なwire typeの使用

### 3. 型安全性

- コンパイル時に型エラーを検出
- ランタイムでの型変換エラーを最小化
- 適切なエラーメッセージ

---

## 🏗️ アーキテクチャ設計

### Phase 1: 型情報の拡張

**現在のFieldInfo**:
```swift
struct FieldInfo {
    let name: String
    let type: String  // "Address?" のような文字列
    let isPrimaryKey: Bool
    let isTransient: Bool
}
```

**拡張後のFieldInfo**:
```swift
struct FieldInfo {
    let name: String
    let type: String           // 元の型文字列 "Address?"
    let typeInfo: TypeInfo     // 詳細な型情報
    let isPrimaryKey: Bool
    let isTransient: Bool
}

struct TypeInfo {
    let baseType: String       // "Address"（修飾を除いた型）
    let isOptional: Bool       // Optional<T> or T?
    let isArray: Bool          // Array<T> or [T]
    let category: TypeCategory

    var arrayElementType: String?  // 配列の要素型
}

enum TypeCategory {
    case primitive(PrimitiveType)
    case custom                // Recordable準拠の構造体
}

enum PrimitiveType {
    case int32, int64, uint32, uint64
    case bool
    case string, data
    case double, float
}
```

### Phase 2: 型解析ロジック

```swift
private static func analyzeType(_ typeString: String) -> TypeInfo {
    var workingType = typeString.trimmingCharacters(in: .whitespaces)
    var isOptional = false
    var isArray = false

    // Optional検出: "T?" または "Optional<T>"
    if workingType.hasSuffix("?") {
        isOptional = true
        workingType = String(workingType.dropLast())
    } else if workingType.hasPrefix("Optional<") && workingType.hasSuffix(">") {
        isOptional = true
        workingType = String(workingType.dropFirst(9).dropLast())
    }

    // Array検出: "[T]" または "Array<T>"
    if workingType.hasPrefix("[") && workingType.hasSuffix("]") {
        isArray = true
        workingType = String(workingType.dropFirst().dropLast())
    } else if workingType.hasPrefix("Array<") && workingType.hasSuffix(">") {
        isArray = true
        workingType = String(workingType.dropFirst(6).dropLast())
    }

    // 再帰的に内部型を解析（配列の要素がOptionalの場合など）
    // 例: [String?] -> isArray=true, elementType="String?"

    let category = classifyType(workingType)

    return TypeInfo(
        baseType: workingType,
        isOptional: isOptional,
        isArray: isArray,
        category: category,
        arrayElementType: isArray ? workingType : nil
    )
}

private static func classifyType(_ type: String) -> TypeCategory {
    switch type {
    case "Int32": return .primitive(.int32)
    case "Int64": return .primitive(.int64)
    case "UInt32": return .primitive(.uint32)
    case "UInt64": return .primitive(.uint64)
    case "Bool": return .primitive(.bool)
    case "String": return .primitive(.string)
    case "Data": return .primitive(.data)
    case "Double": return .primitive(.double)
    case "Float": return .primitive(.float)
    default: return .custom
    }
}
```

### Phase 3: デフォルト値の生成

**戦略**:
1. **Primitive types**: 型に応じたデフォルト値（0, "", false, etc.）
2. **Custom types (非Optional)**: `nil`で初期化し、後でrequiredチェック
3. **Custom types (Optional)**: `nil`で初期化
4. **Array types**: 空配列 `[]`
5. **Optional types**: `nil`

```swift
private static func generateDeserializeField(field: FieldInfo, fieldNumber: Int) -> String {
    let typeInfo = field.typeInfo

    if typeInfo.isArray {
        // 配列は空配列で初期化
        return "var \(field.name): \(field.type) = []"
    }

    if typeInfo.isOptional {
        // Optionalは常にnil
        return "var \(field.name): \(field.type) = nil"
    }

    switch typeInfo.category {
    case .primitive(let primitiveType):
        let defaultValue = getDefaultValue(for: primitiveType)
        return "var \(field.name): \(typeInfo.baseType) = \(defaultValue)"

    case .custom:
        // カスタム型（非Optional）はnilで初期化し、後でチェック
        return "var \(field.name): \(typeInfo.baseType)? = nil"
    }
}
```

### Phase 4: デシリアライゼーションの完全実装

**Primitive types**（既存の実装を維持）:
```swift
case 1: // name (String)
    let length = try decodeVarint(data, offset: &offset)
    let endOffset = offset + Int(length)
    name = String(data: data[offset..<endOffset], encoding: .utf8) ?? ""
    offset = endOffset
```

**Custom types (非Optional)**:
```swift
case 2: // address (Address)
    let length = try decodeVarint(data, offset: &offset)
    let endOffset = offset + Int(length)
    let fieldData = data[offset..<endOffset]
    address = try Address.fromProtobuf(fieldData)
    offset = endOffset
```

**Custom types (Optional)**:
```swift
case 3: // department (Department?)
    let length = try decodeVarint(data, offset: &offset)
    let endOffset = offset + Int(length)
    let fieldData = data[offset..<endOffset]
    department = try Department.fromProtobuf(fieldData)
    offset = endOffset
```

**Array types (Primitive elements)**:
```swift
case 4: // tags ([String])
    let length = try decodeVarint(data, offset: &offset)
    let endOffset = offset + Int(length)
    let itemData = data[offset..<endOffset]
    let item = String(data: itemData, encoding: .utf8) ?? ""
    tags.append(item)
    offset = endOffset
```

**Array types (Custom elements)**:
```swift
case 5: // orders ([Order])
    let length = try decodeVarint(data, offset: &offset)
    let endOffset = offset + Int(length)
    let itemData = data[offset..<endOffset]
    let item = try Order.fromProtobuf(itemData)
    orders.append(item)
    offset = endOffset
```

**Array types (Optional elements)**:
```swift
case 6: // phoneNumbers ([String?])
    let length = try decodeVarint(data, offset: &offset)
    let endOffset = offset + Int(length)
    let itemData = data[offset..<endOffset]
    if itemData.isEmpty {
        phoneNumbers.append(nil)
    } else {
        let item = String(data: itemData, encoding: .utf8)
        phoneNumbers.append(item)
    }
    offset = endOffset
```

### Phase 5: 必須フィールドの検証

カスタム型（非Optional）は必須フィールドとして扱う：

```swift
public static func fromProtobuf(_ data: Data) throws -> Order {
    var offset = 0
    var orderID: Int64 = 0
    var address: Address? = nil  // カスタム型は一旦Optional
    var tags: [String] = []

    // ... パース処理 ...

    // 必須フィールドチェック
    guard let address = address else {
        throw RecordLayerError.serializationError("Required field 'address' is missing")
    }

    return Order(
        orderID: orderID,
        address: address,  // Optionalを外す
        tags: tags
    )
}
```

### Phase 6: extractField の完全実装

型に応じた適切な変換：

**Primitive types**:
```swift
case "name": return [self.name]  // String は TupleElement
case "age": return [self.age]    // Int32 は TupleElement
```

**Custom types (Primary Keyを抽出)**:
```swift
case "address":
    // カスタム型のプライマリキーを抽出
    return self.address.extractPrimaryKey().elements
```

**Custom types (Optional)**:
```swift
case "department":
    // Optionalの場合はnilチェック
    if let department = self.department {
        return department.extractPrimaryKey().elements
    }
    return []
```

**Array types (Primitive)**:
```swift
case "tags":
    // [String] -> [TupleElement]
    return self.tags.map { $0 as TupleElement }
```

**Array types (Custom)**:
```swift
case "orders":
    // [Order] -> [TupleElement]
    // 各OrderのプライマリキーをTupleとして返す
    return self.orders.flatMap { $0.extractPrimaryKey().elements }
```

---

## 🔧 実装詳細

### generateDecodeCase の完全実装

```swift
private static func generateDecodeCase(field: FieldInfo, fieldNumber: Int) -> String {
    let typeInfo = field.typeInfo

    // Primitive types
    if case .primitive(let primitiveType) = typeInfo.category {
        if typeInfo.isArray {
            return generatePrimitiveArrayDecode(field: field, fieldNumber: fieldNumber, primitiveType: primitiveType)
        } else {
            return generatePrimitiveDecode(field: field, fieldNumber: fieldNumber, primitiveType: primitiveType)
        }
    }

    // Custom types
    if typeInfo.isArray {
        return generateCustomArrayDecode(field: field, fieldNumber: fieldNumber)
    } else {
        return generateCustomDecode(field: field, fieldNumber: fieldNumber)
    }
}

private static func generatePrimitiveDecode(field: FieldInfo, fieldNumber: Int, primitiveType: PrimitiveType) -> String {
    switch primitiveType {
    case .int32:
        return """
        case \(fieldNumber): // \(field.name)
            \(field.name) = Int32(bitPattern: UInt32(truncatingIfNeeded: try decodeVarint(data, offset: &offset)))
        """
    case .int64:
        return """
        case \(fieldNumber): // \(field.name)
            \(field.name) = Int64(bitPattern: try decodeVarint(data, offset: &offset))
        """
    case .string:
        return """
        case \(fieldNumber): // \(field.name)
            let length = try decodeVarint(data, offset: &offset)
            let endOffset = offset + Int(length)
            guard endOffset <= data.count else {
                throw RecordLayerError.serializationError("String length exceeds data bounds")
            }
            \(field.name) = String(data: data[offset..<endOffset], encoding: .utf8) ?? ""
            offset = endOffset
        """
    // ... 他のPrimitive types
    }
}

private static func generatePrimitiveArrayDecode(field: FieldInfo, fieldNumber: Int, primitiveType: PrimitiveType) -> String {
    let elementDecodeCode: String

    switch primitiveType {
    case .int32:
        elementDecodeCode = "Int32(bitPattern: UInt32(truncatingIfNeeded: try decodeVarint(itemData, offset: &itemOffset)))"
    case .int64:
        elementDecodeCode = "Int64(bitPattern: try decodeVarint(itemData, offset: &itemOffset))"
    case .string:
        elementDecodeCode = """
        {
            let itemLength = try decodeVarint(itemData, offset: &itemOffset)
            let itemEndOffset = itemOffset + Int(itemLength)
            let str = String(data: itemData[itemOffset..<itemEndOffset], encoding: .utf8) ?? ""
            itemOffset = itemEndOffset
            return str
        }()
        """
    // ... 他の型
    }

    return """
    case \(fieldNumber): // \(field.name) (Array)
        let length = try decodeVarint(data, offset: &offset)
        let endOffset = offset + Int(length)
        guard endOffset <= data.count else {
            throw RecordLayerError.serializationError("Array field length exceeds data bounds")
        }
        var itemData = data[offset..<endOffset]
        var itemOffset = 0
        let item = \(elementDecodeCode)
        \(field.name).append(item)
        offset = endOffset
    """
}

private static func generateCustomDecode(field: FieldInfo, fieldNumber: Int) -> String {
    let assignmentTarget = field.typeInfo.isOptional ? field.name : "\(field.name)_temp"

    return """
    case \(fieldNumber): // \(field.name) (\(field.typeInfo.baseType))
        let length = try decodeVarint(data, offset: &offset)
        let endOffset = offset + Int(length)
        guard endOffset <= data.count else {
            throw RecordLayerError.serializationError("Custom type field length exceeds data bounds")
        }
        let fieldData = data[offset..<endOffset]
        \(assignmentTarget) = try \(field.typeInfo.baseType).fromProtobuf(fieldData)
        offset = endOffset
    """
}

private static func generateCustomArrayDecode(field: FieldInfo, fieldNumber: Int) -> String {
    return """
    case \(fieldNumber): // \(field.name) ([\\(field.typeInfo.baseType)])
        let length = try decodeVarint(data, offset: &offset)
        let endOffset = offset + Int(length)
        guard endOffset <= data.count else {
            throw RecordLayerError.serializationError("Custom array field length exceeds data bounds")
        }
        let itemData = data[offset..<endOffset]
        let item = try \(field.typeInfo.baseType).fromProtobuf(itemData)
        \(field.name).append(item)
        offset = endOffset
    """
}
```

### 必須フィールド検証の生成

```swift
private static func generateRequiredFieldChecks(fields: [FieldInfo]) -> String {
    let checks = fields
        .filter { !$0.typeInfo.isOptional && $0.typeInfo.category == .custom }
        .map { field in
            """
            guard let \(field.name) = \(field.name)_temp else {
                throw RecordLayerError.serializationError("Required field '\(field.name)' is missing")
            }
            """
        }
        .joined(separator: "\n    ")

    return checks
}
```

---

## 📊 サポートマトリックス

| 型パターン | シリアライズ | デシリアライズ | extractField | テスト |
|-----------|------------|--------------|--------------|--------|
| Int32, Int64 | ✅ | ✅ | ✅ | ✅ |
| String, Data | ✅ | ✅ | ✅ | ✅ |
| Bool | ✅ | ✅ | ✅ | ✅ |
| Double, Float | ✅ | ✅ | ✅ | ✅ |
| Custom型 | ✅ | 🔄 実装予定 | 🔄 実装予定 | 🔄 |
| Custom? | ✅ | 🔄 実装予定 | 🔄 実装予定 | 🔄 |
| [Primitive] | ✅ | 🔄 実装予定 | 🔄 実装予定 | 🔄 |
| [Custom] | ✅ | 🔄 実装予定 | 🔄 実装予定 | 🔄 |
| [T]? | ✅ | 🔄 実装予定 | 🔄 実装予定 | 🔄 |
| [T?] | ⚠️ | 🔄 実装予定 | 🔄 実装予定 | 🔄 |

---

## 🧪 テスト計画

### 1. 基本型テスト（既存）
- ✅ Int32, Int64, String, etc.

### 2. カスタム型テスト
```swift
@Recordable
struct Address {
    @PrimaryKey var id: Int64
    var street: String
    var city: String
}

@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var name: String
    var address: Address           // 必須カスタム型
    var alternateAddress: Address?  // OptionalカスタムARM型
}
```

### 3. 配列型テスト
```swift
@Recordable
struct BlogPost {
    @PrimaryKey var postID: Int64
    var title: String
    var tags: [String]              // Primitive配列
    var comments: [Comment]         // Custom配列
    var optionalTags: [String]?     // Optional配列
}
```

### 4. 複合型テスト
```swift
@Recordable
struct Company {
    @PrimaryKey var companyID: Int64
    var name: String
    var employees: [Employee]       // Custom配列
    var departments: [Department]?  // Optional Custom配列
    var headquarters: Address       // 必須Custom
    var branches: [Address]         // Custom配列
}
```

---

## 📝 実装順序

### Step 1: 型解析システム
- [ ] TypeInfo構造体の実装
- [ ] analyzeType関数の実装
- [ ] classifyType関数の実装

### Step 2: FieldInfo拡張
- [ ] FieldInfo構造体にtypeInfoを追加
- [ ] extractFields関数でtypeInfoを生成

### Step 3: デフォルト値生成の改善
- [ ] generateDeserializeFieldの完全実装
- [ ] 型に応じた適切なデフォルト値

### Step 4: デシリアライゼーション実装
- [ ] generateDecodeCaseの完全実装
- [ ] Primitive配列のサポート
- [ ] Custom型のサポート
- [ ] Custom配列のサポート
- [ ] Optional型のサポート

### Step 5: 必須フィールド検証
- [ ] generateRequiredFieldChecksの実装
- [ ] fromProtobufメソッドへの統合

### Step 6: extractField実装
- [ ] generateExtractFieldCaseの完全実装
- [ ] カスタム型のプライマリキー抽出
- [ ] 配列型の要素展開

### Step 7: テスト
- [ ] カスタム型テストの作成
- [ ] 配列型テストの作成
- [ ] Optional型テストの作成
- [ ] 複合型テストの作成
- [ ] エッジケーステスト

### Step 8: ドキュメント
- [ ] サポート型の完全リスト
- [ ] 使用例の追加
- [ ] ベストプラクティス

---

## 🎯 完成基準

1. ✅ すべてのSwift型パターンをサポート
2. ✅ Protobuf仕様への完全準拠
3. ✅ コンパイルエラーなし
4. ✅ 包括的なテストカバレッジ（>90%）
5. ✅ ラウンドトリップテスト（serialize → deserialize）が100%成功
6. ✅ パフォーマンステスト（大規模データでの動作確認）
7. ✅ ドキュメント完備

---

## 🚀 Next Actions

1. **型解析システムの実装**から開始
2. 各Stepを順番に実装
3. 各Step完了後にテストを実行
4. すべてのテストが通るまで反復

**妥協なし。完全実装を目指します。**

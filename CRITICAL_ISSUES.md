# 重大な問題 - RecordableMacro実装

## 🔥 発見された重大な問題（未解決）

### 問題1: カスタム型（Nested Messages）のデフォルト値がコメント ❌

**影響**: **致命的** - カスタム型フィールドを含む構造体で**コンパイルエラー**

**症状**:
```swift
@Recordable
struct Order {
    @PrimaryKey var orderID: Int64
    var shippingAddress: Address  // カスタム型
}

@Recordable
struct Address {
    @PrimaryKey var id: Int64
    var street: String
    var city: String
}
```

**生成されるコード**（RecordableMacro.swift:412）:
```swift
public static func fromProtobuf(_ data: Data) throws -> Order {
    var offset = 0
    var orderID: Int64 = 0
    var shippingAddress: Address = /* TODO: nested message */  // ❌ コンパイルエラー！

    // ...
}
```

**原因** (RecordableMacro.swift:474):
```swift
private static func getDefaultValue(for type: String) -> String {
    switch type {
    // ...
    default:
        if type.hasPrefix("Array<") {
            return "[]"
        } else if type.hasPrefix("Optional<") || type.hasSuffix("?") {
            return "nil"
        } else {
            // For nested messages, we'll need special handling
            return "/* TODO: nested message */"  // ❌ これはコメント！
        }
    }
}
```

**問題の本質**:
Swiftでは、カスタム型のデフォルト値を自動生成することは不可能です（初期化パラメータが必要）。

**解決策の選択肢**:

1. **Option A: 必須フィールドとして扱う**
   ```swift
   // カスタム型フィールドは必ずProtobufデータに存在することを要求
   // データに存在しない場合はエラーをthrow
   ```

2. **Option B: Optionalを強制** ✅ **推奨**
   ```swift
   // カスタム型フィールドはすべてOptional型にする
   var shippingAddress: Address?  // nilがデフォルト値
   ```

3. **Option C: デフォルトコンストラクタを要求**
   ```swift
   // Recordableプロトコルにinit()を要求
   // デフォルト値として Type() を使用
   ```

---

### 問題2: カスタム型のデシリアライゼーションが未実装 ❌

**影響**: **致命的** - データが正しくデコードされない

**症状**:
カスタム型フィールドがProtobufデータに存在しても、デコードされずにデフォルト値のままになります。

**生成されるコード**（RecordableMacro.swift:569）:
```swift
case 2: // shippingAddress
    let length = try decodeVarint(data, offset: &offset)
    let endOffset = offset + Int(length)
    guard endOffset <= data.count else {
        throw RecordLayerError.serializationError("Field length exceeds data bounds")
    }
    let fieldData = data[offset..<endOffset]
    // TODO: Deserialize complex type Address  // ❌ 実装なし！
    offset = endOffset
```

**問題**:
- `fieldData`は取得されるが、**使用されない**
- `shippingAddress`変数は**更新されない**
- オフセットだけが進められ、データは捨てられる

**正しい実装例**:
```swift
case 2: // shippingAddress
    let length = try decodeVarint(data, offset: &offset)
    let endOffset = offset + Int(length)
    guard endOffset <= data.count else {
        throw RecordLayerError.serializationError("Field length exceeds data bounds")
    }
    let fieldData = data[offset..<endOffset]
    shippingAddress = try Address.fromProtobuf(fieldData)  // ✅ 実際にデコード
    offset = endOffset
```

---

### 問題3: extractField の型変換が未実装 ⚠️

**影響**: **高** - カスタム型でコンパイルエラーまたはランタイムエラー

**症状**:
`extractField`メソッドは`[any TupleElement]`を返す必要がありますが、すべての型が`TupleElement`プロトコルに準拠しているわけではありません。

**生成されるコード**（RecordableMacro.swift:480）:
```swift
public func extractField(_ fieldName: String) -> [any TupleElement] {
    switch fieldName {
    case "orderID": return [self.orderID]          // ✅ Int64は TupleElement
    case "shippingAddress": return [self.shippingAddress]  // ❌ Address は TupleElement ではない
    default: return []
    }
}
```

**問題**:
カスタム型、Date型、配列型などは`TupleElement`プロトコルに準拠していない可能性があります。

**TupleElementに準拠している型**（FoundationDB）:
- Int, Int8, Int16, Int32, Int64
- UInt, UInt8, UInt16, UInt32, UInt64
- Float, Double
- String
- Data (as Bytes)
- Bool
- UUID

**TupleElementに準拠していない型**:
- Date
- カスタム構造体/クラス
- 配列型（配列の中身がTupleElementでも、配列自体は違う）

**解決策**:
型に応じた適切な変換が必要です：

```swift
case "createdAt":  // Date型
    return [Int64(self.createdAt.timeIntervalSince1970)]

case "tags":  // [String]型
    return self.tags.map { $0 as TupleElement }  // 各要素を個別に返す

case "shippingAddress":  // カスタム型
    // インデックスには入れない、またはシリアライズしたDataを入れる
    return []  // または throw error
```

---

### 問題4: 配列型とOptional型のデシリアライゼーションが未実装 ⚠️

**影響**: **高** - 配列フィールドやOptionalフィールドが正しくデコードされない

**現状**:
- シリアライゼーション側：実装あり（generateArraySerialize, generateOptionalSerialize）
- デシリアライゼーション側：**未実装**（default caseで処理される）

**問題のコード**（RecordableMacro.swift:559-571）:
```swift
default:
    // Handle complex types (arrays, optionals, nested messages)
    return """
    case \(fieldNumber): // \(field.name)
        let length = try decodeVarint(data, offset: &offset)
        let endOffset = offset + Int(length)
        guard endOffset <= data.count else {
            throw RecordLayerError.serializationError("Field length exceeds data bounds")
        }
        let fieldData = data[offset..<endOffset]
        // TODO: Deserialize complex type \(field.type)  // ❌ 未実装
        offset = endOffset
    """
```

**必要な実装**:

1. **配列型の場合**:
   ```swift
   // Protobufでは配列は繰り返しフィールドとして表現される
   // 同じfield numberが複数回出現する

   var tags: [String] = []

   // Parsing loop内で
   case 5: // tags
       let length = try decodeVarint(data, offset: &offset)
       let endOffset = offset + Int(length)
       let itemData = data[offset..<endOffset]
       let item = String(data: itemData, encoding: .utf8) ?? ""
       tags.append(item)  // 追加（上書きではない）
       offset = endOffset
   ```

2. **Optional型の場合**:
   ```swift
   var middleName: String? = nil

   // Parsing loop内で
   case 6: // middleName
       let length = try decodeVarint(data, offset: &offset)
       let endOffset = offset + Int(length)
       let itemData = data[offset..<endOffset]
       middleName = String(data: itemData, encoding: .utf8)
       offset = endOffset
   ```

---

## 影響範囲

### 現在動作する型（✅）:
- Int32, Int64, UInt32, UInt64
- Bool
- String
- Data
- Double, Float

### 現在動作しない型（❌）:
- カスタム構造体（Nested Messages）
- 配列型（Array<T>）
- Optional型（T?）
- Date型
- UUID型（extractFieldで問題）
- その他のカスタム型

---

## なぜ現在ビルドが成功しているのか？

**理由**: 作成したテストが基本型のみを使用しているため

テストで使用されている型：
- `TestUser`: Int64, String, Int32 のみ
- `TestTenantUser`: String, Int64 のみ
- `TestProduct`: Int64, String のみ
- `TestOrder`: Int64 のみ

**ユーザーが以下を試すと失敗します**:
```swift
@Recordable
struct BlogPost {
    @PrimaryKey var postID: Int64
    var title: String
    var tags: [String]              // ❌ 配列型：デシリアライズ未実装
    var author: Author              // ❌ カスタム型：コンパイルエラー
    var publishedAt: Date?          // ❌ Optional Date：デシリアライズ未実装
}

@Recordable
struct Author {
    @PrimaryKey var authorID: Int64
    var name: String
}
```

---

## 推奨される対応

### 短期対応（緊急）:

1. **ドキュメントに制限事項を明記**
   ```markdown
   ## 現在サポートされている型

   - Int32, Int64, UInt32, UInt64
   - Bool
   - String
   - Data
   - Double, Float

   ## 未サポート（将来実装予定）

   - カスタム構造体（Nested Messages）
   - 配列型（Array<T>）
   - Optional型（T?）
   - Date, UUID など
   ```

2. **マクロ展開時に警告またはエラーを出す**
   ```swift
   // RecordableMacroで型チェック
   if !isSupportedType(field.type) {
       throw DiagnosticsError(diagnostics: [
           Diagnostic(
               node: field.syntax,
               message: MacroExpansionErrorMessage(
                   "Field '\(field.name)' has unsupported type '\(field.type)'. " +
                   "Currently supported types: Int32, Int64, UInt32, UInt64, Bool, String, Data, Double, Float"
               ),
               severity: .error
           )
       ])
   }
   ```

### 中長期対応（完全実装）:

1. **カスタム型サポート**の実装
   - デフォルト値の問題を解決（Optionalにするか、init()を要求）
   - デシリアライゼーションの実装
   - extractFieldの実装（シリアライズして返すか、サポート外とする）

2. **配列型サポート**の実装
   - デシリアライゼーションでの複数値の処理
   - extractFieldでの配列展開

3. **Optional型サポート**の実装
   - デシリアライゼーションの実装
   - nil値の適切な処理

4. **Date/UUID型サポート**の実装
   - 自動的な型変換（Date → Int64 timestamp, UUID → Data）

---

## セキュリティ/安定性への影響

### 現在の状態:
- ✅ 基本型のみを使う限り安定
- ❌ 未サポート型を使うとコンパイルエラーまたはデータ損失
- ❌ ドキュメントに制限事項の記載なし（ユーザーが気づかない）

### リスク:
- **データ損失**: 未サポート型のフィールドがProtobufデータから無視される
- **型安全性の欠如**: コンパイル時にエラーが出ない（マクロが生成したコードがコンパイルエラーになるまで気づかない）
- **予期しない動作**: extractFieldでランタイムエラーの可能性

---

## 優先度

| 問題 | 優先度 | 影響 | 対応期限 |
|------|--------|------|----------|
| カスタム型のデフォルト値 | 🔥 P0 | コンパイルエラー | 即時 |
| カスタム型のデシリアライズ | 🔥 P0 | データ損失 | 即時 |
| 制限事項のドキュメント化 | 🔥 P0 | ユーザー混乱 | 即時 |
| 型チェックとエラー報告 | ⚠️ P1 | UX | 1週間 |
| 配列型サポート | ⚠️ P1 | 機能不足 | 2週間 |
| Optional型サポート | ⚠️ P1 | 機能不足 | 2週間 |
| Date/UUID型サポート | ℹ️ P2 | 機能不足 | 1ヶ月 |
| extractField型変換 | ℹ️ P2 | インデックス機能 | 1ヶ月 |

---

## 結論

**現在の実装は基本型のみをサポートしており、それ以外の型は動作しません。**

ユーザーがカスタム型、配列、Optionalなどを使おうとすると：
1. コンパイルエラー（カスタム型のデフォルト値）
2. データ損失（デシリアライゼーションの未実装）
3. ランタイムエラー（extractFieldの型不一致）

**緊急対応が必要**:
1. ドキュメントに明確な制限事項を記載
2. 未サポート型でマクロエラーを出す
3. または、カスタム型・配列・Optionalのサポートを完全実装

現状では「部分的な実装」であり、プロダクション使用には**重大なリスク**があります。

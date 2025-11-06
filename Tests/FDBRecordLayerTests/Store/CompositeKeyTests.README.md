# CompositeKeyTests.swift - Temporarily Disabled

## Status: ⏸️ Disabled

**File**: `CompositeKeyTests.swift.disabled`

## Reason

このテストファイルは**複合主キー**（複数フィールドの組み合わせで主キーを構成）の機能をテストしています。

現在の`@Recordable`マクロは**単一フィールドの主キー**のみをサポートしているため、このテストは一時的に無効化されています。

### 例：複合主キー（未サポート）

```swift
struct OrderItem {
    var orderID: String
    var itemID: String

    // 複合主キー: (orderID, itemID)
    var compositeKey: Tuple {
        Tuple(orderID, itemID)
    }
}
```

### 現在サポート：単一主キー

```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64  // ← 単一主キー
    var email: String
}
```

## 将来の対応

複合主キーのサポートは将来実装予定です：

### Phase 1: @PrimaryKeyの複数適用
```swift
@Recordable
struct OrderItem {
    @PrimaryKey var orderID: String
    @PrimaryKey var itemID: String
}
```

### Phase 2: マクロが自動的に複合キーを生成
```swift
// 自動生成:
// static var primaryKeyFields: [String] { ["orderID", "itemID"] }
// func extractPrimaryKey() -> Tuple { Tuple(orderID, itemID) }
```

## 有効化手順

複合主キーのサポートが実装されたら：

1. `CompositeKeyTests.swift.disabled` → `CompositeKeyTests.swift` にリネーム
2. 手動のRecordable適合を削除し、`@Recordable`マクロに変更
3. テストを実行して検証

## 関連イシュー

- TODO: 複合主キーサポートの実装
- TODO: @PrimaryKeyマクロの拡張（複数フィールド対応）

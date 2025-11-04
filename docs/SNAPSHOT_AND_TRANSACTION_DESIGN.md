# Snapshot読み取りとトランザクションの設計

## 概要

このドキュメントは、TransactionCursorとSnapshotCursorにおける`snapshot`パラメータの設計思想を明確に定義します。

## FoundationDBの`snapshot`パラメータ

FoundationDBの`getRange()`や`getValue()`には`snapshot`パラメータがあり、以下の2つのモードを提供します：

### `snapshot: true` (スナップショット読み取り)

**動作**:
- 読み取り開始時点のデータベーススナップショットを見る
- **他のトランザクションの変更を検知しない** (conflict detection disabled)
- 読み取り範囲は競合範囲に追加されない
- 他のトランザクションがコミットしても、このトランザクションは失敗しない

**利点**:
- 読み取り専用操作でパフォーマンスが高い
- 競合によるリトライが発生しない
- 長時間の読み取り操作に適している

**欠点**:
- Read-Your-Writes保証がない（同一トランザクション内の書き込みが見えない可能性）
- Serializable isolationが保証されない

**用途**:
- 読み取り専用のクエリ
- 分析クエリ
- レポート生成
- **SnapshotCursor（トランザクション外の単発読み取り）**

### `snapshot: false` (Serializable読み取り)

**動作**:
- **競合検知が有効** (conflict detection enabled)
- 読み取り範囲が競合範囲に追加される
- **Read-Your-Writes保証**: 同一トランザクション内の書き込みが見える
- **Serializable isolation**: 他のトランザクションとの競合を検知
- 競合があればコミット時に`not_committed`エラー

**利点**:
- ACID保証の完全なサポート
- Read-Your-Writes動作
- Serializable isolation

**欠点**:
- 競合によるリトライが発生する可能性
- パフォーマンスへの影響（競合検知のオーバーヘッド）

**用途**:
- トランザクション内の読み取り・書き込み操作
- 一貫性が重要な操作
- **TransactionCursor（明示的なトランザクション内の読み取り）**

## このプロジェクトの設計方針

### TransactionCursor: `snapshot: false`

**理由**:

1. **明示的なトランザクション内で使用される**
   ```swift
   try await context.transaction { transaction in
       let cursor = try await transaction.fetch(query)
       // ↑ この内部では snapshot: false を使用すべき
   }
   ```

2. **Read-Your-Writes保証が必要**
   ```swift
   try await context.transaction { transaction in
       // レコードを保存
       try await transaction.save(user)

       // すぐにクエリ
       let cursor = try await transaction.fetch(query)
       // ← 保存したレコードが見える必要がある！
   }
   ```

3. **Serializable isolation保証が必要**
   - 他のトランザクションとの競合を検知
   - ACID保証の維持
   - データ整合性の確保

4. **トランザクションの一部として動作**
   - トランザクションコンテキスト内での一貫した動作
   - コミット時に競合があれば適切にエラー

### SnapshotCursor: `snapshot: true`

**理由**:

1. **トランザクション外の単発読み取り**
   ```swift
   let cursor = try await context.fetch(query)
   // ↑ トランザクションブロック外での読み取り
   // 読み取り専用なので競合検知は不要
   ```

2. **読み取り専用操作**
   - 書き込みを伴わない
   - 競合検知は不要
   - パフォーマンス最適化が重要

3. **独立したトランザクション**
   - 各読み取りが独自のトランザクションを作成
   - 他のトランザクションとの競合を考慮する必要がない

4. **長時間の読み取りに対応**
   - 大量データのスキャン
   - 競合によるリトライを避ける

## 実装における問題点（修正前）

### 問題: TypedFullScanPlan が常に `snapshot: true` を使用

**現在のコード**:
```swift
// TypedQueryPlan.swift:43-46
let sequence = transaction.getRange(
    beginSelector: .firstGreaterOrEqual(beginKey),
    endSelector: .firstGreaterThan(endKey),
    snapshot: true  // ← 常に true！
)
```

**影響**:

1. **TransactionCursor での使用時に問題**
   - 本来 `snapshot: false` を使うべき
   - しかし `snapshot: true` が強制される
   - Read-Your-Writes が動作しない
   - Serializable isolation が保証されない

2. **トランザクション内での動作が不正確**
   ```swift
   try await context.transaction { transaction in
       try await transaction.save(user)
       let cursor = try await transaction.fetch(query)
       // ↑ 保存したレコードが見えない可能性！
   }
   ```

## 解決策

### TypedQueryPlan に `snapshot` パラメータを追加

**修正案**:
```swift
public protocol TypedQueryPlan<Record>: Sendable {
    associatedtype Record: Sendable

    func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        snapshot: Bool  // ← パラメータ追加
    ) async throws -> AnyTypedRecordCursor<Record>
}

public struct TypedFullScanPlan<Record: Sendable>: TypedQueryPlan {
    public func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        snapshot: Bool  // ← パラメータ追加
    ) async throws -> AnyTypedRecordCursor<Record> {
        // ...
        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(beginKey),
            endSelector: .firstGreaterThan(endKey),
            snapshot: snapshot  // ← 呼び出し元から渡された値を使用
        )
        // ...
    }
}
```

### TransactionCursor の修正

**修正案**:
```swift
public mutating func next() async throws -> Record? {
    if !initialized {
        // ...
        let cursor = try await plan.execute(
            subspace: storeSubspace,
            recordAccess: recordAccess,
            context: context,
            snapshot: false  // ← TransactionCursor は false
        )
        // ...
    }
    return try await typedIterator?.next()
}
```

### SnapshotCursor の修正

**修正案**:
```swift
public mutating func next() async throws -> Record? {
    if !initialized {
        // ...
        let cursor = try await plan.execute(
            subspace: storeSubspace,
            recordAccess: recordAccess,
            context: ctx,
            snapshot: true  // ← SnapshotCursor は true
        )
        // ...
    }
    return try await typedIterator?.next()
}
```

## 検証方法

### テストケース1: Read-Your-Writes

```swift
@Test("TransactionCursor supports Read-Your-Writes")
func transactionCursorReadYourWrites() async throws {
    try await context.transaction { transaction in
        // 1. レコードを保存
        let user = User(id: "test-id", name: "Alice")
        try await transaction.save(user)

        // 2. すぐにクエリ
        let query = RecordQuery(recordTypes: ["User"])
        let cursor = try await transaction.fetch(query)

        // 3. 保存したレコードが見えることを確認
        var found = false
        for try await record in cursor {
            if record.id == "test-id" {
                found = true
            }
        }

        #expect(found == true)  // ← snapshot: false なら true
    }
}
```

### テストケース2: Snapshot読み取り

```swift
@Test("SnapshotCursor reads snapshot")
func snapshotCursorReadsSnapshot() async throws {
    // 1. レコードを保存
    try await context.transaction { transaction in
        let user = User(id: "test-id", name: "Alice")
        try await transaction.save(user)
    }

    // 2. スナップショットカーソルで読み取り
    let query = RecordQuery(recordTypes: ["User"])
    let cursor = try await context.fetch(query)

    // 3. レコードが見えることを確認
    var found = false
    for try await record in cursor {
        if record.id == "test-id" {
            found = true
        }
    }

    #expect(found == true)
}
```

## ベストプラクティス

### 使い分けのガイドライン

| シナリオ | 使用するCursor | snapshot設定 | 理由 |
|---------|---------------|-------------|------|
| トランザクション内の読み書き | TransactionCursor | `false` | Read-Your-Writes保証、Serializable isolation |
| 単発の読み取り専用クエリ | SnapshotCursor | `true` | パフォーマンス最適、競合検知不要 |
| 分析クエリ、レポート | SnapshotCursor | `true` | 長時間読み取り、競合回避 |
| トランザクション内の読み取り専用 | TransactionCursor | `false` | トランザクションの一貫性保証 |

### 注意事項

1. **TransactionCursor は常に `snapshot: false`**
   - トランザクション内で一貫性を保証
   - Read-Your-Writes が必要

2. **SnapshotCursor は常に `snapshot: true`**
   - 読み取り専用操作
   - パフォーマンス最適化

3. **混在させない**
   - 同一トランザクション内で snapshotとnon-snapshotを混在させると、予期しない動作になる可能性

## まとめ

- **TransactionCursor**: 明示的なトランザクション内で使用、`snapshot: false`でSerializable isolation保証
- **SnapshotCursor**: トランザクション外の単発読み取り、`snapshot: true`でパフォーマンス最適化
- この設計により、正しいトランザクション動作と最適なパフォーマンスを両立

---

**作成日**: 2025-01-15
**最終更新**: 2025-01-15

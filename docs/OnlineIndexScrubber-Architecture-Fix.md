# OnlineIndexScrubber Architecture - Corrected Design

**Version**: 2.0 (Based on Code Review)
**Date**: 2025-01-15
**Status**: Design Phase - Corrected

---

## レビュー指摘事項の修正

### 問題1: 無限ループ対策が不完全

**指摘内容**:
> 無限ループ対策として提案されている `if scannedCount > 0 && …` が根本的な再現条件を解消できていません。最初のキーが
> maxTransactionBytes を超えているケースでは scannedCount == 0 のまま処理に入るため、依然として同じキーに戻ってしまい前進できません。

**根本原因の再分析**:

```swift
// 現在の実装（OnlineIndexScrubber.swift:274-282）
for try await (indexKey, _) in sequence {
    let keySize = indexKey.count
    if scannedBytes + keySize > configuration.maxTransactionBytes {
        // ❌ 問題: scannedCount=0 でもこのチェックに引っかかる
        // → 継続キー = 同じキー → 無限ループ
        return (indexKey, issues, lastProcessedKey, scannedCount)
    }
    scannedBytes += keySize
    scannedCount += 1
    // ... 処理 ...
}
```

**シナリオ再現**:
```
バッチ1:
  scannedCount = 0, scannedBytes = 0
  Read キー1 (5MB)
  Check: 0 + 5MB > 1MB → true
  Return (キー1, [], nil, 0)  ❌ scannedCount=0

バッチ2:
  開始キー = キー1（前回と同じ）
  scannedCount = 0, scannedBytes = 0
  Read キー1 (5MB)
  Check: 0 + 5MB > 1MB → true
  Return (キー1, [], nil, 0)  ❌ 無限ループ
```

**提案された `scannedCount > 0` チェックでも解決しない理由**:
```swift
// 提案（不完全）
if scannedCount > 0 && scannedBytes + keySize > maxBytes {
    return (indexKey, issues, lastProcessedKey, scannedCount)
}
// ✅ 2つ目以降のキーは制限チェック有効
// ❌ 最初のキー（scannedCount=0）は必ず処理に入る
//    → 処理後 scannedCount=1, scannedBytes=5MB
//    → 次のイテレーション: scannedCount > 0 なので制限チェック発動
//    → キー2が読めずに return
//    → 次のバッチは キー2 から開始
//    → キー2 も 5MB なら同じ問題発生 ❌
```

**正しい対策: 最初のキーを必ず処理し、エラー時にスキップ**

```swift
/// Phase 1: Index Entries Scan（修正版）
private func scrubIndexEntries(progress: ScrubberProgress) async throws -> ([ScrubberIssue], Int) {
    let indexSubspace = subspace
        .subspace(RecordStoreKeyspace.index.rawValue)
        .subspace(index.subspaceTupleKey)

    let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
    let recordTypeNames = metaData.getRecordTypesForIndex(index.name)
    let (beginKey, endKey) = indexSubspace.range()

    var continuation: FDB.Bytes? = beginKey
    var allIssues: [ScrubberIssue] = []
    var totalScanned = 0
    var warningCount = 0

    while let currentKey = continuation {
        let context = try RecordContext(database: database)
        defer { context.cancel() }

        do {
            // バッチ処理（必ず最初のキーは処理する）
            let (nextContinuation, batchIssues, batchEndKey, scannedCount) = try await scrubIndexEntriesBatch(
                context: context,
                indexSubspace: indexSubspace,
                recordSubspace: recordSubspace,
                recordTypeNames: recordTypeNames,
                startKey: currentKey,
                endKey: endKey,
                warningCount: &warningCount
            )

            allIssues.append(contentsOf: batchIssues)
            totalScanned += scannedCount

            // プログレス更新
            if let lastKey = batchEndKey {
                let rangeEnd = nextKey(after: lastKey)
                try await progress.markPhase1Range(from: currentKey, to: rangeEnd, context: context)
            }

            try await context.commit()

            continuation = nextContinuation

        } catch let error as FDB.Error where error.errno == 2101 {
            // ✅ transaction_too_large エラー
            // 最初のキーが大きすぎる場合、スキップして次に進む

            if configuration.enableProgressLogging {
                print("[OnlineIndexScrubber] WARNING: Oversized key at \(currentKey.hexEncodedString()), skipping")
            }

            // このキーをスキップ（プログレスマーク）
            let skipKey = nextKey(after: currentKey)
            let skipContext = try RecordContext(database: database)
            defer { skipContext.cancel() }

            try await progress.markPhase1Range(from: currentKey, to: skipKey, context: skipContext)
            try await skipContext.commit()

            // 次のキーから再開
            continuation = skipKey

        } catch {
            // その他のエラーは再スロー
            throw error
        }
    }

    return (allIssues, totalScanned)
}

/// バッチ処理（修正版）
private func scrubIndexEntriesBatch(
    context: RecordContext,
    indexSubspace: Subspace,
    recordSubspace: Subspace,
    recordTypeNames: [String],
    startKey: FDB.Bytes,
    endKey: FDB.Bytes,
    warningCount: inout Int
) async throws -> (continuation: FDB.Bytes?, issues: [ScrubberIssue], lastKey: FDB.Bytes?, scannedCount: Int) {
    let transaction = context.getTransaction()

    var scannedBytes = 0
    var scannedCount = 0
    var issues: [ScrubberIssue] = []
    var lastProcessedKey: FDB.Bytes?

    let sequence = transaction.getRange(
        begin: startKey,
        end: endKey,
        snapshot: true
    )

    for try await (indexKey, _) in sequence {
        let keySize = indexKey.count

        // ✅ 前進保証: 最初のキー（scannedCount=0）は必ず処理する
        // 2つ目以降のキーは制限チェック
        if scannedCount > 0 && scannedBytes + keySize > configuration.maxTransactionBytes {
            // 制限到達: このキーは未処理
            return (indexKey, issues, lastProcessedKey, scannedCount)
        }

        // 処理実行
        scannedBytes += keySize
        scannedCount += 1

        // ... 実際の検証ロジック（既存コードと同じ）...

        lastProcessedKey = indexKey

        // スキャン制限チェック
        if scannedCount >= configuration.entriesScanLimit {
            let continuationKey = nextKey(after: indexKey)
            return (continuationKey, issues, lastProcessedKey, scannedCount)
        }
    }

    return (nil, issues, lastProcessedKey, scannedCount)
}
```

**前進保証の証明**:
1. **最初のキー**: `scannedCount=0` なので制限チェックをスキップ → 必ず処理 → `scannedCount=1`
2. **大きすぎる場合**: コミット時に `transaction_too_large` (2101) エラー
3. **エラー処理**: キーをスキップし、`nextKey(after:)` から再開
4. **結果**: 必ず前進する（無限ループ不可能）

---

### 問題2: 存在しないAPI参照

**指摘内容**:
> 例外処理の追記例が scrubPhase1() / scrubPhase2()、firstRange、progressContext、progress.insertRange といった現行コードに存在しない名前
> へ言及しており、そのままではコンパイル不可です。

**現行コードの実際のAPI**:
- `scrubPhase1()` → **実際**: `scrubIndexEntries(progress:)`
- `scrubPhase2()` → **実際**: `scrubRecords(progress:)`
- `firstRange` → **実際**: バッチごとに `startKey`, `endKey` を渡す
- `progressContext` → **実際**: 各バッチで新しい `RecordContext` を作成
- `progress.insertRange()` → **実際**: `progress.markPhase1Range(from:to:context:)`

**修正済みコード例** (上記参照)

---

### 問題3: 原子性改善の手順とプログレスコンテキスト

**指摘内容**:
> 原子性改善の手順でも同様に progressContext を想定していますが現行設計には存在せず、コミット順序の説明が不足しています。

**現行の実装確認** (OnlineIndexScrubber.swift:212-242):
```swift
while let currentKey = continuation {
    let context = try RecordContext(database: database)
    defer { context.cancel() }

    let (nextContinuation, batchIssues, batchEndKey, scannedCount) = try await scrubIndexEntriesBatch(...)

    // ❌ 問題: issues を先に記録
    allIssues.append(contentsOf: batchIssues)

    // プログレスマーク（同じ context 内）
    if let lastKey = batchEndKey {
        let rangeEnd = nextKey(after: lastKey)
        try await progress.markPhase1Range(from: currentKey, to: rangeEnd, context: context)
    }

    // ❌ コミット失敗時、allIssues には既に追加済み
    try await context.commit()

    continuation = nextContinuation
}
```

**原子性問題の詳細**:
1. `allIssues.append()` がコミット前に実行される
2. コミット失敗時、`batchIssues` は `allIssues` に残る
3. 結果: 修復されていない issues が "修復済み" として記録される

**正しい修正**:

```swift
while let currentKey = continuation {
    let context = try RecordContext(database: database)
    defer { context.cancel() }

    let (nextContinuation, batchIssues, batchEndKey, scannedCount) = try await scrubIndexEntriesBatch(...)

    // プログレスマーク（修復と同じトランザクション内）
    if let lastKey = batchEndKey {
        let rangeEnd = nextKey(after: lastKey)
        try await progress.markPhase1Range(from: currentKey, to: rangeEnd, context: context)
    }

    // ✅ 先にコミット
    try await context.commit()

    // ✅ コミット成功後に issues 記録
    allIssues.append(contentsOf: batchIssues)
    totalScanned += scannedCount

    continuation = nextContinuation
}
```

**コミット順序の保証**:
1. バッチ内の修復（deleteやsave）は `context` 内で実行
2. プログレスマークも同じ `context` 内
3. コミット成功 → issues を `allIssues` に追加
4. コミット失敗 → issues は破棄（次回バッチで再検出）

**注意**: `RangeSet` の実装によっては、プログレスマークが別トランザクションの場合もあるため、`markPhase1Range` の実装確認が必要。

---

### 問題4: transactionTimeoutMillis の API 設計

**指摘内容**:
> transactionTimeoutMillis の適用例として context.setTransactionTimeout を呼び出す案が示されていますが、RecordContext に
> はその API が定義されていません。

**現行の RecordContext API** (RecordContext.swift:1-100):
```swift
public final class RecordContext: Sendable {
    private let transaction: any TransactionProtocol

    public func commit() async throws { ... }
    public func cancel() { ... }
    public func getTransaction() -> any TransactionProtocol { ... }

    // ❌ setTransactionTimeout() は存在しない
}
```

**設計選択肢**:

#### Option A: RecordContext に API を追加（推奨）

```swift
// RecordContext.swift
extension RecordContext {
    /// Set transaction timeout
    /// - Parameter milliseconds: Timeout in milliseconds (0 = no timeout)
    /// - Throws: FDB errors if setting fails
    public func setTimeout(milliseconds: Int) throws {
        // TransactionProtocol には setOption() があると仮定
        try transaction.setOption(.timeout, value: milliseconds)
    }
}
```

**使用例**:
```swift
private func scrubIndexEntriesBatch(context: RecordContext, ...) async throws -> (...) {
    // タイムアウト設定
    if configuration.transactionTimeoutMillis > 0 {
        try context.setTimeout(milliseconds: configuration.transactionTimeoutMillis)
    }

    let transaction = context.getTransaction()
    // ... バッチ処理 ...
}
```

#### Option B: TransactionProtocol に直接アクセス

```swift
private func scrubIndexEntriesBatch(context: RecordContext, ...) async throws -> (...) {
    let transaction = context.getTransaction()

    // タイムアウト設定（TransactionProtocol 経由）
    if configuration.transactionTimeoutMillis > 0 {
        // FDB の Transaction API を使用
        // transaction.setTimeout(milliseconds: configuration.transactionTimeoutMillis)
        // または
        // transaction.setOption(.timeout, value: configuration.transactionTimeoutMillis)
    }

    // ... バッチ処理 ...
}
```

**注意**: `fdb-swift-bindings` の `TransactionProtocol` API を確認する必要があります。

**推奨**: Option A（RecordContext に API 追加）- カプセル化と型安全性のため

---

### 問題5: enableProgressLogging の命名統一

**指摘内容**:
> ログ機能の項目では設定名を configuration.progressLogging としていますが、既存構造体は enableProgressLogging を持っています。

**現行の Configuration** (OnlineIndexScrubber.swift:843-845):
```swift
public struct ScrubberConfiguration: Sendable {
    // ...
    public let enableProgressLogging: Bool  // ✅ 正しい名前
    // ...
}
```

**正しいログ実装**:

```swift
private func logProgress(_ message: String) {
    if configuration.enableProgressLogging {  // ✅ 正しい名前
        print("[OnlineIndexScrubber] \(Date()) \(message)")
    }
}

private func scrubIndexEntries(progress: ScrubberProgress) async throws -> ([ScrubberIssue], Int) {
    logProgress("Starting Phase 1: Index→Record validation")

    var continuation: FDB.Bytes? = beginKey
    // ...

    while let currentKey = continuation {
        logProgress("Processing batch from \(currentKey.hexEncodedString())")

        // ... バッチ処理 ...

        logProgress("Batch complete: scanned=\(scannedCount), issues=\(batchIssues.count)")
    }

    logProgress("Phase 1 complete: total scanned=\(totalScanned), total issues=\(allIssues.count)")
    return (allIssues, totalScanned)
}
```

---

### 問題6: readYourWrites の完全な実装

**指摘内容**:
> readYourWrites の切り替えでは getRange の snapshot フラグしか調整しておらず、getValue など他の読み取りは依然 snapshot
> を強制しています。さらに、FDB で read-your-writes を有効化するにはトランザクションオプションを明示的に設定する必要があるため、ここだけ
> の変更では挙動が一致しません。

**現行の実装問題** (OnlineIndexScrubber.swift:268-272):
```swift
// ❌ 不完全: getRange のみ snapshot 指定
let sequence = transaction.getRange(
    begin: startKey,
    end: endKey,
    snapshot: true  // ← ここだけ
)
```

**同じファイル内の他の読み取り操作** (OnlineIndexScrubber.swift:309-310):
```swift
let recordKey = recordSubspace.pack(...)
let recordData = try await transaction.get(recordKey, snapshot: true)
// ❌ ここも snapshot=true で固定
```

**完全な readYourWrites 実装**:

```swift
private func scrubIndexEntriesBatch(context: RecordContext, ...) async throws -> (...) {
    let transaction = context.getTransaction()

    // ✅ Step 1: トランザクションオプションの設定（FDB レベル）
    let snapshot = !configuration.readYourWrites
    if !configuration.readYourWrites {
        // ReadYourWrites を無効化（メモリ最適化）
        // transaction.setOption(.readYourWritesDisable)
    }
    // Note: readYourWrites=true の場合、デフォルトで有効なので設定不要

    var scannedBytes = 0
    var scannedCount = 0
    var issues: [ScrubberIssue] = []
    var lastProcessedKey: FDB.Bytes?

    // ✅ Step 2: getRange で snapshot フラグを設定
    let sequence = transaction.getRange(
        begin: startKey,
        end: endKey,
        snapshot: snapshot  // ← 設定に従う
    )

    for try await (indexKey, _) in sequence {
        // ... 制限チェック ...

        // ✅ Step 3: get でも snapshot フラグを設定
        for recordTypeName in recordTypeNames {
            // ...
            let recordKey = recordSubspace.pack(...)
            let recordData = try await transaction.get(
                recordKey,
                snapshot: snapshot  // ← 設定に従う
            )
            // ...
        }

        lastProcessedKey = indexKey
    }

    return (nil, issues, lastProcessedKey, scannedCount)
}
```

**Phase 2 でも同様の修正が必要** (scrubRecordsBatch):
```swift
private func scrubRecordsBatch(context: RecordContext, ...) async throws -> (...) {
    let transaction = context.getTransaction()

    // ✅ トランザクションオプションの設定
    let snapshot = !configuration.readYourWrites
    if !configuration.readYourWrites {
        // transaction.setOption(.readYourWritesDisable)
    }

    // ✅ レコードスキャン
    let recordSequence = transaction.getRange(
        begin: startKey,
        end: endKey,
        snapshot: snapshot  // ← 設定に従う
    )

    for try await (recordKey, recordData) in recordSequence {
        // ...

        // ✅ インデックスエントリのチェック
        for indexKey in expectedIndexKeys {
            let indexData = try await transaction.get(
                indexKey,
                snapshot: snapshot  // ← 設定に従う
            )
            // ...
        }
    }

    return (nil, issues, lastProcessedKey, scannedCount)
}
```

**readYourWrites の意味**:
- `false` (snapshot=true): メモリ最適化、同一トランザクション内の書き込みは見えない
- `true` (snapshot=false): 一貫性保証、同一トランザクション内の書き込みが見える（メモリ使用量増加）

**Scrubber では `false` が推奨**:
- 大量のレコードをスキャンする（メモリ節約が重要）
- 読み取り専用操作（修復は別のキーで行われる）
- 同一トランザクション内の書き込みを参照する必要がない

---

## 修正済み実装チェックリスト

### Priority 0: Critical Fixes

#### ✅ Fix 1: 無限ループ防止（完全版）

**変更箇所**:
1. `scrubIndexEntries()` (Line 195-243):
   - `transaction_too_large` エラーハンドリング追加
   - 大きすぎるキーをスキップする処理

2. `scrubIndexEntriesBatch()` (Line 248-365):
   - 前進保証: `if scannedCount > 0 && ...` で最初のキーは必ず処理

3. `scrubRecords()` と `scrubRecordsBatch()`:
   - 同様の修正

**テスト**:
- [ ] 5MB キーで無限ループが発生しないこと
- [ ] スキップされたキーがログに記録されること
- [ ] プログレスが正しく更新されること

**Estimated Time**: 2 hours（エラーハンドリング含む）

---

#### ✅ Fix 2: 原子性修正

**変更箇所**:
1. `scrubIndexEntries()` (Line 227-229):
   ```swift
   // OLD:
   allIssues.append(contentsOf: batchIssues)
   // ... progress marking ...
   try await context.commit()

   // NEW:
   // ... progress marking ...
   try await context.commit()
   allIssues.append(contentsOf: batchIssues)  // ← コミット後
   totalScanned += scannedCount                // ← コミット後
   ```

2. `scrubRecords()`:
   - 同様の修正

**テスト**:
- [ ] コミット失敗時、issues が記録されないこと
- [ ] 統計情報が正確であること

**Estimated Time**: 1 hour

---

### Priority 1: High Priority

#### ✅ Fix 3A: transactionTimeoutMillis 実装

**変更箇所**:
1. `RecordContext.swift` に新規 API 追加:
   ```swift
   extension RecordContext {
       public func setTimeout(milliseconds: Int) throws {
           // TransactionProtocol の setOption() を使用
           // 実装は fdb-swift-bindings の API に依存
       }
   }
   ```

2. `scrubIndexEntriesBatch()` と `scrubRecordsBatch()`:
   ```swift
   if configuration.transactionTimeoutMillis > 0 {
       try context.setTimeout(milliseconds: configuration.transactionTimeoutMillis)
   }
   ```

**注意**: `fdb-swift-bindings` の API 確認が必要

**Estimated Time**: 2 hours（API 調査含む）

---

#### ✅ Fix 3B: readYourWrites 完全実装

**変更箇所**:
1. `scrubIndexEntriesBatch()`:
   - トランザクションオプション設定
   - 全ての `getRange()` と `get()` で `snapshot` フラグ設定

2. `scrubRecordsBatch()`:
   - 同様の修正

**Estimated Time**: 1.5 hours

---

#### ✅ Fix 4: リトライロジック

**変更箇所**:
1. 新規ヘルパーメソッド追加:
   ```swift
   private func withRetry<T>(
       operation: () async throws -> T
   ) async throws -> T {
       var attempts = 0
       while true {
           do {
               return try await operation()
           } catch let error as FDB.Error where error.isRetryable {
               attempts += 1
               if attempts >= configuration.maxRetries {
                   throw error
               }
               logProgress("Retrying... (\(attempts)/\(configuration.maxRetries))")
               try await Task.sleep(nanoseconds: UInt64(configuration.retryDelayMillis * 1_000_000))
           }
       }
   }
   ```

2. コミット時に使用:
   ```swift
   try await withRetry {
       try await context.commit()
   }
   ```

**Estimated Time**: 2 hours

---

### Priority 2: Medium Priority

#### ✅ Fix 5: Progress Logging

**変更箇所**:
1. ログヘルパー追加:
   ```swift
   private func logProgress(_ message: String) {
       if configuration.enableProgressLogging {  // ✅ 正しい名前
           print("[OnlineIndexScrubber] \(Date()) \(message)")
       }
   }
   ```

2. 各フェーズでログ追加

**Estimated Time**: 1 hour

---

## 実装順序（修正版）

1. **Day 1**: P0 Fixes
   - [ ] Morning: Fix 1（無限ループ - 完全版）- 2 hours
   - [ ] Afternoon: Fix 2（原子性）- 1 hour
   - [ ] End of day: テストと検証

2. **Day 2**: P1 Fixes
   - [ ] Morning: Fix 3A（timeout）+ Fix 3B（RYW）- 3.5 hours
   - [ ] Afternoon: Fix 4（リトライ）- 2 hours

3. **Day 3**: P2 + Documentation
   - [ ] Morning: Fix 5（ロギング）- 1 hour
   - [ ] Afternoon: 統合テスト + ドキュメント更新

**Total**: 10.5 hours

---

## 今後の確認事項

1. **fdb-swift-bindings の API**:
   - TransactionProtocol のオプション設定方法
   - setTimeout の実装方法
   - readYourWritesDisable オプションの有無

2. **RangeSet の実装**:
   - `markPhase1Range()` が同じトランザクション内で動作するか
   - 別トランザクションの場合、原子性保証の再設計が必要

3. **FDB.Error の拡張**:
   - `isRetryable` プロパティの実装
   - リトライ可能なエラーコードの列挙

---

**Document Status**: Corrected Based on Code Review
**Next Steps**: fdb-swift-bindings API の確認後、実装開始

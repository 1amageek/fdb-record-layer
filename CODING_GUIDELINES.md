# Swift Coding Guidelines

## 基本原則

### 明確性を最優先する
- コードは他の開発者が読むものである
- 簡潔さより明確さを優先する
- 型システムを活用して不正な状態を防ぐ

### Swift API Design Guidelinesに従う
- https://www.swift.org/documentation/api-design-guidelines/
- 標準ライブラリのパターンを踏襲する
- 一貫性のある命名規約を使用する

### レビュアーの時間を尊重する
- PRは適切なサイズに保つ（目安: 500行以内）
- 変更の意図を明確に説明する
- フィードバックには根拠を持って応答する

---

## 1. 型安全性

### 1.1 Sendable適合の明示

Swift 6では、型がスレッドセーフかどうかを曖昧にしない。

**正しい実装:**
```swift
// 無条件にSendable
struct Configuration: Sendable {
    let host: String
    let port: Int
}

// 条件付きSendable
struct Container<Element>: Sendable where Element: Sendable {
    private let storage: [Element]
}

// 意図的に非Sendable
struct UnsafeCache {
    private var storage: [String: Any] = [:]
}
@available(*, unavailable)
extension UnsafeCache: Sendable {}
```

**避けるべき実装:**
```swift
// Sendable制約の漏れ
struct Container<Element> {
    private let storage: [Element]
}
extension Container: Sendable {} // Elementが非Sendableでも通る

// 実際には非スレッドセーフ
struct Cache: Sendable {
    private var storage: [String: Any] = [:] // 可変状態を持つ
}
```

**チェックリスト:**
- 全ての公開型について、Sendableかどうか明示的に決定する
- ジェネリック型は適切な`where`句でSendable制約を追加する
- 意図的に非Sendableな型は`@available(*, unavailable)`で明示する
- 内部で可変状態を持つ型はスレッドセーフ機構を実装してからSendableにする
- `@unchecked Sendable`の増殖を避け、既存の安全なパターン（`NIOLoopBound`等）を再利用する
- 実際の制約を反映する適切な名前付き型を使用する（`@unchecked Sendable`で嘘をつかない）

### 1.2 コンパイラバージョンガード

標準ライブラリの変更に対応し、複数バージョンで動作するコードを書く。

**正しい実装:**
```swift
#if compiler(<6.2)
@available(*, unavailable)
extension LockStorage: Sendable {}
#endif
// Swift 6.2以降はManagedBufferが既に宣言している

#if compiler(>=6.0)
extension MyType {
    @available(macOS 15, iOS 18, *)
    public func newFeature() { }
}
#endif
```

**避けるべき実装:**
```swift
// 言語モードで条件分岐（期待通り動作しない）
#if swift(>=6.0)
extension MyType {
    public func newFeature() { }
}
#endif

// バージョンガードなしで最新機能を使用
@available(*, unavailable)
extension ManagedBuffer: Sendable {} // Swift 6.2では既に定義済み
```

**条件分岐の使い分け:**
- `#if compiler(>=X.Y)`: コンパイラの機能やバグ修正に依存
- `#if swift(>=X.Y)`: 言語構文の変更に依存（稀）
- `@available(platform version, *)`: ランタイムAPIの可用性

---

## 2. API設計

### 2.1 命名規約

**標準ライブラリのパターンに従う:**
```swift
// ジェネリックエラー型は "Failure"
func process<Failure: Error>(
    _ operation: () throws(Failure) -> Void
) throws(Failure)

// 動詞の選択
func append(_ element: Element) // 既存機能の拡張
func add(_ element: Element) // 新しい操作

// タプルパラメータのラベル
func write(_ data: (buffer: UnsafeRawBufferPointer, count: Int))

// プレフィックスの使用
public func publicAPI()
internal func _internalHelper()
@usableFromInline internal func _inlinableHelper()
```

**避けるべき命名:**
```swift
// 非標準的な名前
func process<E: Error>(_ operation: () throws(E) -> Void) throws(E)

// 曖昧な動詞
func set(_ element: Element)

// ラベルのないタプル
func write(_ data: (UnsafeRawBufferPointer, Int))

// 不適切なプレフィックス
public func _publicAPI()
```

### 2.2 API表面積の最小化

必要最小限のAPIのみを公開し、後から追加する。

**正しいアプローチ:**
```swift
// シンプルなwrapper
public struct NIOFilePath {
    private let _underlying: FilePath

    public init(_ filePath: FilePath) {
        self._underlying = filePath
    }

    public var underlying: FilePath {
        _underlying
    }
}
```

**避けるべきアプローチ:**
```swift
// 過剰な公開API
public struct NIOFilePath {
    public var root: Root
    public var components: ComponentView
    public var description: String
    public var debugDescription: String
    public func normalized() -> Self
    public func lexicallyNormalized() -> Self
    // 多数の不要なメソッド
}
```

**判断基準:**

公開すべきAPI:
- ユーザーが直接使用する機能
- ドキュメント化可能な明確なユースケースがある

公開すべきでないAPI:
- 内部実装の詳細
- 将来変更する可能性が高い
- ユースケースが不明確

### 2.3 API簡素化と既存パターンの再利用

新しいプロトコルを導入する前に、既存の抽象化を拡張できないか検討する。

**正しいアプローチ:**
```swift
// 既存プロトコルに辞書プロパティを追加
protocol ExpressibleByArgument {
    // 既存メンバー
    init?(argument: String)
    var defaultValueDescription: String { get }

    // 新規追加（新プロトコルではなく）
    static var allValueDescriptions: [String: String] { get }
}
```

**避けるべきアプローチ:**
```swift
// 新しいプロトコルを導入
protocol EnumerableOptionValue: ExpressibleByArgument {
    static var allValueDescriptions: [String: String] { get }
}
```

**破壊的変更時の非推奨戦略:**
```swift
// 古いプロパティを非推奨化し、新しいプロパティを追加
struct ToolInfo {
    @available(*, deprecated, renamed: "discussion2")
    public var discussion: String

    public var discussion2: ArgumentDiscussion
}
```

**Result buildersより単純な配列パラメータを優先:**
```swift
// 正しい: シンプルで柔軟
CommandConfiguration(
    subcommands: [M.self],
    groupedSubcommands: [
        CommandGroup(name: "Tools", subcommands: [Foo.self, Bar.self])
    ]
)

// 避ける: 動的操作を制限する複雑なbuilder
CommandConfiguration {
    M.self
    CommandGroup("Tools") {
        Foo.self
        Bar.self
    }
}
```

### 2.4 レイヤリング原則

APIレイヤーと実装レイヤーを明確に分離する。

**正しい実装:**
```swift
// Public API層
public func openFile(_ path: NIOFilePath) throws -> FileHandle {
    try _openFile(path.underlying)
}

// 実装層
@usableFromInline
internal func _openFile(_ path: FilePath) throws -> FileHandle {
    // 実装
}
```

**避けるべき実装:**
```swift
// レイヤーの混在
public func openFile(_ path: FilePath) throws -> FileHandle {
    // Public APIで内部型を露出
}
```

---

## 3. 所有権とメモリ管理

### 3.1 所有権の明示

関数が引数の所有権をどう扱うか、シグネチャで明確にする。

**4つの所有権パターン:**
```swift
// 1. Borrowing - データをコピー
func append(copying other: Container) {
    self.storage.append(contentsOf: other.storage)
}

// 2. Moving - ソースを空にする
func append(moving other: inout Container) {
    self.storage.append(contentsOf: other.storage)
    other.storage.removeAll()
}

// 3. Consuming - ソースを完全に消費
func append(consuming other: consuming Container) {
    self.storage.append(contentsOf: other.storage)
}

// 4. 従来型 - 標準的なコピー
func append(contentsOf other: Container) {
    self.storage.append(contentsOf: other.storage)
}
```

### 3.2 ライフタイム管理

リソースのライフタイムを正確に管理し、use-after-freeを防ぐ。

**正しい実装:**
```swift
class ResourceManager {
    private var handle: OpaquePointer?

    func close() {
        if let handle = handle {
            releaseResource(handle)
            self.handle = nil // 解放後は即座にnil
        }
    }

    deinit {
        close()
    }
}

// deferでクリーンアップを保証
func processFile() throws {
    let file = openFile()
    defer { closeFile(file) }
    try processContents(file)
}

// 不変条件のチェック
mutating func removeAll(where predicate: (Element) throws -> Bool) rethrows {
    defer { _checkInvariants() }

    for index in indices.reversed() {
        if try predicate(self[index]) {
            remove(at: index)
        }
    }
}
```

**避けるべき実装:**
```swift
// 解放後の参照を保持
func close() {
    if let handle = handle {
        releaseResource(handle)
        // handleをnilに設定していない
    }
}

// クリーンアップの漏れ
func processFile() throws {
    let file = openFile()
    try processContents(file)
    closeFile(file) // 例外時に呼ばれない
}
```

### 3.3 メモリアライメント

構造体のメモリレイアウトを意識し、アライメント要件を満たす。

**正しい実装:**
```swift
struct TrailingArray<Header, Element> {
    static func allocate(header: Header, capacity: Int) -> TrailingArray {
        let elementAlignment = MemoryLayout<Element>.alignment
        let headerSize = MemoryLayout<Header>.size

        // ヘッダーサイズをElement alignmentに切り上げ
        let alignedHeaderSize = (headerSize + elementAlignment - 1)
            & ~(elementAlignment - 1)

        let elementSize = MemoryLayout<Element>.stride * capacity
        let totalSize = alignedHeaderSize + elementSize

        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: totalSize,
            alignment: elementAlignment
        )

        return TrailingArray(_pointer: pointer)
    }
}
```

**避けるべき実装:**
```swift
// アライメントを考慮しない
static func allocate(header: Header, capacity: Int) -> TrailingArray {
    let size = MemoryLayout<Header>.size
        + MemoryLayout<Element>.stride * capacity

    let pointer = UnsafeMutableRawPointer.allocate(
        byteCount: size,
        alignment: MemoryLayout<Header>.alignment
    )
    // Elementが強いalignmentを要求する場合、不正なアクセス
}
```

---

## 4. エラーハンドリング

### 4.1 Typed Throws

エラー型が明確な場合はtyped throwsを使用する。

**正しい実装:**
```swift
enum ParseError: Error {
    case invalidFormat
    case unexpectedEnd
}

func parse(_ input: String) throws(ParseError) -> AST {
    guard !input.isEmpty else {
        throw ParseError.unexpectedEnd
    }
    // 実装
}

// ジェネリックなtyped throws
func transform<T, E: Error>(
    _ value: T,
    using: (T) throws(E) -> T
) throws(E) -> T {
    try using(value)
}
```

**避けるべき実装:**
```swift
// rethrows（旧スタイル）
func transform<T>(
    _ value: T,
    using: (T) throws -> T
) rethrows -> T {
    try using(value)
}
```

### 4.2 バリデーションエラー

ユーザーエラーにはfatalErrorを使わず、適切にメッセージを表示する。

**正しい実装:**
```swift
// CLIツール
func validate() -> ValidationResult {
    // バリデーション処理
}

func run() {
    let result = validate()
    if let error = result.error {
        FileHandle.standardError.write(
            "Error: \(error.message)\n".data(using: .utf8)!
        )
        exit(error.exitCode)
    }
}

// ライブラリ
enum ValidationError: Error, CustomStringConvertible {
    case missingRequired(String)
    case invalidFormat(String)

    var description: String {
        switch self {
        case .missingRequired(let field):
            return "Required field '\(field)' is missing"
        case .invalidFormat(let field):
            return "Field '\(field)' has invalid format"
        }
    }
}
```

**避けるべき実装:**
```swift
// fatalErrorの不適切な使用
func validate() {
    guard hasRequiredFields() else {
        fatalError("Validation failed") // backtraceがメッセージを隠す
    }
}
```

### 4.3 エラー伝播の維持

エラーを下流に伝播し、情報損失を防ぐ。

**正しい実装:**
```swift
func errorCaught(error: Error) {
    // エラーを記録
    handleError(error)

    // 下流に伝播（情報損失を防ぐ）
    context.fireErrorCaught(error)
}
```

**避けるべき実装:**
```swift
func errorCaught(error: Error) {
    // エラーを消費（下流に伝播しない）
    handleError(error)
    // 下流のハンドラーがエラーを受け取れない
}
```

**エラーメッセージの明確化:**
```swift
// CustomStringConvertible実装
extension NIOConnectionError: CustomStringConvertible {
    var description: String {
        switch self {
        case .closed:
            return "NIOConnectionError: Connection closed"
        case .timeout:
            return "NIOConnectionError: Connection timeout"
        case .unknown(let error):
            // 型名を含める（デバッグ時に有用）
            return "NIOConnectionError: unknown (\(type(of: error)))"
        }
    }
}

// String interpolationを使用（localizedDescriptionではなく）
let message = "Failed to connect: \(error)"
```

### 4.4 エラー後の状態保証

エラーが発生しても、データ構造の不変条件は維持する。

**正しい実装:**
```swift
mutating func removeAll(where predicate: (Element) throws -> Bool) rethrows {
    defer { _checkInvariants() }

    var indicesToRemove: [Index] = []

    // 削除する要素を特定（この段階では変更しない）
    for index in indices {
        if try predicate(self[index]) {
            indicesToRemove.append(index)
        }
    }

    // 削除実行（throwしない操作のみ）
    for index in indicesToRemove.reversed() {
        remove(at: index)
    }
}
```

**避けるべき実装:**
```swift
// 例外非安全
mutating func removeAll(where predicate: (Element) throws -> Bool) rethrows {
    for index in indices.reversed() {
        if try predicate(self[index]) {
            remove(at: index)
            // predicateがthrowした場合、データ構造が中途半端な状態
        }
    }
}
```

---

## 5. テスト

### 5.1 再現可能なテスト

テストは常に同じ結果を返す。乱数や時刻に依存しない。

**正しい実装:**
```swift
func testShuffle() {
    var rng = SystemRandomNumberGenerator(seed: 42)
    let input = [1, 2, 3, 4, 5]
    let result = input.shuffled(using: &rng)
    XCTAssertEqual(result, [2, 5, 1, 4, 3])
}

func testTimestamp() {
    let fixedDate = Date(timeIntervalSince1970: 1234567890)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    XCTAssertEqual(formatter.string(from: fixedDate), "2009-02-13")
}
```

**避けるべき実装:**
```swift
// ランダムな入力
func testShuffle() {
    let result = [1, 2, 3].shuffled() // 毎回異なる結果
    XCTAssertEqual(result.count, 3) // テストが弱い
}

// 現在時刻への依存
func testAge() {
    let age = calculateAge(from: birthDate, to: Date())
    XCTAssertEqual(age, 55) // 日付により失敗
}
```

### 5.2 独立した期待値

テスト対象と同じロジックで期待値を生成しない。

**正しい実装:**
```swift
func testFilter() {
    let numbers = [1, 2, 3, 4, 5, 6]
    let evens = numbers.filter { $0 % 2 == 0 }
    XCTAssertEqual(evens, [2, 4, 6]) // 手動で定義
}

// 別の実装で検証
func testQuickSort() {
    let input = [3, 1, 4, 1, 5, 9, 2, 6]
    let result = quickSort(input)
    XCTAssertEqual(result, input.sorted())
}
```

**避けるべき実装:**
```swift
// テスト対象と同じロジック
func testFilter() {
    let numbers = [1, 2, 3, 4, 5, 6]
    let evens = numbers.filter { $0 % 2 == 0 }
    let expected = numbers.filter { $0 % 2 == 0 } // 同じロジック
    XCTAssertEqual(evens, expected)
}
```

### 5.3 環境変数とグローバル状態のテスト

環境変数は可変共有グローバル状態であり、並列テスト実行時に競合を引き起こす。

**正しい実装:**
```swift
func testEnvironmentVariable() {
    // 並列テストモード検出
    let isParallelTest = CommandLine.arguments.contains("--parallel")
    guard !isParallelTest else {
        // 並列実行時はスキップ
        return
    }

    // テスト開始前に環境変数を保存
    let originalValue = ProcessInfo.processInfo.environment["COLUMNS"]

    // テスト実行
    setenv("COLUMNS", "80", 1)
    XCTAssertEqual(getTerminalWidth(), 80)

    // テスト終了後に復元
    if let original = originalValue {
        setenv("COLUMNS", original, 1)
    } else {
        unsetenv("COLUMNS")
    }
}
```

**避けるべき実装:**
```swift
// 環境変数を変更して復元しない
func testEnvironmentVariable() {
    setenv("COLUMNS", "80", 1)
    XCTAssertEqual(getTerminalWidth(), 80)
    // 他のテストに影響する
}
```

**代替アプローチ:**
```swift
// テストターゲット全体で環境変数を強制unset
override func setUp() {
    super.setUp()
    unsetenv("COLUMNS")
    unsetenv("LINES")
}

// ヘルプ生成テストでは明示的に幅を指定
func testHelpGeneration() {
    let help = generateHelp(terminalWidth: 80)
    XCTAssertEqual(help, expectedOutput)
}
```

### 5.4 包括的なカバレッジ

境界条件、エッジケース、大量データを全てテストする。

**正しい実装:**
```swift
func testRemoveAll() {
    for count in [0, 1, 2, 10, 100, 1000] {
        var collection = MyCollection(1...count)
        collection.removeAll(where: { $0 % 2 == 0 })
        XCTAssertTrue(collection.allSatisfy { $0 % 2 == 1 })
    }
}

func testSubstring() {
    let string = "Hello"

    // 空範囲
    XCTAssertEqual(string[string.startIndex..<string.startIndex], "")

    // 全体
    XCTAssertEqual(string[string.startIndex..<string.endIndex], "Hello")

    // 最初の1文字
    let secondIndex = string.index(after: string.startIndex)
    XCTAssertEqual(string[string.startIndex..<secondIndex], "H")
}
```

**避けるべき実装:**
```swift
// 単一サイズのみ
func testRemoveAll() {
    var collection = MyCollection([1, 2, 3])
    collection.removeAll(where: { $0 % 2 == 0 })
    XCTAssertEqual(collection, MyCollection([1, 3]))
}
```

### 5.4 例外安全性のテスト

throwing操作の途中で例外が発生しても、データ構造の整合性を保つ。

**正しい実装:**
```swift
func testRemoveAllThrows() {
    struct TestError: Error {}
    var heap = Heap([1, 2, 3, 4, 5])

    XCTAssertThrowsError(
        try heap.removeAll(where: { element in
            if element == 3 { throw TestError() }
            return element % 2 == 0
        })
    )

    // 例外後もデータ構造は有効
    XCTAssertNoThrow(heap._checkInvariants())
}
```

### 5.5 プラットフォーム依存テスト

プラットフォーム固有の機能は、関数本体内で可用性をチェックする。

**正しい実装:**
```swift
func testNewFeature() {
    guard #available(macOS 15, iOS 18, *) else {
        return
    }
    let result = useNewAPI()
    XCTAssertNotNil(result)
}

#if os(Linux)
func testLinuxSpecific() {
    XCTAssertTrue(linuxSpecificBehavior())
}
#endif
```

**避けるべき実装:**
```swift
// @available属性（XCTestは未対応プラットフォームでも呼び出す）
@available(macOS 15, *)
func testNewFeature() {
    let result = useNewAPI() // macOS 14でクラッシュ
    XCTAssertNotNil(result)
}
```

---

## 6. パフォーマンス

### 6.1 最適化の根拠

最適化には必ずベンチマーク結果を示す。

**正しいアプローチ:**
```swift
/// Optimized implementation using manual specialization.
///
/// Performance:
/// - Before: 0.24s (100M iterations)
/// - After: 0.18s (100M iterations)
/// - Improvement: 25-30% faster
///
/// Trade-offs:
/// - Memory: O(n) cache vs O(1)
/// - Lookup: O(1) vs O(n)
func optimizedCheck() -> Bool {
    // 実装
}
```

**避けるべきアプローチ:**
```swift
// "This should be faster"
func optimizedSort() { // ベンチマーク結果なし
    // 複雑な実装
}
```

### 6.2 安全性とパフォーマンスのトレードオフ

**SSWG方針: パフォーマンスはunsafe codeを使用する十分な理由ではない**

**正しいアプローチ:**
```swift
// Safe実装を優先
func readIntegers(from buffer: ByteBuffer, count: Int) -> [Int] {
    var result: [Int] = []
    result.reserveCapacity(count)

    for i in 0..<count {
        let offset = i * MemoryLayout<Int>.stride  // stride使用
        if let value = buffer.getInteger(at: offset, as: Int.self) {
            result.append(value)
        }
    }
    return result
}
```

**避けるべきアプローチ:**
```swift
// パフォーマンス目的で不必要にunsafe codeを使用
func readIntegers(from buffer: ByteBuffer, count: Int) -> [Int] {
    buffer.withUnsafeReadableBytes { pointer in
        // コンパイラはspecializationで最適化可能なのでunsafeは不要
        return (0..<count).map { i in
            pointer.loadUnaligned(
                fromByteOffset: i * MemoryLayout<Int>.size,  // strideではなくsize
                as: Int.self
            )
        }
    }
}
```

**stride vs sizeの使い分け:**
```swift
// 正しい: strideを使用（padding bytesを考慮）
let offset = index * MemoryLayout<Element>.stride

// 間違い: sizeを使用（paddingを無視）
let offset = index * MemoryLayout<Element>.size
```

**@inlinableアノテーションの一貫性:**
```swift
// 正しい: ジェネリック型の全メソッドで一貫
public struct AsyncSequenceProducer<Element> {
    @inlinable
    public func yield(_ element: Element) { }

    @inlinable
    public func finish() { }

    @inlinable  // 忘れずに全てに付与
    public func cancel() { }
}

// 避ける: 一部のみに付与（一貫性がない）
public struct AsyncSequenceProducer<Element> {
    @inlinable
    public func yield(_ element: Element) { }

    public func finish() { }  // @inlinableが欠落

    @inlinable
    public func cancel() { }
}
```

### 6.3 不要なアロケーションの回避

**正しい実装:**
```swift
// Collection genericsを使用
func process<C: Collection>(_ items: C) where C.Element == Int {
    for item in items {
        // 処理
    }
}

// withUnsafeBytesを使用
func hash(_ data: Data) -> Int {
    data.withUnsafeBytes { buffer in
        hashBytes(buffer)
    }
}

// 遅延評価
let result = array
    .lazy
    .filter { $0 > 0 }
    .map { $0 * 2 }
    .first
```

**避けるべき実装:**
```swift
// 不要な配列アロケーション
func process(_ items: [Int]) { // 具象型を要求
    // 処理
}

// データコピー
func hash(_ data: Data) -> Int {
    let bytes = Array(data) // 不要なコピー
    return hashBytes(bytes)
}
```

---

## 7. ドキュメント

### 7.1 APIドキュメント

全ての公開APIに、使い方と動作を説明するドキュメントを付ける。

**正しい実装:**
```swift
/// Writes the contents of `buffer` to this buffer.
///
/// This method appends the bytes from `buffer` to the end of this buffer,
/// advancing the writer index by the number of bytes written.
///
/// - Parameter buffer: The buffer containing bytes to write.
/// - Returns: The number of bytes written.
/// - Complexity: O(n), where n is the length of `buffer`.
///
/// Example:
/// ```swift
/// var buffer = ByteBuffer()
/// let data = ByteBuffer(string: "Hello")
/// let written = buffer.write(data)
/// print(written) // 5
/// ```
@discardableResult
public mutating func write(_ buffer: ByteBuffer) -> Int
```

**避けるべき実装:**
```swift
// ドキュメントなし
public mutating func write(_ buffer: ByteBuffer) -> Int

// 不完全なドキュメント
/// Writes a buffer.
public mutating func write(_ buffer: ByteBuffer) -> Int
```

### 7.2 コード例の正確性

ドキュメント内のコード例は、必ずコンパイルして動作確認する。

**正しい実装:**
```swift
/// Sorts the elements in place.
///
/// Example:
/// ```swift
/// var set: OrderedSet = [3, 1, 2]
/// set.sort()
/// print(set) // [1, 2, 3]
/// ```
public mutating func sort()
```

**避けるべき実装:**
```swift
/// Example:
/// ```swift
/// let set: OrderedSet = [3, 1, 2]
/// set.sort() // コンパイルエラー: mutating methodをletで呼べない
/// ```
public mutating func sort()
```

### 7.3 実装コメント

複雑な実装には、なぜそうするのかを説明するコメントを付ける。

**正しい実装:**
```swift
// アライメント要件を満たすため、ヘッダーサイズを切り上げる
// ElementがHeaderより強いアライメントを要求する可能性がある
let alignedHeaderSize = (headerSize + elementAlignment - 1)
    & ~(elementAlignment - 1)

// join()時にnilに設定してdeallocated pthread_tを保持しないため
// POSIX仕様では.join後のpthread_t使用は未定義動作
if let handle = handle {
    pthread_join(handle, nil)
    self.handle = nil
}
```

**避けるべき実装:**
```swift
// コードの繰り返し
// ヘッダーサイズを計算
let size = (headerSize + alignment - 1) & ~(alignment - 1)

// 自明なコメント
// handleをnilに設定
self.handle = nil
```

---

## 8. プラットフォーム互換性

### 8.1 条件付きコンパイル

**正しい実装:**
```swift
// コンパイラバージョンで分岐
#if compiler(>=6.0)
extension MyType {
    @available(macOS 15, iOS 18, *)
    public func newFeature() { }
}
#endif

// OSで分岐
#if os(Linux)
import Glibc
#elseif os(macOS) || os(iOS)
import Darwin
#elseif os(Windows)
import CRT
#endif

// 機能の有無で分岐
#if canImport(Foundation)
import Foundation
#endif
```

**避けるべき実装:**
```swift
// 言語モードで分岐（期待通り動作しない）
#if swift(>=6.0)
extension MyType {
    public func newFeature() { }
}
#endif
```

### 8.2 プラットフォーム固有の対応

プラットフォーム固有の問題は、shimレイヤーで吸収する。

**正しい実装:**
```swift
// プラットフォーム固有のshim
#if os(Windows)
private func platformInit() {
    WSAStartup(...)
}
#elseif os(Linux)
private func platformInit() {
    // Linux特有の初期化
}
#endif

// 公開APIは統一
public func initialize() {
    platformInit()
    // 共通の初期化処理
}

// 型エイリアスで吸収
#if os(Windows)
typealias PlatformHandle = HANDLE
#else
typealias PlatformHandle = Int32
#endif

public struct FileHandle {
    internal let platformHandle: PlatformHandle
}
```

**避けるべき実装:**
```swift
// プラットフォーム分岐が散在
public func process() {
    #if os(Windows)
    // Windows処理
    #else
    // Unix処理
    #endif

    // 共通処理

    #if os(Windows)
    // また別のWindows処理
    #else
    // また別のUnix処理
    #endif
}
```

---

## 9. コード品質

### 9.1 型安全性の活用

**正しい実装:**
```swift
// Enumで無効な状態を防ぐ
enum TupleTypeCode: UInt8 {
    case null = 0x00
    case bytes = 0x01
    case string = 0x02
    case int64 = 0x15
}

// コンパイラ合成を活用
struct Configuration: Equatable, Hashable, Codable {
    let host: String
    let port: Int
}
```

**避けるべき実装:**
```swift
// 生の値を使用
func encode(_ type: UInt8) {
    switch type {
    case 0x00: // Null
    case 0x01: // Bytes
    // 無効な値を受け入れてしまう
    }
}

// 手動実装
struct Configuration {
    let host: String
    let port: Int

    static func == (lhs: Configuration, rhs: Configuration) -> Bool {
        // 手動で実装
    }
}
```

### 9.2 コード重複の回避

既存メソッドに委譲してロジックの重複を避ける。

**正しい実装:**
```swift
// 既存メソッドに委譲
func peekLengthPrefixedSlice<T: FixedWidthInteger>(
    at index: Int,
    as: T.Type = T.self
) -> ByteBuffer? {
    // getLengthPrefixedSliceを呼び出す（重複を避ける）
    var copy = self
    return copy.getLengthPrefixedSlice(at: index, as: T.self)
}
```

**避けるべき実装:**
```swift
// ロジックを重複
func peekLengthPrefixedSlice<T: FixedWidthInteger>(
    at index: Int,
    as: T.Type = T.self
) -> ByteBuffer? {
    // getLengthPrefixedSliceと同じロジックをコピー
    guard let length = getInteger(at: index, as: T.self) else {
        return nil
    }
    let dataStartIndex = index + MemoryLayout<T>.size
    // 同一ロジックが複数箇所に存在（メンテナンス性低下）
}
```

### 9.3 ビルド設定ファイルの同期

ソースファイルの変更時は、ビルド設定も同時に更新する。

**チェックリスト:**
- ソースファイル追加/削除時は`CMakeLists.txt`を更新
- Xcodeプロジェクト使用時は`.xcodeproj`も更新
- テストファイル追加時はテストターゲットに追加

**正しいPRの例:**
```
Files changed:
- Sources/MyModule/NewFile.swift (追加)
- Sources/MyModule/CMakeLists.txt (NewFile.swiftを追加)
- MyProject.xcodeproj/project.pbxproj (NewFile.swiftを追加)
```

### 9.4 制御フロー

**正しい実装:**
```swift
// guardで早期リターン
func process(_ value: String?) -> Int {
    guard let value = value else {
        return 0
    }
    guard value.count > 0 else {
        return 0
    }
    return value.count
}

// ifでシンプルな条件
func calculate(_ x: Int) -> Int {
    if x > 0 {
        return x * 2
    }
    return 0
}
```

**避けるべき実装:**
```swift
// 不要なネスト
func process(_ value: String?) -> Int {
    if let value = value {
        if value.count > 0 {
            return value.count
        }
    }
    return 0
}
```

### 9.3 Force Unwrapの回避

テスト以外ではforce unwrapを避け、optional bindingを使用する。

**正しい実装:**
```swift
if let value = optionalValue {
    process(value)
}

guard let value = optionalValue else {
    return
}
process(value)

let value = optionalValue ?? defaultValue
```

**避けるべき実装:**
```swift
// 本番コードでのforce unwrap
let value = optionalValue!
doSomething(value)
```

### 9.4 依存関係の最小化

必要最小限の依存関係のみをインポートする。

**正しい実装:**
```swift
#if canImport(Foundation)
import struct Foundation.Date
import struct Foundation.UUID
#endif

#if canImport(Foundation)
import Foundation
#else
// Foundation.Essentials等の代替
#endif
```

**避けるべき実装:**
```swift
import Foundation // Dateしか使っていない
import UIKit      // まったく使っていない
```

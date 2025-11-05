import FDBRecordLayer

// MARK: - Models with Nested Fields

@Recordable
struct Address {
    @PrimaryKey var id: Int64
    var street: String
    var city: String
    var zipCode: String
    var country: String
}

@Recordable
struct Person {
    // ネストフィールドインデックスの例
    #Index<Person>([\\.address.city])              // 都市でインデックス
    #Index<Person>([\\.address.country, \\.age])   // 国と年齢の複合インデックス
    #Unique<Person>([\\.email])                    // メール一意制約
    #Unique<Person>([\\.address.zipCode])          // 郵便番号一意制約（ネスト）

    @PrimaryKey var personID: Int64
    var name: String
    var email: String
    var age: Int32
    var address: Address                           // ネストした型
}

@Recordable
struct Company {
    #Index<Company>([\\.headquarters.city])        // 本社所在地でインデックス
    #Index<Company>([\\.headquarters.country, \\.name])  // 国と名前の複合

    @PrimaryKey var companyID: Int64
    var name: String
    var headquarters: Address                      // 本社住所
    var branchOffices: [Address]                   // 支社リスト（配列）
}

@Recordable
struct Employee {
    #Index<Employee>([\\.person.address.city])     // 多段ネスト：従業員の住所の都市
    #Index<Employee>([\\.person.age, \\.department])  // 年齢と部署の複合

    @PrimaryKey var employeeID: Int64
    var person: Person                             // ネストしたPerson
    var department: String
    var salary: Int64
}

// MARK: - Usage Examples

func exampleUsage() throws {
    print("=== Nested Field Index Example ===\n")

    // 1. Person with nested Address
    let address = Address(
        id: 1,
        street: "123 Market St",
        city: "San Francisco",
        zipCode: "94103",
        country: "USA"
    )

    let person = Person(
        personID: 100,
        name: "Alice Johnson",
        email: "alice@example.com",
        age: 30,
        address: address
    )

    // 2. extractField でネストパス取得
    print("Testing extractField with nested paths:")

    // 単一フィールド
    let nameField = person.extractField("name")
    print("  person.name: \(nameField)")  // ["Alice Johnson"]

    // ネストしたフィールド
    let cityField = person.extractField("address.city")
    print("  person.address.city: \(cityField)")  // ["San Francisco"]

    let countryField = person.extractField("address.country")
    print("  person.address.country: \(countryField)")  // ["USA"]

    let zipCodeField = person.extractField("address.zipCode")
    print("  person.address.zipCode: \(zipCodeField)")  // ["94103"]

    print()

    // 3. Index定義の確認
    print("Index Definitions:")

    // Person_address_city_index
    // fields: ["address.city"]
    print("  Index on Person.address.city:")
    print("    - Allows queries like: 'Find all people in San Francisco'")

    // Person_address_country_age_index
    // fields: ["address.country", "age"]
    print("  Composite index on Person.address.country + age:")
    print("    - Allows queries like: 'Find people in USA aged 30'")

    // Person_address_zipCode_unique
    // fields: ["address.zipCode"], unique: true
    print("  Unique constraint on Person.address.zipCode:")
    print("    - Ensures no two people have the same zip code")

    print()

    // 4. Serialization/Deserialization
    print("Testing serialization with nested fields:")
    let data = try person.toProtobuf()
    print("  Serialized size: \(data.count) bytes")

    let decoded = try Person.fromProtobuf(data)
    print("  Decoded successfully:")
    print("    - Name: \(decoded.name)")
    print("    - Address.city: \(decoded.address.city)")
    print("    - Address.zipCode: \(decoded.address.zipCode)")

    print()

    // 5. Multi-level nesting
    let employee = Employee(
        employeeID: 1,
        person: person,  // Person contains Address
        department: "Engineering",
        salary: 120000
    )

    print("Testing multi-level nested paths:")
    let employeeCityField = employee.extractField("person.address.city")
    print("  employee.person.address.city: \(employeeCityField)")  // ["San Francisco"]

    print()

    // 6. Optional nested fields
    @Recordable
    struct Contact {
        @PrimaryKey var contactID: Int64
        var name: String
        var workAddress: Address?  // Optional nested type
    }

    let contactWithAddress = Contact(
        contactID: 1,
        name: "Bob Smith",
        workAddress: address
    )

    let contactWithoutAddress = Contact(
        contactID: 2,
        name: "Charlie Brown",
        workAddress: nil
    )

    print("Testing optional nested fields:")
    let workCityWith = contactWithAddress.extractField("workAddress.city")
    print("  contactWithAddress.workAddress.city: \(workCityWith)")  // ["San Francisco"]

    let workCityWithout = contactWithoutAddress.extractField("workAddress.city")
    print("  contactWithoutAddress.workAddress.city: \(workCityWithout)")  // []

    print("\n=== All tests completed successfully! ===")
}

// MARK: - Benefits Summary

/*

 ✅ ネストフィールドインデックスの利点:

 1. **型安全なクエリ**
    - KeyPath連鎖: \Person.address.city
    - コンパイル時に型チェック
    - 自動補完サポート

 2. **効率的なクエリ**
    - ネストしたフィールドで直接検索
    - 例: "San Francisco在住のユーザーを検索"
    - FoundationDBインデックスを活用

 3. **柔軟なデータモデル**
    - 正規化と非正規化のバランス
    - 必要に応じてネスト or ID参照
    - 使用ケースに最適な設計

 4. **保守性向上**
    - フィールド名変更時にコンパイルエラー
    - リファクタリング安全
    - IDE支援

 使用例:

 ```swift
 // ネストフィールドインデックスを使ったクエリ（RecordStoreで）
 let sfPeople = try recordStore.query(
     recordType: Person.self,
     indexName: "Person_address_city_index",
     value: "San Francisco"
 )

 // 複合インデックス
 let usaAge30 = try recordStore.query(
     recordType: Person.self,
     indexName: "Person_address_country_age_index",
     values: ["USA", 30]
 )
 ```

 */

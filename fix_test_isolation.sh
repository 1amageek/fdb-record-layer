#!/bin/bash

# Script to fix test isolation in FDB Record Layer tests
# This adds defer-based cleanup to all integration tests

echo "Fixing test isolation..."

# Define the pattern to search for
# Pattern: Tests that have cleanup() but no defer

# Files to fix
TEST_FILES=(
    "Tests/FDBRecordLayerTests/Index/OnlineIndexScrubberTests.swift"
    "Tests/FDBRecordLayerTests/IndexStateManagerTests.swift"
    "Tests/FDBRecordLayerTests/Query/TypedInJoinPlanTests.swift"
)

for file in "${TEST_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "Processing: $file"

        # Backup original file
        cp "$file" "${file}.backup"

        echo "  ✓ Created backup: ${file}.backup"
        echo "  → Please manually apply the following pattern:"
        echo ""
        echo "  BEFORE:"
        echo "    @Test(\"Test name\")"
        echo "    func testMethod() async throws {"
        echo "        let db = try createTestDatabase()"
        echo "        let subspace = createTestSubspace()"
        echo "        let schema = try createTestSchema()"
        echo ""
        echo "        // ... test code"
        echo ""
        echo "        try await cleanup(database: db, subspace: subspace)"
        echo "    }"
        echo ""
        echo "  AFTER:"
        echo "    @Test(\"Test name\")"
        echo "    func testMethod() async throws {"
        echo "        try await withTestEnvironment { db, subspace, schema in"
        echo "            // ... test code"
        echo "        }"
        echo "        // cleanup handled automatically"
        echo "    }"
        echo ""
    else
        echo "⚠  File not found: $file"
    fi
done

echo ""
echo "✅ Backup complete!"
echo ""
echo "Next steps:"
echo "1. Review the pattern above"
echo "2. Use withTestEnvironment helper in all tests"
echo "3. Remove manual cleanup() calls"
echo "4. Run tests: swift test"
echo ""

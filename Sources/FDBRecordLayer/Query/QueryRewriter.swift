import Foundation

/// Query rewriter for optimization
///
/// Transforms queries into more efficient equivalent forms while preventing
/// exponential explosion of terms. Applies various rewriting rules:
/// - Push NOT down (De Morgan's laws)
/// - Convert to DNF (with bounds checking)
/// - Flatten nested AND/OR
/// - Remove redundant conditions
public struct QueryRewriter<Record: Sendable> {

    /// Configuration for rewriting bounds
    public struct Config: Sendable {
        /// Maximum number of terms after DNF conversion
        public let maxDNFTerms: Int

        /// Maximum depth of expression tree
        public let maxDepth: Int

        /// Enable DNF conversion
        public let enableDNF: Bool

        public init(maxDNFTerms: Int, maxDepth: Int, enableDNF: Bool = true) {
            self.maxDNFTerms = maxDNFTerms
            self.maxDepth = maxDepth
            self.enableDNF = enableDNF
        }
    }

    private let config: Config

    public init(config: Config = .default) {
        self.config = config
    }

    // MARK: - Public API

    /// Apply all rewrite rules to a filter
    public func rewrite(
        _ filter: any TypedQueryComponent<Record>
    ) -> any TypedQueryComponent<Record> {
        var rewritten = filter

        // Rule 1: Push NOT down (always safe)
        rewritten = pushNotDown(rewritten)

        // Rule 2: Flatten nested AND/OR (always safe)
        rewritten = flattenBooleans(rewritten)

        // Rule 3: Remove redundant conditions (always safe)
        rewritten = removeRedundant(rewritten)

        // Rule 4: Convert to DNF (ONLY if safe and enabled)
        if config.enableDNF && shouldConvertToDNF(rewritten) {
            rewritten = convertToDNF(rewritten, currentTerms: 0)
        }

        // Rule 5: Flatten again after DNF
        rewritten = flattenBooleans(rewritten)

        return rewritten
    }

    // MARK: - Rule 1: Push NOT Down

    /// Apply De Morgan's laws to push NOT operators down
    private func pushNotDown(
        _ filter: any TypedQueryComponent<Record>
    ) -> any TypedQueryComponent<Record> {
        if let notFilter = filter as? TypedNotQueryComponent<Record> {
            let inner = notFilter.child

            if let andFilter = inner as? TypedAndQueryComponent<Record> {
                // NOT (A AND B) → (NOT A) OR (NOT B)
                let negatedChildren = andFilter.children.map { child in
                    pushNotDown(TypedNotQueryComponent(child: child))
                }
                return TypedOrQueryComponent(children: negatedChildren)
            } else if let orFilter = inner as? TypedOrQueryComponent<Record> {
                // NOT (A OR B) → (NOT A) AND (NOT B)
                let negatedChildren = orFilter.children.map { child in
                    pushNotDown(TypedNotQueryComponent(child: child))
                }
                return TypedAndQueryComponent(children: negatedChildren)
            } else if let doubleNot = inner as? TypedNotQueryComponent<Record> {
                // NOT (NOT A) → A
                return pushNotDown(doubleNot.child)
            }
        } else if let andFilter = filter as? TypedAndQueryComponent<Record> {
            // Recursively apply to children
            let rewrittenChildren = andFilter.children.map { pushNotDown($0) }
            return TypedAndQueryComponent(children: rewrittenChildren)
        } else if let orFilter = filter as? TypedOrQueryComponent<Record> {
            // Recursively apply to children
            let rewrittenChildren = orFilter.children.map { pushNotDown($0) }
            return TypedOrQueryComponent(children: rewrittenChildren)
        }

        return filter
    }

    // MARK: - Rule 2: Convert to DNF

    /// Check if DNF conversion is safe
    private func shouldConvertToDNF(
        _ filter: any TypedQueryComponent<Record>
    ) -> Bool {
        let estimatedTerms = estimateDNFTermCount(filter)
        return estimatedTerms <= config.maxDNFTerms
    }

    /// Estimate number of terms after DNF conversion
    private func estimateDNFTermCount(
        _ filter: any TypedQueryComponent<Record>
    ) -> Int {
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            // AND: terms multiply
            return andFilter.children.reduce(1) { result, child in
                result * estimateDNFTermCount(child)
            }
        } else if let orFilter = filter as? TypedOrQueryComponent<Record> {
            // OR: terms add
            return orFilter.children.reduce(0) { result, child in
                result + estimateDNFTermCount(child)
            }
        } else if let notFilter = filter as? TypedNotQueryComponent<Record> {
            return estimateDNFTermCount(notFilter.child)
        } else {
            // Leaf node
            return 1
        }
    }

    /// Convert to DNF with bounds checking
    private func convertToDNF(
        _ filter: any TypedQueryComponent<Record>,
        currentTerms: Int
    ) -> any TypedQueryComponent<Record> {
        // Stop if exceeded limit
        guard currentTerms <= config.maxDNFTerms else {
            return filter
        }

        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            // Check if any child is an OR
            for (index, child) in andFilter.children.enumerated() {
                if let orChild = child as? TypedOrQueryComponent<Record> {
                    // Estimate expansion
                    let newTermCount = currentTerms + (orChild.children.count - 1) * andFilter.children.count

                    // Only expand if under limit
                    guard newTermCount <= config.maxDNFTerms else {
                        return filter
                    }

                    // Distribute: A AND (B OR C) → (A AND B) OR (A AND C)
                    var otherChildren = andFilter.children
                    otherChildren.remove(at: index)

                    let distributed = orChild.children.map { orTerm in
                        var newAnd = otherChildren
                        newAnd.append(orTerm)
                        return convertToDNF(
                            TypedAndQueryComponent(children: newAnd),
                            currentTerms: newTermCount
                        )
                    }

                    return TypedOrQueryComponent(children: distributed)
                }
            }

            // Recursively apply to children if no OR found
            let rewrittenChildren = andFilter.children.map {
                convertToDNF($0, currentTerms: currentTerms)
            }
            return TypedAndQueryComponent(children: rewrittenChildren)
        } else if let orFilter = filter as? TypedOrQueryComponent<Record> {
            // Recursively apply to children
            let rewrittenChildren = orFilter.children.map {
                convertToDNF($0, currentTerms: currentTerms)
            }
            return TypedOrQueryComponent(children: rewrittenChildren)
        }

        return filter
    }

    // MARK: - Rule 3: Flatten Booleans

    /// Flatten nested AND/OR expressions
    private func flattenBooleans(
        _ filter: any TypedQueryComponent<Record>
    ) -> any TypedQueryComponent<Record> {
        if let orFilter = filter as? TypedOrQueryComponent<Record> {
            var flattened: [any TypedQueryComponent<Record>] = []

            for child in orFilter.children {
                let flatChild = flattenBooleans(child)
                if let nestedOr = flatChild as? TypedOrQueryComponent<Record> {
                    // Flatten: (A OR B) OR C → A OR B OR C
                    flattened.append(contentsOf: nestedOr.children)
                } else {
                    flattened.append(flatChild)
                }
            }

            return flattened.count == 1 ? flattened[0] : TypedOrQueryComponent(children: flattened)
        } else if let andFilter = filter as? TypedAndQueryComponent<Record> {
            var flattened: [any TypedQueryComponent<Record>] = []

            for child in andFilter.children {
                let flatChild = flattenBooleans(child)
                if let nestedAnd = flatChild as? TypedAndQueryComponent<Record> {
                    // Flatten: (A AND B) AND C → A AND B AND C
                    flattened.append(contentsOf: nestedAnd.children)
                } else {
                    flattened.append(flatChild)
                }
            }

            return flattened.count == 1 ? flattened[0] : TypedAndQueryComponent(children: flattened)
        } else if let notFilter = filter as? TypedNotQueryComponent<Record> {
            return TypedNotQueryComponent(child: flattenBooleans(notFilter.child))
        }

        return filter
    }

    // MARK: - Rule 4: Remove Redundant

    /// Remove duplicate conditions
    private func removeRedundant(
        _ filter: any TypedQueryComponent<Record>
    ) -> any TypedQueryComponent<Record> {
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            // Remove duplicates in AND
            let unique = removeDuplicates(andFilter.children.map { removeRedundant($0) })
            return unique.count == 1 ? unique[0] : TypedAndQueryComponent(children: unique)
        } else if let orFilter = filter as? TypedOrQueryComponent<Record> {
            // Remove duplicates in OR
            let unique = removeDuplicates(orFilter.children.map { removeRedundant($0) })
            return unique.count == 1 ? unique[0] : TypedOrQueryComponent(children: unique)
        }

        return filter
    }

    /// Remove duplicate filters
    private func removeDuplicates(
        _ filters: [any TypedQueryComponent<Record>]
    ) -> [any TypedQueryComponent<Record>] {
        var seen: Set<String> = []
        var unique: [any TypedQueryComponent<Record>] = []

        for filter in filters {
            let key = describeFilter(filter)
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(filter)
            }
        }

        return unique
    }

    /// Generate stable description of filter for deduplication
    private func describeFilter(_ filter: any TypedQueryComponent<Record>) -> String {
        if let fieldFilter = filter as? TypedFieldQueryComponent<Record> {
            return "field:\(fieldFilter.fieldName):\(fieldFilter.comparison):\(String(describing: fieldFilter.value))"
        } else if let andFilter = filter as? TypedAndQueryComponent<Record> {
            let childKeys = andFilter.children.map { describeFilter($0) }.sorted().joined(separator: ",")
            return "and:[\(childKeys)]"
        } else if let orFilter = filter as? TypedOrQueryComponent<Record> {
            let childKeys = orFilter.children.map { describeFilter($0) }.sorted().joined(separator: ",")
            return "or:[\(childKeys)]"
        } else if let notFilter = filter as? TypedNotQueryComponent<Record> {
            return "not:\(describeFilter(notFilter.child))"
        } else {
            return "unknown"
        }
    }

    // MARK: - Utility

    /// Count depth of expression tree
    public func measureDepth(_ filter: any TypedQueryComponent<Record>) -> Int {
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            let maxChildDepth = andFilter.children.map { measureDepth($0) }.max() ?? 0
            return 1 + maxChildDepth
        } else if let orFilter = filter as? TypedOrQueryComponent<Record> {
            let maxChildDepth = orFilter.children.map { measureDepth($0) }.max() ?? 0
            return 1 + maxChildDepth
        } else if let notFilter = filter as? TypedNotQueryComponent<Record> {
            return 1 + measureDepth(notFilter.child)
        } else {
            return 1
        }
    }

    /// Count total number of terms
    public func countTerms(_ filter: any TypedQueryComponent<Record>) -> Int {
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            return andFilter.children.reduce(0) { $0 + countTerms($1) }
        } else if let orFilter = filter as? TypedOrQueryComponent<Record> {
            return orFilter.children.reduce(0) { $0 + countTerms($1) }
        } else if let notFilter = filter as? TypedNotQueryComponent<Record> {
            return countTerms(notFilter.child)
        } else {
            return 1
        }
    }
}

// MARK: - Config Extensions

extension QueryRewriter.Config {
    public static var `default`: QueryRewriter.Config {
        QueryRewriter.Config(
            maxDNFTerms: 100,
            maxDepth: 20,
            enableDNF: true
        )
    }

    public static var conservative: QueryRewriter.Config {
        QueryRewriter.Config(
            maxDNFTerms: 20,
            maxDepth: 10,
            enableDNF: true
        )
    }

    public static var aggressive: QueryRewriter.Config {
        QueryRewriter.Config(
            maxDNFTerms: 500,
            maxDepth: 50,
            enableDNF: true
        )
    }

    public static var noDNF: QueryRewriter.Config {
        QueryRewriter.Config(
            maxDNFTerms: 0,
            maxDepth: 20,
            enableDNF: false
        )
    }
}

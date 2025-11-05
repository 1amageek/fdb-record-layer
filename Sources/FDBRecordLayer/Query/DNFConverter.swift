import Foundation

/// Converts query filters to Disjunctive Normal Form (DNF)
///
/// DNF is a normalized form: (A AND B) OR (C AND D) OR ...
/// Each OR branch can be optimized separately with index intersection.
///
/// **Example:**
/// ```
/// Input:  (city = "Tokyo" OR city = "Osaka") AND age > 18
/// DNF:    (city = "Tokyo" AND age > 18) OR (city = "Osaka" AND age > 18)
/// ```
///
/// **Algorithm:**
/// 1. Push NOT down to leaves (De Morgan's laws)
/// 2. Distribute AND over OR (Distributive law)
/// 3. Control explosion with max branch limit
///
/// **Explosion Control:**
/// - Limit number of OR branches (default: 10 from PlanGenerationConfig)
/// - If limit exceeded, fall back to original filter
///
/// **Usage:**
/// ```swift
/// let converter = DNFConverter(maxBranches: 10)
/// let dnf = try converter.convertToDNF(filter)
/// // dnf is TypedOrQueryComponent<Record> with AND children
/// ```
public struct DNFConverter<Record: Sendable> {
    // MARK: - Properties

    /// Maximum number of OR branches allowed
    private let maxBranches: Int

    // MARK: - Initialization

    public init(maxBranches: Int = 10) {
        self.maxBranches = maxBranches
    }

    // MARK: - Public API

    /// Convert filter to DNF
    ///
    /// - Parameter filter: The filter to convert
    /// - Returns: DNF form (OR of ANDs), or original if conversion would explode
    /// - Throws: RecordLayerError if conversion fails
    public func convertToDNF(
        _ filter: any TypedQueryComponent<Record>
    ) throws -> any TypedQueryComponent<Record> {
        // Step 1: Push NOT down to leaves
        let normalized = pushNotDown(filter)

        // Step 2: Convert to DNF
        let dnf = toDNF(normalized)

        // Step 3: Check explosion
        let branchCount = countORBranches(dnf)
        if branchCount > maxBranches {
            // Explosion detected: return original filter
            return filter
        }

        return dnf
    }

    // MARK: - Step 1: Push NOT Down

    /// Push NOT operators down to leaves using De Morgan's laws
    ///
    /// De Morgan's laws:
    /// - NOT (A AND B) = (NOT A) OR (NOT B)
    /// - NOT (A OR B) = (NOT A) AND (NOT B)
    /// - NOT (NOT A) = A
    private func pushNotDown(
        _ filter: any TypedQueryComponent<Record>
    ) -> any TypedQueryComponent<Record> {
        // NOT component: apply De Morgan's laws
        if let notFilter = filter as? TypedNotQueryComponent<Record> {
            let child = notFilter.child

            // NOT (NOT A) = A
            if let innerNot = child as? TypedNotQueryComponent<Record> {
                return pushNotDown(innerNot.child)
            }

            // NOT (A AND B) = (NOT A) OR (NOT B)
            if let andFilter = child as? TypedAndQueryComponent<Record> {
                let negatedChildren = andFilter.children.map { child in
                    pushNotDown(TypedNotQueryComponent(child: child))
                }
                return TypedOrQueryComponent(children: negatedChildren)
            }

            // NOT (A OR B) = (NOT A) AND (NOT B)
            if let orFilter = child as? TypedOrQueryComponent<Record> {
                let negatedChildren = orFilter.children.map { child in
                    pushNotDown(TypedNotQueryComponent(child: child))
                }
                return TypedAndQueryComponent(children: negatedChildren)
            }

            // NOT (field comparison): leave as is (handled at leaf level)
            if child is TypedFieldQueryComponent<Record> {
                return notFilter
            }

            return notFilter
        }

        // AND component: recursively push down in children
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            let normalizedChildren = andFilter.children.map { pushNotDown($0) }
            return TypedAndQueryComponent(children: normalizedChildren)
        }

        // OR component: recursively push down in children
        if let orFilter = filter as? TypedOrQueryComponent<Record> {
            let normalizedChildren = orFilter.children.map { pushNotDown($0) }
            return TypedOrQueryComponent(children: normalizedChildren)
        }

        // Leaf node (field comparison): no transformation needed
        return filter
    }

    // MARK: - Step 2: Convert to DNF

    /// Convert normalized filter to DNF
    ///
    /// Uses distributive law: A AND (B OR C) = (A AND B) OR (A AND C)
    private func toDNF(
        _ filter: any TypedQueryComponent<Record>
    ) -> any TypedQueryComponent<Record> {
        // OR: already in DNF form (top level), recurse on children
        if let orFilter = filter as? TypedOrQueryComponent<Record> {
            let dnfChildren = orFilter.children.map { toDNF($0) }
            return TypedOrQueryComponent(children: dnfChildren)
        }

        // AND: distribute over OR
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            return distributeAND(andFilter.children)
        }

        // Leaf node: already in DNF
        return filter
    }

    /// Distribute AND over OR using Distributive law
    ///
    /// Example: (A OR B) AND C = (A AND C) OR (B AND C)
    private func distributeAND(
        _ children: [any TypedQueryComponent<Record>]
    ) -> any TypedQueryComponent<Record> {
        guard !children.isEmpty else {
            // Empty AND: return trivial true filter (should not happen)
            fatalError("Empty AND filter")
        }

        // Start with first child
        var result = toDNF(children[0])

        // Distribute remaining children
        for child in children.dropFirst() {
            let childDNF = toDNF(child)
            result = distributeTwo(result, childDNF)
        }

        return result
    }

    /// Distribute two DNF expressions: (A OR B) AND (C OR D)
    ///
    /// Result: (A AND C) OR (A AND D) OR (B AND C) OR (B AND D)
    private func distributeTwo(
        _ lhs: any TypedQueryComponent<Record>,
        _ rhs: any TypedQueryComponent<Record>
    ) -> any TypedQueryComponent<Record> {
        // Extract OR branches from both sides
        let lhsBranches: [any TypedQueryComponent<Record>]
        if let lhsOr = lhs as? TypedOrQueryComponent<Record> {
            lhsBranches = lhsOr.children
        } else {
            lhsBranches = [lhs]
        }

        let rhsBranches: [any TypedQueryComponent<Record>]
        if let rhsOr = rhs as? TypedOrQueryComponent<Record> {
            rhsBranches = rhsOr.children
        } else {
            rhsBranches = [rhs]
        }

        // Compute cross product: (A OR B) AND (C OR D) = (A AND C) OR (A AND D) OR (B AND C) OR (B AND D)
        var orBranches: [any TypedQueryComponent<Record>] = []

        for lhsBranch in lhsBranches {
            for rhsBranch in rhsBranches {
                // Combine lhsBranch AND rhsBranch
                let combined = combineAND(lhsBranch, rhsBranch)
                orBranches.append(combined)
            }
        }

        // Return OR of all branches
        if orBranches.count == 1 {
            return orBranches[0]
        } else {
            return TypedOrQueryComponent(children: orBranches)
        }
    }

    /// Combine two filters with AND
    private func combineAND(
        _ lhs: any TypedQueryComponent<Record>,
        _ rhs: any TypedQueryComponent<Record>
    ) -> any TypedQueryComponent<Record> {
        // Extract AND children from both sides
        var andChildren: [any TypedQueryComponent<Record>] = []

        if let lhsAnd = lhs as? TypedAndQueryComponent<Record> {
            andChildren.append(contentsOf: lhsAnd.children)
        } else {
            andChildren.append(lhs)
        }

        if let rhsAnd = rhs as? TypedAndQueryComponent<Record> {
            andChildren.append(contentsOf: rhsAnd.children)
        } else {
            andChildren.append(rhs)
        }

        // Flatten AND
        if andChildren.count == 1 {
            return andChildren[0]
        } else {
            return TypedAndQueryComponent(children: andChildren)
        }
    }

    // MARK: - Step 3: Explosion Control

    /// Count number of OR branches in DNF
    private func countORBranches(
        _ filter: any TypedQueryComponent<Record>
    ) -> Int {
        if let orFilter = filter as? TypedOrQueryComponent<Record> {
            return orFilter.children.count
        } else {
            return 1 // Single branch (no OR at top level)
        }
    }
}

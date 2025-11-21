// ExampleConfig.swift
// Centralized configuration for all examples with environment variable support

import Foundation

/// Configuration for FoundationDB examples
/// Supports environment variables for cluster configuration
public struct ExampleConfig {
    /// Cluster file path
    /// Override with FDB_CLUSTER_FILE environment variable
    public let clusterFilePath: String?

    /// API version
    /// Override with FDB_API_VERSION environment variable
    public let apiVersion: Int

    /// Whether to clean up data after example runs
    /// Override with EXAMPLE_CLEANUP=true/false
    public let cleanup: Bool

    /// Unique run ID for data isolation
    /// Override with EXAMPLE_RUN_ID environment variable
    public let runID: String

    /// Default configuration
    public static let `default` = ExampleConfig()

    public init(
        clusterFilePath: String? = nil,
        apiVersion: Int = 710,
        cleanup: Bool = true,
        runID: String? = nil
    ) {
        let env = ProcessInfo.processInfo.environment

        // Cluster file: FDB_CLUSTER_FILE env var > parameter > nil (default)
        if let envCluster = env["FDB_CLUSTER_FILE"] {
            self.clusterFilePath = envCluster
        } else {
            self.clusterFilePath = clusterFilePath
        }

        // API version: FDB_API_VERSION env var > parameter > 710
        if let envVersion = env["FDB_API_VERSION"], let version = Int(envVersion) {
            self.apiVersion = version
        } else {
            self.apiVersion = apiVersion
        }

        // Cleanup: EXAMPLE_CLEANUP env var > parameter > true
        if let envCleanup = env["EXAMPLE_CLEANUP"] {
            self.cleanup = envCleanup.lowercased() == "true"
        } else {
            self.cleanup = cleanup
        }

        // Run ID: EXAMPLE_RUN_ID env var > parameter > UUID
        if let envRunID = env["EXAMPLE_RUN_ID"] {
            self.runID = envRunID
        } else {
            self.runID = runID ?? UUID().uuidString
        }
    }

    /// Print configuration for debugging
    public func printConfig() {
        print("📋 Example Configuration:")
        print("   Cluster file: \(clusterFilePath ?? "default")")
        print("   API version: \(apiVersion)")
        print("   Cleanup after run: \(cleanup)")
        print("   Run ID: \(runID)")
        print()
    }
}

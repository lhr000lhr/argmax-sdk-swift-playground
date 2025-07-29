import Foundation
#if canImport(ArgmaxSecrets)
import ArgmaxSecrets
#endif


/// A no-operation implementation of `AnalyticsLogger` that provides empty functionality.
///
/// `NoOpAnalyticsLogger` serves as a null object pattern implementation for scenarios
/// where analytics logging should be disabled or unavailable. All methods perform
/// no operations, making it safe to use as a fallback or default implementation.
///
/// This class is particularly useful for testing environments, debug builds where
/// analytics should be disabled, or as a placeholder during development.
class NoOpAnalyticsLogger: AnalyticsLogger {
    func logEvent(_ name: String, parameters: [String: Any]?) {}
    func configureIfNeeded() {}
}

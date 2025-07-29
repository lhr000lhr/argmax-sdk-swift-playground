import Foundation
import Argmax

#if !canImport(ArgmaxSecrets)
/// A protocol defining the interface for initializing the Playground application's environment components.
///
/// `PlaygroundEnvInitializer` provides a unified interface for setting up the core environment
/// dependencies required by the Playground application, including API key providers for SDK
/// authentication and analytics loggers for usage tracking and monitoring.
///
/// This protocol enables different deployment configurations (development, production, public)
/// to provide their own implementations while maintaining a consistent initialization interface
/// throughout the application.
///
/// ## Core Responsibilities
///
/// - **API Key Management**: Creates and configures `APIKeyProvider` instances for authenticating with external services
/// - **Analytics Setup**: Initializes appropriate `AnalyticsLogger` implementations based on deployment context  
/// - **Environment Configuration**: Handles any additional environment-specific setup requirements
///
/// ## Usage Example
///
/// ```swift
/// let envInitializer: PlaygroundEnvInitializer = ArgmaxEnvInitializer()
/// let apiKeyProvider = envInitializer.createAPIKeyProvider()
/// let analyticsLogger = envInitializer.createAnalyticsLogger()
/// 
/// // Use in app initialization
/// let coordinator = ArgmaxSDKCoordinator(keyProvider: apiKeyProvider)
/// ```
///
/// ## Implementation Notes
///
/// Implementations should be lightweight and avoid heavy initialization work in the creation methods.
/// The actual configuration and setup should be deferred until the components are actively used.
public protocol PlaygroundEnvInitializer {
    
    /// Creates an API key provider configured for the current environment.
    ///
    /// The returned provider should be ready to supply API keys for various services
    /// including WhisperKit, HuggingFace, and other external APIs used by the application.
    ///
    /// - Returns: A configured `APIKeyProvider` instance
    func createAPIKeyProvider() -> APIKeyProvider
    
    /// Creates an analytics logger appropriate for the current environment.
    ///
    /// The returned logger should be configured to handle event logging and analytics
    /// tracking according to the deployment context (e.g., Firebase for production,
    /// no-op for development).
    ///
    /// - Returns: A configured `AnalyticsLogger` instance
    func createAnalyticsLogger() -> AnalyticsLogger
}

/// A protocol defining the interface for analytics logging functionality.
///
/// `AnalyticsLogger` provides a common interface for logging events and parameters
/// to various analytics services. Implementations can support different analytics
/// providers while maintaining a consistent API for the application.
///
/// The protocol supports both event logging with optional parameters and
/// configuration setup through the lifecycle methods.
///
/// ## Usage Example
///
/// ```swift
/// let logger: AnalyticsLogger = NoOpAnalyticsLogger()
/// logger.configureIfNeeded()
/// logger.logEvent("user_action", parameters: ["action_type": "button_tap"])
/// ```
public protocol AnalyticsLogger {
    func logEvent(_ name: String, parameters: [String: Any]?)
    func configureIfNeeded()
}

#endif

import Argmax
import CoreML
import Foundation
import Combine

/// A central `ObservableObject` that manages all Argmax SDK components including model loading,
/// transcription, and speaker diarization.
///
/// `ArgmaxSDKCoordinator` acts as the main integration point for apps using WhisperKit, SpeakerKit, 
/// LiveTranscriber, and ModelStore. It simplifies the orchestration of the Argmax transcription pipeline 
/// and provides a unified interface for SwiftUI applications to observe and control model workflows.
///
/// ## Core Responsibilities
///
/// - **Model Management:** Coordinates loading, downloading, and updating transcription models using `ModelStore`
/// - **Component Lifecycle:** Instantiates and wires up `WhisperKitPro`, `SpeakerKitPro`, and `LiveTranscriber` with correct configuration and state tracking
/// - **API Key Handling:** Retrieves and validates obfuscated API keys required to access Argmax services
/// - **State Propagation:** Uses `@Published` properties to notify SwiftUI views about model loading state and service availability
///
/// ## Key Methods
///
/// - ``setupArgmax()``: Sets up the Argmax SDK with proper configuration and error handling
/// - ``prepare(modelName:repository:config:redownload:)``: Downloads and initializes models for WhisperKit and SpeakerKit
/// - ``updateModelList()``: Refreshes available models from configured repositories
/// - ``reset()``: Unloads all models and resets the coordinator state
///
/// ## Related SDK Objects
///
/// - **WhisperKit:** Core transcription engine that consumes raw audio and outputs segmented, timestamped text (used as `WhisperKitPro` for advanced streaming support)
/// - **SpeakerKit:** Diarization engine that distinguishes speakers in audio, loaded alongside WhisperKit when needed for multi-speaker transcripts
/// - **LiveTranscriber:** High-level component that wraps WhisperKit for real-time streaming transcription, automatically initialized when `whisperKit` is set
/// - **ModelStore:** Manages available model metadata, repositories, and downloads throughout the coordinator lifecycle
///
/// ## Usage Example
///
/// ```swift
/// let coordinator = ArgmaxSDKCoordinator()
/// coordinator.setupArgmax()
/// 
/// // Load a model
/// try await coordinator.prepare(
///     modelName: "whisper-base", 
///     config: WhisperKitProConfig()
/// )
/// 
/// // Use the transcription services
/// if let liveTranscriber = coordinator.liveTranscriber {
///     // Start real-time transcription
/// }
/// ```
public final class ArgmaxSDKCoordinator: ObservableObject {
    // MARK: - Published Properties
    @Published public private(set) var whisperKitModelState: ModelState = .unloaded
    @Published public private(set) var speakerKitModelState: ModelState = .unloaded
    @Published public var modelDownloadFailed: Bool = false
    
    // MARK: - Argmax API objects
    public private(set) var whisperKit: WhisperKitPro? {
        didSet {
            if let wk = whisperKit {
                liveTranscriber = LiveTranscriber(whisperKit: wk)
            } else {
                liveTranscriber = nil
            }
        }
    }
    public private(set) var speakerKit: SpeakerKitPro?
    
    public private(set) var liveTranscriber: LiveTranscriber?
    public let modelStore: ModelStore
    private let keyProvider: APIKeyProvider
    
    // MARK: - properties
    private var apiKey: String? = nil
    private var cancellables = Set<AnyCancellable>()
    
    public init(
        whisperKitConfig: WhisperKitProConfig = WhisperKitProConfig(),
        keyProvider: APIKeyProvider
    ) {
        // Initialize with provided key provider
        self.keyProvider = keyProvider
        // ModelStore uses WhisperKit configuration
        self.modelStore = ModelStore(whisperKitConfig: whisperKitConfig)
        
        // Manually chain the objectWillChange publisher from the modelStore
        // to this coordinator. This ensures that any @Published property(.localModels and .availableModels) change
        // in modelStore will also trigger an update for any view observing this coordinator.
        // Otherwise directly use ModelStore as a @StateObject in your SwiftUI
        modelStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
    
    /// Sets up the Argmax SDK with proper configuration and error handling
    public func setupArgmax() {
        if let apiKey = apiKey, !apiKey.isEmpty {
            return
        }
        Task {
            do {
                guard let apiKey = keyProvider.apiKey, !apiKey.isEmpty else {
                    await MainActor.run {
                        self.whisperKitModelState = .unloaded
                        self.speakerKitModelState = .unloaded
                    }
                    throw ArgmaxError.invalidLicense("Missing API Key")
                }
                
                self.apiKey = apiKey
                await ArgmaxSDK.with(ArgmaxConfig(apiKey: apiKey))
                Logging.debug("Setting up ArgmaxSDK")
                Logging.debug(await ArgmaxSDK.licenseInfo())
            } catch {
                await MainActor.run {
                    modelDownloadFailed = true
                }
                Logging.error("Failed to set up ArgmaxSDK: \(error)")
            }
        }
    }

    // MARK: - Model Management
    
    /// Updates the model list using ModelStore's functionality
    public func updateModelList() async {
        let targetRepositories: [RepoType]
        
        if #available(macOS 15, iOS 18, watchOS 11, visionOS 2, *) {
            // iOS18+/macOS15+: Use Pro repositories only
            targetRepositories = [.parakeetRepo, .proRepo]
        } else {
            // iOS17/macOS14: Use parakeet pro + open source repositories
            targetRepositories = [.parakeetRepo, .openSourceRepo]
        }
        
        await modelStore.updateAvailableModels(from: targetRepositories, keyProvider: keyProvider)
    }

    /// Downloads the CoreML bundle (if needed) and instantiates both WhisperKit and SpeakerKit.
    /// Call this once per model you want to use; subsequent calls replace the services.
    @MainActor
    public func prepare(modelName: String,
                        repository: String? = nil,
                        config: WhisperKitProConfig,
                        redownload: Bool = false) async throws {
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            self.whisperKitModelState = .unloaded
            self.speakerKitModelState = .unloaded
            throw ArgmaxError.invalidLicense("Missing API Key")
        }
        do {
            // --- First prepare WhisperKit
            // Determine repository to use
            let selectedRepository: String
            if let repository {
                selectedRepository = repository
            } else {
                selectedRepository = await findRepositoryForModel(modelName)
            }
            
            // Check if model needs to be downloaded
            let needsDownload = redownload || !modelStore.modelExists(variant: modelName, from: selectedRepository)

            if needsDownload {
                self.whisperKitModelState = .downloading
            }

            // Download model using ModelStore
            // Note if needsDownload is false this function returns immediately
            let localURL = try await modelStore.downloadModel(
                name: modelName,
                repo: selectedRepository,
                token: keyProvider.huggingFaceToken,
                redownload: redownload
            )
            // Set manually due to lag of setting up Whisperkit for large models and getting state
            self.whisperKitModelState = .prewarming

            let whisperKitPro = try await initializeWhisperKitPro(config: config, modelFolder: localURL, modelName: modelName)
            self.whisperKit = whisperKitPro
            
            // --- Then prepare SpeakerKit
            let speakerKitPro = try await initializeSpeakerKitPro()
            self.speakerKit = speakerKitPro
            self.speakerKitModelState = speakerKitPro.modelState
            
        } catch {
            self.whisperKitModelState = .unloaded
            self.speakerKitModelState = .unloaded
            self.whisperKit = nil
            self.speakerKit = nil
            Logging.debug("Failed to prepare models:", error)
            throw error
        }
    }

    public func delete(modelName: String,
                       repository: String? = nil,
                       config: WhisperKitConfig? = nil) async throws {
        do {
            let selectedRepository: String
            if let repository {
                selectedRepository = repository
            } else {
                selectedRepository = await findRepositoryForModel(modelName)
            }
            try await modelStore.deleteModel(variant: modelName, from: selectedRepository)
        } catch {
            throw ArgmaxError.generic("Failed to delete model")
        }
    }

    public func reset() async {
        modelStore.cancelDownload()
        await whisperKit?.unloadModels()
        speakerKit?.unloadModels()
        await MainActor.run {
            whisperKit = nil
            speakerKit = nil
            whisperKitModelState = .unloaded
            speakerKitModelState = .unloaded
        }
    }
    
    // MARK: - Private Helper Methods
    
    /// Finds the appropriate repository for a given model name
    private func findRepositoryForModel(_ modelName: String) async -> String {
        let targetRepositories: [RepoType]

        if #available(macOS 15, iOS 18, watchOS 11, visionOS 2, *) {
            // iOS18+/macOS15+: Use Pro repositories only
            targetRepositories = [.parakeetRepo, .proRepo]
        } else {
            // iOS17/macOS14: Use parakeet pro + open source repositories
            targetRepositories = [.parakeetRepo, .openSourceRepo]
        }

        // First try to identify a repository that already lists this model
        if let foundRepo = modelStore.findRepository(containing: modelName, in: targetRepositories) {
            return foundRepo
        }
        
        // Fallback to naming heuristic if no match was found above
        // TODO: use built in method for parakeet
        if modelName.lowercased().contains("parakeet") {
            return RepoType.parakeetRepo.repoId
        } else {
            // For iOS18+/macOS15+, default to pro repository
            if #available(macOS 15, iOS 18, watchOS 11, visionOS 2, *) {
                return RepoType.proRepo.repoId
            } else {
                // For iOS17/macOS14, default to open source repository
                return RepoType.openSourceRepo.repoId
            }
        }
    }
    
    /// Creates a consistent model state callback for WhisperKit
    private func createWhisperKitModelStateCallback() -> ModelStateCallback {
        return { [weak self] oldState, newState in
            Task { @MainActor in
                // Map states for UI consistency
                let displayState: ModelState
                switch newState {
                case .prewarmed:
                    displayState = .loaded  // "Specialized" -> "Loaded"
                case .downloaded:
                    displayState = .prewarming  // "Downloaded" -> "Specializing" (during transcriber init)
                case .unloading:
                    displayState = .unloaded  // "Unloading" -> "Unloaded"
                case .unloaded, .loading, .loaded, .prewarming, .downloading:
                    displayState = newState  // Keep these states as-is
                }
                self?.whisperKitModelState = displayState
            }
        }
    }
    
    /// Sets up the model state callback for WhisperKitPro transcriber
    private func setupWhisperKitModelStateCallback(for transcriber: WhisperKitPro) {
        transcriber.modelStateCallback = createWhisperKitModelStateCallback()
    }
    
    /// Loads or prewarms models based on configuration
    private func prepareWhisperKitModels(for whisperKit: WhisperKit, config: WhisperKitProConfig) async throws {
        let shouldPrewarm = config.prewarm ?? false && !config.fastLoad
        if shouldPrewarm {
            try await whisperKit.prewarmModels()
        }
        try await whisperKit.loadModels()
    }

    /// Initializes and loads a WhisperKitPro transcriber
    private func initializeWhisperKitPro(config: WhisperKitProConfig, modelFolder: URL, modelName: String) async throws -> WhisperKitPro {

        config.modelFolder = modelFolder.path
        config.load = false
        let whisperKitPro = try await WhisperKitPro(config)
        // Set up model state callback and initial state
        setupWhisperKitModelStateCallback(for: whisperKitPro)
        // Load or prewarms models
        try await prepareWhisperKitModels(for: whisperKitPro, config: config)
        return whisperKitPro
    }

    /// Initializes and loads SpeakerKitPro
    private func initializeSpeakerKitPro() async throws -> SpeakerKitPro {
        var config = SpeakerKitProConfig(load: true)
        let connected = await ArgmaxSDK.isConnected()
        if !connected {
            config.download = false
            let modelBaseUrl = ModelStore().transcriberFolder(repo: "argmaxinc/speakerkit-pro")
            config.modelFolder = modelBaseUrl
        }
        let speakerKit = try await SpeakerKitPro(config)
        speakerKit.modelStateCallback = { oldState, newState in
            Task {
                await MainActor.run {
                    self.speakerKitModelState = newState
                }
            }
        }
        return speakerKit
    }
}

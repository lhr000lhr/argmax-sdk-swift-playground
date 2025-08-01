import Foundation
import SwiftUI
import ArgmaxSDK
import Argmax
import WhisperKit
import CoreAudio

/// An `ObservableObject` that manages the state and logic for real-time audio streaming and transcription.
/// This view model acts as the primary interface between the SwiftUI views and the underlying transcription services.
///
/// ## Core Responsibilities
///
/// - **State Management:** Holds `@Published` properties for transcription results, including confirmed text,
///   hypotheses, and audio energy levels. These properties are observed by SwiftUI views to drive UI updates.
///
/// - **Transcription Lifecycle:** It orchestrates the entire streaming process by interacting with the
///   `ArgmaxSDKCoordinator`. It is responsible for setting up the audio sources, which can include a primary
///   stream from a selected input device (like a microphone) and an optional secondary stream from a
///   system audio process on macOS.
///
/// ### Starting and Stopping a Stream
///
/// The key functionality of this view model is to manage the `LiveTranscriber` provided by the `ArgmaxSDKCoordinator`.
///
/// - **`startTranscribing(options:)`:** This method initiates the transcription process. It retrieves the
///   `liveTranscriber` from the `sdkCoordinator` and begins listening for audio from the currently configured
///   stream sources (such as a microphone or system audio tap). It then consumes the transcription results
///   asynchronously, updating its `@Published` properties as new hypotheses and confirmations arrive.
///
/// - **`stopTranscribing()`:** This method gracefully terminates the stream. It calls the necessary methods on
///   the `liveTranscriber` to stop the audio processing and cancel any ongoing transcription tasks, ensuring
///   that resources are properly released.
///
/// ## Dependencies
///
/// - **`ArgmaxSDKCoordinator`:** Injected via the SwiftUI environment, this provides access to the configured
///   `LiveTranscriber` instance.
///
/// - **`AudioProcessDiscoverer` / `AudioDeviceDiscoverer`:** (macOS only) These are used to determine which
///   audio sources are available for streaming.
class StreamViewModel: ObservableObject {
    // Stream Results - per-stream data for UI
    @Published var deviceResult: StreamResult?
    @Published var systemResult: StreamResult?
    
    #if os(macOS)
    let audioProcessDiscoverer: AudioProcessDiscoverer
    #endif
    let audioDeviceDiscoverer: AudioDeviceDiscoverer
    let sdkCoordinator: ArgmaxSDKCoordinator
    
    private var streamTasks: [Task<Void, Never>] = []
    
    // Currently active streaming sources, set only in startTranscribing
    private var curActiveStreamSrcs: [any StreamSourceProtocol] = []
    private var confirmedresultCallback: ((String, TranscriptionResultPro) -> Void)?
    
    // Compute active stream sources
    private func computeActiveStreamSrcs() async throws -> [any StreamSourceProtocol] {
        #if os(macOS)
        // Set up stream 1 from device
        var result: [any StreamSourceProtocol] = []
        if let selectedDeviceID = audioDeviceDiscoverer.selectedDiviceID {
            // Validate device exists and is available before creating stream
            let availableDevices = AudioProcessor.getAudioDevices()
            if availableDevices.contains(where: { $0.id == selectedDeviceID }) {
                Logging.debug("Creating device stream for valid device ID: \(selectedDeviceID)")
                let newDeviceSource = ArgmaxStreamType.device(selectedDeviceID)
                result.append(ArgmaxSource(streamType: newDeviceSource))
            } else {
                // Device is not available - this will cause format validation crash
                let deviceName = audioDeviceDiscoverer.selectedAudioInput
                Logging.error("Selected device '\(deviceName)' (ID: \(selectedDeviceID)) is not available in current audio devices")
                throw StreamingError.deviceNotAvailable(deviceName: deviceName)
            }
        }
        // Set up stream 2 from selected process(macOS only)
        if let processTapper = audioProcessDiscoverer.processTapper {
            // Validate the selected process is still running before creating stream
            let selectedProcess = audioProcessDiscoverer.selectedProcessForStream
            if selectedProcess != .noAudio {
                // Check if process is still running by updating its status
                selectedProcess.updateIsRunning()
                if selectedProcess.isRunning {
                    Logging.debug("Creating process stream for valid process: \(selectedProcess.name)")
                    // Move ProcessTapper startTapStream to background to avoid blocking main thread
                    let (tapperStream, tapperContinuation) = await Task.detached {
                        return processTapper.startTapStream()
                    }.value
                    result.append(
                        CustomSource(id: "ProcessTapper", audioStream: tapperStream, audioContinuation: tapperContinuation)
                    )
                } else {
                    // Process is no longer running
                    Logging.error("Selected process '\(selectedProcess.name)' is no longer running")
                    throw StreamingError.processNotAvailable(processName: selectedProcess.name)
                }
            }
        }
        #else
        // Set up microphone device for iOS
        var result: [any StreamSourceProtocol] = [ArgmaxSource(streamType: .device())]
        #endif
        return result
    }
    
    #if os(macOS)
    init(sdkCoordinator: ArgmaxSDKCoordinator, audioProcessDiscoverer: AudioProcessDiscoverer, audioDeviceDiscoverer: AudioDeviceDiscoverer) {
        self.sdkCoordinator = sdkCoordinator
        self.audioProcessDiscoverer = audioProcessDiscoverer
        self.audioDeviceDiscoverer = audioDeviceDiscoverer
    }
    #else
    init(sdkCoordinator: ArgmaxSDKCoordinator, audioDeviceDiscoverer: AudioDeviceDiscoverer) {
        self.sdkCoordinator = sdkCoordinator
        self.audioDeviceDiscoverer = audioDeviceDiscoverer
    }
    #endif
    
    /// Contains all transcription data for a single stream including text results, timing information, and audio energy data
    struct StreamResult {
        var title: String = ""
        var confirmedText: String = ""
        var hypothesisText: String = ""
        var streamEndSeconds: Float?
        var bufferEnergy: [Float] = []
        var bufferSeconds: Double = 0
        var transcribeResult: TranscriptionResultPro? = nil
        var streamTimestampText: String {
            guard let end = streamEndSeconds else {
                return ""
            }
            return "[0 --> \(String(format: "%.2f", end))] "
        }
    }
    
    /// Clears all transcription results for both device and system streams
    func clearAllResults() {
        Task { @MainActor in
            deviceResult = nil
            systemResult = nil
        }
    }
    
    /// Sets a callback function to be invoked when transcription results are confirmed
    /// - Parameter confirmedresultCallback: Callback function that receives the source ID and transcription result
    func setConfirmedResultCallback(confirmedresultCallback: @escaping (String, TranscriptionResultPro) -> Void) {
        self.confirmedresultCallback = confirmedresultCallback
    }

    /// Starts transcription for all active stream sources concurrently
    /// - Parameter options: Decoding options to configure the transcription process
    /// - Throws: `StreamingError` if no sources are selected or if audio devices/processes are not available
    func startTranscribing(options: DecodingOptionsPro) async throws {
        // Compute and store active stream sources only once at the start
        curActiveStreamSrcs = try await computeActiveStreamSrcs()
        let activeStreamSrc = curActiveStreamSrcs
        await MainActor.run {
            deviceResult = nil
            systemResult = nil
        }
        guard !activeStreamSrc.isEmpty else {
            throw StreamingError.noSourcesSelected
        }
        
        guard let transcriber = sdkCoordinator.liveTranscriber else {
            throw WhisperError.transcriptionFailed("No transcriber found")
        }
        
        
        // Initialize UI state for all streams in one MainActor call to avoid animation stutter
        await MainActor.run {
            for src in activeStreamSrc {
                #if os(macOS)
                if self.isDeviceSource(src.id) {
                    self.deviceResult = StreamResult(
                        title: "Device: \(audioDeviceDiscoverer.selectedAudioInput)"
                    )
                } else {
                    self.systemResult = StreamResult(
                        title: "System: \(audioProcessDiscoverer.selectedProcessForStream.name)"
                    )
                }
                #else
                if self.isDeviceSource(src.id) {
                    self.deviceResult = StreamResult(
                        title: ""
                    )
                }
                #endif
            }
        }
        
        // Start all streams concurrently
        for src in activeStreamSrc {
            let task = Task.detached {
                do {
                    // Register stream on background queue to avoid blocking UI
                    // Add validation to prevent invalid audio device formats
                    if let argmaxSrc = src as? ArgmaxSource {
                        Logging.debug("Registering stream \(src.id) with device: \(argmaxSrc.streamType)")
                        // Log device info for debugging
                        if case .device(let deviceID) = argmaxSrc.streamType {
                            Logging.debug("Device ID: \(String(describing: deviceID))")
                        }
                    }
                    
                    try await transcriber.registerStream(
                        streamSource: src,
                        options: options
                    ) { [weak self] audioData in
                        if let src = src as? ArgmaxSource {
                            await self?.updateAudioMetrics(for: src, audioData: audioData)
                        }
                    }
                    
                    // Consume transcription results
                    for try await result in try await transcriber.startTranscription(for: src) {
                        await self.handleResult(result, for: src.id)
                    }
                } catch {
                    Logging.error("Stream \(src.id) failed: \(error)")
                    // Notify on main actor about stream failure
                    await MainActor.run {
                        // You could set a property here to show error in UI
                        Logging.error("Stream initialization failed for \(src.id)")
                    }
                }
            }
            self.streamTasks.append(task)
            
        }
    }
    
    /// Stops all active transcription streams and cleans up resources
    func stopTranscribing() {
        Task.detached {
            guard let transcriber = self.sdkCoordinator.liveTranscriber else {
                return
            }
            // First stop and remove all streams
            for source in self.curActiveStreamSrcs {
                do {
                    try await transcriber.stopAndRemoveStream(for: source)
                } catch {
                    Logging.error("Failed to stop stream \(source): \(error)")
                }
            }
            
            // Then cancel all stream consuming tasks
            for task in self.streamTasks {
                task.cancel()
            }
            
            await MainActor.run {
                self.streamTasks.removeAll()
                self.curActiveStreamSrcs.removeAll()
            }
            
            Logging.debug("Stopped all transcription streams")
        }
    }
    
    // MARK: - Private Helpers
    
    private func isDeviceSource(_ sourceId: String) -> Bool {
        return sourceId.starts(with: "device")
    }

    @MainActor
    private func updateStreamResult(sourceId: String, updateBlock: (StreamResult) -> StreamResult) {
        if isDeviceSource(sourceId) {
            let old = deviceResult ?? StreamResult()
            deviceResult = updateBlock(old)
        } else {
            let old = systemResult ?? StreamResult()
            systemResult = updateBlock(old)
        }
    }
    
    @MainActor
    private func handleResult(_ result: LiveResult, for sourceId: String) {
        switch result {
        case .hypothesis(let text, _):
            updateStreamResult(sourceId: sourceId) { oldResult in
                var newResult = oldResult
                newResult.hypothesisText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return newResult
            }
            
        case .confirm(let text, let seconds, let transcriptionResult):
            updateStreamResult(sourceId: sourceId) { oldResult in
                var newResult = oldResult
                let newText = text.trimmingCharacters(in: .whitespaces)
                if !newText.isEmpty {
                    if !newResult.confirmedText.isEmpty {
                        newResult.confirmedText += " "
                    }
                    newResult.confirmedText += newText
                }
                newResult.streamEndSeconds = Float(seconds)
                newResult.transcribeResult = transcriptionResult
                return newResult
            }
            if let confirmedresultCallback = self.confirmedresultCallback {
                confirmedresultCallback(sourceId, transcriptionResult)
            }
        }
    }

    @MainActor
    private func updateAudioMetrics(for source: ArgmaxSource, audioData: [Float]) {
        if case .device = source.streamType, let whisperKitPro = self.sdkCoordinator.whisperKit {
            updateStreamResult(sourceId: source.id) { oldResult in
                var newResult = oldResult
                newResult.bufferEnergy = whisperKitPro.audioProcessor.relativeEnergy
                newResult.bufferSeconds = Double(whisperKitPro.audioProcessor.audioSamples.count) / Double(WhisperKit.sampleRate)
                return newResult
            }
        }
    }
}

enum StreamingError: Error, LocalizedError {
    case noSourcesSelected
    case deviceNotAvailable(deviceName: String)
    case processNotAvailable(processName: String)
    
    var errorDescription: String? {
        switch self {
        case .noSourcesSelected:
            return "No stream sources available to start transcription"
        case .deviceNotAvailable(let deviceName):
            return "Selected audio device '\(deviceName)' is not available"
        case .processNotAvailable(let processName):
            return "Selected audio process '\(processName)' is not available"
        }
    }
    
    var alertTitle: String {
        switch self {
        case .noSourcesSelected:
            return "No Audio Source Selected"
        case .deviceNotAvailable:
            return "Audio Device Not Available"
        case .processNotAvailable:
            return "Audio Process Not Available"
        }
    }
    
    var alertMessage: String {
        switch self {
        case .noSourcesSelected:
            return "Select at least one source"
        case .deviceNotAvailable(let deviceName):
            return "The selected audio device '\(deviceName)' is not available. Please select a different device."
        case .processNotAvailable(let processName):
            return "The selected audio process '\(processName)' is no longer running. Please select a different process."
        }
    }
}

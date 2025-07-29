//  Based on Apple's sample code from "Capturing System Audio with Core Audio Taps"
//  Source: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
//
//  Copyright © 2024 Apple Inc.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#if os(macOS)
import CoreAudio
import Foundation
import AppKit

/// A model to represent a process that produces sound on macOS.
///
/// `AudioProcess` encapsulates information about a system audio process, including its process ID,
/// bundle identifier, name, and running state. It provides functionality to monitor and interact
/// with audio-producing processes on macOS systems.
///
/// The class includes special static instances for system audio and no audio selection scenarios,
/// making it suitable for use in audio source selection interfaces.
///
/// ## Usage Example
///
/// ```swift
/// // Create an AudioProcess for a specific process ID
/// let audioProcess = AudioProcess(id: processID)
/// print("Process: \(audioProcess.name), Running: \(audioProcess.isRunning)")
///
/// // Use special instances
/// let systemAudio = AudioProcess.systemAudio
/// let noAudio = AudioProcess.noAudio
/// ```
@available(macOS 14.2, *)
class AudioProcess: Identifiable, Hashable, ObservableObject {
    var id: AudioObjectID
    var pid: Int32 = 0
    var name: String = ""
    var bundleID: String = ""
    /// Only running process is producing audio
    /// Note: when an audio is paused from a process, it will stop running after a short delay
    var isRunning = false
    
    
    // Static instance for system audio selection
    // TODO - support system audio tapping
    static let systemAudio = AudioProcess(systemAudio: true)
    
    // Static instance for no audio selection
    static let noAudio = AudioProcess(noAudio: true)
    
    // Private initializer for system audio
    private init(systemAudio: Bool) {
        self.id = AudioObjectID(UInt32.max) // Special ID for system audio
        self.pid = -1
        self.name = "System Audio"
        self.bundleID = "system.audio"
        self.isRunning = true
    }
    
    // Private initializer for no audio
    private init(noAudio: Bool) {
        self.id = AudioObjectID(UInt32.max - 1) // Special ID for no audio
        self.pid = -2
        self.name = "No Audio"
        self.bundleID = "no.audio"
        self.isRunning = true
    }
    
    init(id: AudioObjectID) {
        self.id = id
        
        // Get the bundle ID of the audio process.
        var propertyAddress = getPropertyAddress(selector: kAudioProcessPropertyBundleID)
        var propertySize = UInt32(MemoryLayout<CFString>.stride)
        var bundleID: CFString = "" as CFString
        _ = withUnsafeMutablePointer(to: &bundleID) { bundleID in
            AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &propertySize, bundleID)
        }
        self.bundleID = bundleID as String
        
        // Get the PID of the audio process.
        propertyAddress = getPropertyAddress(selector: kAudioProcessPropertyPID)
        propertySize = UInt32(MemoryLayout<Int32>.stride)
        var processPID: Int32 = 0
        AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &propertySize, &processPID)
        self.pid = processPID
        
        self.name = processNameFromPID(pid: self.pid)
        self.updateIsRunning()
        
    }
    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        return lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
    
    
    func updateIsRunning() {
        // Get the `isRunning` property of the process object.
        var propertySize = UInt32(MemoryLayout<UInt32>.stride)
        var running: UInt32 = 0
        var isRunningAddress = getPropertyAddress(selector: kAudioProcessPropertyIsRunning)
        AudioObjectGetPropertyData(self.id, &isRunningAddress, 0, nil, &propertySize, &running)
        self.isRunning = running != 0
    }
    
    private func processNameFromPID(pid: Int32) -> String {
        // Try to get the localized process name from the app using `NSWorkspace`.
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier == pid {
            return app.localizedName ?? ""
        }

        // Otherwise use `sysctl` to obtain the process name.
        var result: String = ""
        var info = kinfo_proc()
        var len = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        if (sysctl(&mib, 4, &info, &len, nil, 0) != -1) && len > 0 {
            withUnsafePointer(to: info.kp_proc.p_comm) {
                $0.withMemoryRebound(to: UInt8.self, capacity: len) {
                    result = String(cString: $0)
                }
            }
        }
        return result
    }
}

#endif

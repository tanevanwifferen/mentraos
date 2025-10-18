//
//  MentraManager.swift
//  MentraOS_Manager
//
//  Created by Matthew Fosse on 3/5/25.
//

import AVFoundation
import Combine
import CoreBluetooth
import Foundation
import React
import UIKit

struct ViewState {
    var topText: String
    var bottomText: String
    var title: String
    var layoutType: String
    var text: String
    var data: String?
    var animationData: [String: Any]?
}

enum MicPreference: String {
    case glasses
    case phone

    static func from(_ value: String) -> MicPreference {
        MicPreference(rawValue: value) ?? .glasses
    }
}

enum MicActivationMode: String {
    case headUp = "head_up"
    case alwaysOn = "always_on"

    static func from(_ value: String) -> MicActivationMode {
        MicActivationMode(rawValue: value) ?? .headUp
    }

    var requiresHeadUp: Bool { self == .headUp }
}

enum MentraDisplayLayout: String {
    case textWall = "text_wall"
    case doubleTextWall = "double_text_wall"
    case referenceCard = "reference_card"
    case bitmap = "bitmap_view"
    case clear = "clear_view"
    case unknown

    init(from rawValue: String) {
        self = MentraDisplayLayout(rawValue: rawValue) ?? .unknown
    }
}

// This class handles logic for managing devices and connections to AugmentOS servers
@objc(MentraManager) class MentraManager: NSObject {
    static let shared = MentraManager()

    @objc static func getInstance() -> MentraManager {
        return MentraManager.shared
    }

    var coreToken: String = ""
    var coreTokenOwner: String = ""
    var sgc: SGCManager?

    var lastStatusObj: [String: Any] = [:]

    var cancellables = Set<AnyCancellable>()
    var defaultWearable: String = ""
    var pendingWearable: String = ""
    var deviceName: String = ""
    var contextualDashboard = true
    var headUpAngle = 30
    var brightness = 50
    var autoBrightness: Bool = true
    var dashboardHeight: Int = 4
    var dashboardDepth: Int = 5
    var sensingEnabled: Bool = true
    var powerSavingMode: Bool = false
    var isSearching: Bool = false
    var isUpdatingScreen: Bool = false
    var alwaysOnStatusBar: Bool = false
    var bypassVad: Bool = true
    var bypassVadForPCM: Bool = false // NEW: PCM subscription bypass
    var enforceLocalTranscription: Bool = false
    var offlineModeEnabled: Bool = false
    var bypassAudioEncoding: Bool = false
    var onboardMicUnavailable: Bool = false
    var metricSystemEnabled: Bool = false
    var settingsLoaded = false
    let settingsLoadedSemaphore = DispatchSemaphore(value: 0)
    var connectTask: Task<Void, Never>?
    var glassesWifiConnected: Bool = false
    var glassesWifiSsid: String = ""
    var isHeadUp: Bool = false
    var sendStateWorkItem: DispatchWorkItem?
    let sendStateQueue = DispatchQueue(label: "sendStateQueue", qos: .userInitiated)
    var shouldSendBootingMessage = true

    // mic:
    var useOnboardMic = false
    var preferredMic: MicPreference = .glasses
    var micEnabled = false
    var micSessionActive = false
    var micActivationMode: MicActivationMode = .headUp
    var currentRequiredData: [SpeechRequiredDataType] = []
    // Track whether any foreground (standard) app is open and running
    var hasForegroundAppOpen = false

    // Head-up mic timeout (auto-disable after grace period)
    var headUpMicTimeoutWorkItem: DispatchWorkItem?
    var headUpMicTimeoutElapsed = false
    var headUpMicTimeoutSeconds: Int = 20
    var headUpMicTimeoutEnabled: Bool = true
    // When true, mic/UI should be gated until head goes down or a foreground app opens
    var micBlockedByTimeout: Bool = false

    // button settings:
    var buttonPressMode = "photo"
    var buttonPhotoSize = "medium"
    var buttonVideoWidth = 1280
    var buttonVideoHeight = 720
    var buttonVideoFps = 30
    var buttonMaxRecordingTimeMinutes = 10
    var buttonCameraLed = true

    // VAD:
    var vad: SileroVADStrategy?
    var vadBuffer = [Data]()
    var isSpeaking = false

    // STT:
    var transcriber: SherpaOnnxTranscriber?
    var shouldSendPcmData = false
    var shouldSendTranscript = false

    var viewStates: [ViewState] = [
        ViewState(
            topText: " ", bottomText: " ", title: " ", layoutType: "text_wall", text: ""
        ),
        ViewState(
            topText: " ", bottomText: " ", title: " ", layoutType: "text_wall",
            text: "$TIME12$ $DATE$ $GBATT$ $CONNECTION_STATUS$"
        ),
        ViewState(
            topText: " ", bottomText: " ", title: " ", layoutType: "text_wall", text: "",
            data: nil, animationData: nil
        ),
        ViewState(
            topText: " ", bottomText: " ", title: " ", layoutType: "text_wall",
            text: "$TIME12$ $DATE$ $GBATT$ $CONNECTION_STATUS$", data: nil,
            animationData: nil
        ),
    ]

    override init() {
        Bridge.log("Mentra: init()")
        vad = SileroVADStrategy()
        super.init()

        // Initialize SherpaOnnx Transcriber
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController
        {
            transcriber = SherpaOnnxTranscriber(context: rootViewController)
        } else {
            Bridge.log("Failed to create SherpaOnnxTranscriber - no root view controller found")
        }

        // Initialize the transcriber
        if let transcriber = transcriber {
            transcriber.initialize()
            Bridge.log("SherpaOnnxTranscriber fully initialized")
        }

        Task {
            self.vad?.setup(
                sampleRate: .rate_16k,
                frameSize: .size_1024,
                quality: .normal,
                silenceTriggerDurationMs: 4000,
                speechTriggerDurationMs: 50
            )
        }
    }

    // MARK: - Public Methods (for React Native)

    func onConnectionError(_: String) {
        handle_request_status()
    }

    func onAuthError() {}

    // MARK: - Voice Data Handling

    // MARK: - ServerCommsCallback Implementation

    func setMicActivationMode(_ mode: String) {
        let normalized = MicActivationMode.from(mode)
        if micActivationMode == normalized {
            return
        }
        micActivationMode = normalized
        handle_microphone_state_change(currentRequiredData, bypassVadForPCM)
    }

    func onJsonMessage(_ message: [String: Any]) {
        Bridge.log("Mentra: onJsonMessage: \(message)")
        sgc?.sendJson(message, wakeUp: false)
    }

    func handle_photo_request(
        _ requestId: String, _ appId: String, _ size: String, _ webhookUrl: String?
    ) {
        Bridge.log("Mentra: onPhotoRequest: \(requestId), \(appId), \(webhookUrl), size=\(size)")
        sgc?.requestPhoto(requestId, appId: appId, size: size, webhookUrl: webhookUrl)
    }

    func onRtmpStreamStartRequest(_ message: [String: Any]) {
        Bridge.log("Mentra: onRtmpStreamStartRequest: \(message)")
        sgc?.startRtmpStream(message)
    }

    func onRtmpStreamStop() {
        Bridge.log("Mentra: onRtmpStreamStop")
        sgc?.stopRtmpStream()
    }

    func onRtmpStreamKeepAlive(_ message: [String: Any]) {
        Bridge.log("Mentra: onRtmpStreamKeepAlive: \(message)")
        sgc?.sendRtmpKeepAlive(message)
    }

    func handle_start_buffer_recording() {
        Bridge.log("Mentra: onStartBufferRecording")
        sgc?.startBufferRecording()
    }

    func handle_stop_buffer_recording() {
        Bridge.log("Mentra: onStopBufferRecording")
        sgc?.stopBufferRecording()
    }

    func handle_save_buffer_video(_ requestId: String, _ durationSeconds: Int) {
        Bridge.log(
            "Mentra: onSaveBufferVideo: requestId=\(requestId), duration=\(durationSeconds)s")
        sgc?.saveBufferVideo(requestId: requestId, durationSeconds: durationSeconds)
    }

    func handle_start_video_recording(_ requestId: String, _ save: Bool) {
        Bridge.log("Mentra: onStartVideoRecording: requestId=\(requestId), save=\(save)")
        sgc?.startVideoRecording(requestId: requestId, save: save)
    }

    func handle_stop_video_recording(_ requestId: String) {
        Bridge.log("Mentra: onStopVideoRecording: requestId=\(requestId)")
        sgc?.stopVideoRecording(requestId: requestId)
    }

    //  func onDashboardDisplayEvent(_ event: [String: Any]) {
    //    Core.log("got dashboard display event")
    ////    onDisplayEvent?(["event": event, "type": "dashboard"])
    //    Core.log(event)
    ////    Task {
    ////      await self.g1Manager.sendText(text: "\(event)")
    ////    }
    //  }

    func onRequestSingle(_ dataType: String) {
        // Handle single data request
        if dataType == "battery" {
            // Send battery status if needed
        }
        // TODO:
        handle_request_status()
    }

    func onRouteChange(
        reason: AVAudioSession.RouteChangeReason, availableInputs: [AVAudioSessionPortDescription]
    ) {
        Bridge.log("Mentra: onRouteChange: reason: \(reason)")
        Bridge.log("Mentra: onRouteChange: inputs: \(availableInputs)")

        // Update onboard mic availability based on inputs present
        onboardMicUnavailable = availableInputs.isEmpty

        // Re-evaluate mic selection immediately to adopt the most stable source
        handle_microphone_state_change(currentRequiredData, bypassVadForPCM)
    }

    func onInterruption(began: Bool) {
        Bridge.log("Mentra: Interruption: \(began)")

        onboardMicUnavailable = began
        handle_microphone_state_change(currentRequiredData, bypassVadForPCM)
    }

    // command functions:
    func setAuthCreds(_ token: String, _ userId: String) {
        Bridge.log("Mentra: Setting core token to: \(token) for user: \(userId)")
        coreToken = token
        coreTokenOwner = userId
        handle_request_status()
    }

    func enableContextualDashboard(_ enabled: Bool) {
        contextualDashboard = enabled
        handle_request_status() // to update the UI
    }

    func setPreferredMic(_ mic: String) {
        preferredMic = MicPreference.from(mic)
        handle_microphone_state_change(currentRequiredData, bypassVadForPCM)
        handle_request_status() // to update the UI
    }

    func setButtonMode(_ mode: String) {
        buttonPressMode = mode
        sgc?.sendButtonModeSetting()
        handle_request_status() // to update the UI
    }

    func setButtonPhotoSize(_ size: String) {
        buttonPhotoSize = size
        sgc?.sendButtonPhotoSettings()
        handle_request_status() // to update the UI
    }

    func setButtonVideoSettings(width: Int, height: Int, fps: Int) {
        buttonVideoWidth = width
        buttonVideoHeight = height
        buttonVideoFps = fps
        sgc?.sendButtonVideoRecordingSettings()
        handle_request_status() // to update the UI
    }

    func setButtonMaxRecordingTime(_ minutes: Int) {
        buttonMaxRecordingTimeMinutes = minutes
        sgc?.sendButtonMaxRecordingTime(minutes)
        handle_request_status() // to update the UI
    }

    func setButtonCameraLed(_: Bool) {
        sgc?.sendButtonCameraLedSetting()

        handle_request_status() // to update the UI
    }

    func handleRgbLedControl(
        requestId: String,
        packageName: String?,
        action: String,
        color: String?,
        ontime: Int,
        offtime: Int,
        count: Int
    ) {
        guard let live = sgc as? MentraLive else {
            Bridge.log(
                "Mentra: RGB LED control requested but current SGC does not support Mentra Live features"
            )
            Bridge.sendRgbLedControlResponse(
                requestId: requestId, success: false, error: "unsupported_device"
            )
            return
        }

        live.handleRgbLedControl(
            requestId: requestId,
            packageName: packageName,
            action: action,
            color: color,
            ontime: ontime,
            offtime: offtime,
            count: count
        )
    }

    func updateGlassesHeadUpAngle(_ value: Int) {
        headUpAngle = value
        sgc?.setHeadUpAngle(value)
        handle_request_status() // to update the UI
    }

    func updateGlassesBrightness(_ value: Int, autoBrightness: Bool) {
        let autoBrightnessChanged = self.autoBrightness != autoBrightness
        brightness = value
        self.autoBrightness = autoBrightness
        Task {
            sgc?.setBrightness(value, autoMode: autoBrightness)
            if autoBrightnessChanged {
                sendText(autoBrightness ? "Enabled auto brightness" : "Disabled auto brightness")
            } else {
                sendText("Set brightness to \(value)%")
            }
            try? await Task.sleep(nanoseconds: 800_000_000) // 0.8 seconds
            sendText(" ") // clear screen
        }
        handle_request_status() // to update the UI
    }

    func updateGlassesDepth(_ value: Int) {
        dashboardDepth = value
        Task {
            await sgc?.setDashboardPosition(self.dashboardHeight, self.dashboardDepth)
            Bridge.log("Mentra: Set dashboard depth to \(value)")
        }
        handle_request_status() // to update the UI
    }

    func updateGlassesHeight(_ value: Int) {
        dashboardHeight = value
        Task {
            await sgc?.setDashboardPosition(self.dashboardHeight, self.dashboardDepth)
            Bridge.log("Mentra: Set dashboard height to \(value)")
        }
        handle_request_status() // to update the UI
    }

    func enableSensing(_ enabled: Bool) {
        sensingEnabled = enabled
        // Update microphone state when sensing is toggled
        handle_microphone_state_change(currentRequiredData, bypassVadForPCM)
        handle_request_status() // to update the UI
    }

    func enablePowerSavingMode(_ enabled: Bool) {
        powerSavingMode = enabled
        handle_request_status() // to update the UI
    }

    func enableAlwaysOnStatusBar(_ enabled: Bool) {
        alwaysOnStatusBar = enabled
        handle_request_status() // to update the UI
    }

    func bypassVad(_ enabled: Bool) {
        bypassVad = enabled
        handle_request_status() // to update the UI
    }

    func enforceLocalTranscription(_ enabled: Bool) {
        enforceLocalTranscription = enabled

        if currentRequiredData.contains(.PCM_OR_TRANSCRIPTION) {
            // TODO: Later add bandwidth based logic
            if enforceLocalTranscription {
                shouldSendTranscript = true
                shouldSendPcmData = false
            } else {
                shouldSendPcmData = true
                shouldSendTranscript = false
            }
        }

        handle_request_status() // to update the UI
    }

    func enableOfflineMode(_ enabled: Bool) {
        offlineModeEnabled = enabled

        var requiredData: [SpeechRequiredDataType] = []

        if enabled {
            requiredData.append(.TRANSCRIPTION)
        }

        handle_microphone_state_change(requiredData, bypassVadForPCM)
    }

    func setBypassAudioEncoding(_ enabled: Bool) {
        bypassAudioEncoding = enabled
    }

    func setMetricSystemEnabled(_ enabled: Bool) {
        metricSystemEnabled = enabled
        handle_request_status()
    }

    func toggleUpdatingScreen(_ enabled: Bool) {
        Bridge.log("Mentra: Toggling updating screen: \(enabled)")
        if enabled {
            sgc?.exit()
            isUpdatingScreen = true
        } else {
            isUpdatingScreen = false
        }
    }

    func showDashboard() {
        sgc?.showDashboard()
    }

    func saveBufferVideo(requestId: String, durationSeconds: Int) {
        sgc?.saveBufferVideo(requestId: requestId, durationSeconds: durationSeconds)
    }

    func startVideoRecording(requestId: String, save: Bool) {
        sgc?.startVideoRecording(requestId: requestId, save: save)
    }

    @objc func stopVideoRecording(requestId: String) {
        sgc?.stopVideoRecording(requestId: requestId)
    }

    func requestWifiScan() {
        Bridge.log("Mentra: Requesting wifi scan")
        sgc?.requestWifiScan()
    }

    func sendWifiCredentials(_ ssid: String, _ password: String) {
        Bridge.log("Mentra: Sending wifi credentials: \(ssid) \(password)")
        sgc?.sendWifiCredentials(ssid, password)
    }

    func setGlassesHotspotState(_ enabled: Bool) {
        Bridge.log("Mentra: 🔥 Setting glasses hotspot state: \(enabled)")
        sgc?.sendHotspotState(enabled)
    }

    func queryGalleryStatus() {
        Bridge.log("Mentra: 📸 Querying gallery status from glasses")
        sgc?.queryGalleryStatus()
    }

    func sendGalleryModeActive(_ active: Bool) {
        Bridge.log("Mentra: 📸 Sending gallery mode active to glasses: \(active)")
        sgc?.sendGalleryModeActive(active)
    }

    func restartTranscriber() {
        Bridge.log("Mentra: Restarting SherpaOnnxTranscriber via command")
        transcriber?.restart()
    }

    func getGlassesHasMic() -> Bool {
        if defaultWearable.contains("G1") {
            return true
        }
        if defaultWearable.contains("Live") {
            return false
        }
        if defaultWearable.contains("Mach1") {
            return false
        }
        return false
    }

    // construct the status object:
    func playStartupSequence() {
        Bridge.log("Mentra: playStartupSequence()")
        // Arrow frames for the animation
        let arrowFrames = ["↑", "↗", "↑", "↖"]

        let delay = 0.25 // Frame delay in seconds
        let totalCycles = 2 // Number of animation cycles

        // Variables to track animation state
        var frameIndex = 0
        var cycles = 0

        // Create a dispatch queue for the animation
        let animationQueue = DispatchQueue.global(qos: .userInteractive)

        // Function to display the current animation frame
        func displayFrame() {
            // Check if we've completed all cycles
            if cycles >= totalCycles {
                // End animation with final message
                sendText("                  /// MentraOS Connected \\\\\\")
                animationQueue.asyncAfter(deadline: .now() + 1.0) {
                    self.sendText(" ")
                }
                return
            }

            // Display current animation frame
            let frameText =
                "                    \(arrowFrames[frameIndex]) MentraOS Booting \(arrowFrames[frameIndex])"
            sendText(frameText)

            // Move to next frame
            frameIndex = (frameIndex + 1) % arrowFrames.count

            // Count completed cycles
            if frameIndex == 0 {
                cycles += 1
            }

            // Schedule next frame
            animationQueue.asyncAfter(deadline: .now() + delay) {
                displayFrame()
            }
        }

        // Start the animation after a short initial delay
        animationQueue.asyncAfter(deadline: .now() + 0.35) {
            displayFrame()
        }
    }

    // MARK: - Cleanup

    @objc func cleanup() {
        // Clean up transcriber resources
        transcriber?.shutdown()
        transcriber = nil

        cancellables.removeAll()
    }
}

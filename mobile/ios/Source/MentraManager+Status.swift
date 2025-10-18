//
//  MentraManager+Status.swift
//  MentraOS_Manager
//
//  Created by Codex on 3/17/24.
//

import Foundation

extension MentraManager {
    func handle_request_status() {
        let simulatedConnected = defaultWearable == "Simulated Glasses"
        let isGlassesConnected = sgc?.ready ?? false
        if isGlassesConnected {
            isSearching = false
        }

        let connectedGlasses = buildConnectedGlassesInfo(
            isGlassesConnected: isGlassesConnected, simulatedConnected: simulatedConnected
        )
        let glassesSettings = buildGlassesSettings()

        let coreInfo: [String: Any] = [
            "augmentos_core_version": "Unknown",
            "default_wearable": defaultWearable as Any,
            "preferred_mic": preferredMic.rawValue,
            "is_searching": isSearching,
            "is_mic_enabled_for_frontend": micEnabled && preferredMic == .glasses
                && isSomethingConnected(),
            "sensing_enabled": sensingEnabled,
            "power_saving_mode": powerSavingMode,
            "always_on_status_bar": alwaysOnStatusBar,
            "bypass_vad_for_debugging": bypassVad,
            "enforce_local_transcription": enforceLocalTranscription,
            "bypass_audio_encoding_for_debugging": bypassAudioEncoding,
            "core_token": coreToken,
            "puck_connected": true,
            "metric_system_enabled": metricSystemEnabled,
            "contextual_dashboard_enabled": contextualDashboard,
            "head_up_mic_timeout_enabled": headUpMicTimeoutEnabled,
            "head_up_mic_timeout_seconds": headUpMicTimeoutSeconds,
            "mic_blocked_by_timeout": micBlockedByTimeout,
        ]

        let authObj: [String: Any] = ["core_token_owner": coreTokenOwner]

        let statusObj: [String: Any] = [
            "connected_glasses": connectedGlasses,
            "glasses_settings": glassesSettings,
            "apps": [[String: Any]](),
            "core_info": coreInfo,
            "auth": authObj,
        ]

        lastStatusObj = statusObj
        Bridge.sendStatus(statusObj)
    }

    func triggerStatusUpdate() {
        Bridge.log("🔄 Triggering immediate status update")
        handle_request_status()
    }

    func handle_update_settings(_ settings: [String: Any]) {
        Bridge.log("Mentra: Received update settings: \(settings)")

        if let newPreferredMic = settings["preferred_mic"] as? String {
            let preference = MicPreference.from(newPreferredMic)
            if preference != preferredMic {
                setPreferredMic(newPreferredMic)
            }
        }

        if let newMicActivationMode = settings["mic_activation_mode"] as? String {
            let activationMode = MicActivationMode.from(newMicActivationMode)
            if activationMode != micActivationMode {
                setMicActivationMode(newMicActivationMode)
            }
        }

        if let newHeadUpAngle = settings["head_up_angle"] as? Int, newHeadUpAngle != headUpAngle {
            updateGlassesHeadUpAngle(newHeadUpAngle)
        }

        if let newBrightness = settings["brightness"] as? Int, newBrightness != brightness {
            updateGlassesBrightness(newBrightness, autoBrightness: false)
        }

        if let newDashboardHeight = settings["dashboard_height"] as? Int,
           newDashboardHeight != dashboardHeight
        {
            updateGlassesHeight(newDashboardHeight)
        }

        if let newDashboardDepth = settings["dashboard_depth"] as? Int,
           newDashboardDepth != dashboardDepth
        {
            updateGlassesDepth(newDashboardDepth)
        }

        if let newAutoBrightness = settings["auto_brightness"] as? Bool,
           newAutoBrightness != autoBrightness
        {
            updateGlassesBrightness(brightness, autoBrightness: newAutoBrightness)
        }

        if let sensingEnabled = settings["sensing_enabled"] as? Bool,
           sensingEnabled != self.sensingEnabled
        {
            enableSensing(sensingEnabled)
        }

        if let powerSavingMode = settings["power_saving_mode"] as? Bool,
           powerSavingMode != self.powerSavingMode
        {
            enablePowerSavingMode(powerSavingMode)
        }

        if let newAlwaysOnStatusBar = settings["always_on_status_bar_enabled"] as? Bool,
           newAlwaysOnStatusBar != alwaysOnStatusBar
        {
            enableAlwaysOnStatusBar(newAlwaysOnStatusBar)
        }

        if let timeoutEnabled = settings["head_up_mic_timeout_enabled"] as? Bool {
            headUpMicTimeoutEnabled = timeoutEnabled
            if !timeoutEnabled {
                // Disabling the feature immediately cancels any pending timeout
                cancelHeadUpTimeout()
            } else {
                // Enabling while head is already up: only schedule if eligible.
                // Do NOT reset elapsed/blocked to preserve one-shot semantics.
                scheduleHeadUpTimeoutIfNeeded()
            }
        }
        if let timeoutSeconds = settings["head_up_mic_timeout_seconds"] as? Int {
            headUpMicTimeoutSeconds = max(5, min(300, timeoutSeconds))
            // Do NOT reset elapsed/blocked when changing duration; honor one-shot semantics.
            // Only schedule if currently eligible.
            scheduleHeadUpTimeoutIfNeeded()
        }

        if let newBypassVad = settings["bypass_vad_for_debugging"] as? Bool,
           newBypassVad != bypassVad
        {
            bypassVad(newBypassVad)
        }

        if let newEnforceLocalTranscription = settings["enforce_local_transcription"] as? Bool,
           newEnforceLocalTranscription != enforceLocalTranscription
        {
            enforceLocalTranscription(newEnforceLocalTranscription)
        }

        if let newEnableOfflineMode = settings["offline_captions_app_running"] as? Bool,
           newEnableOfflineMode != offlineModeEnabled
        {
            enableOfflineMode(newEnableOfflineMode)
        }

        if let newMetricSystemEnabled = settings["metric_system_enabled"] as? Bool,
           newMetricSystemEnabled != metricSystemEnabled
        {
            setMetricSystemEnabled(newMetricSystemEnabled)
        }

        if let newContextualDashboard = settings["contextual_dashboard_enabled"] as? Bool,
           newContextualDashboard != contextualDashboard
        {
            enableContextualDashboard(newContextualDashboard)
        }

        if let newButtonMode = settings["button_mode"] as? String, newButtonMode != buttonPressMode {
            setButtonMode(newButtonMode)
        }

        if let newFps = settings["button_video_fps"] as? Int, newFps != buttonVideoFps {
            setButtonVideoSettings(width: buttonVideoWidth, height: buttonVideoHeight, fps: newFps)
        }

        if let newWidth = settings["button_video_width"] as? Int, newWidth != buttonVideoWidth {
            setButtonVideoSettings(width: newWidth, height: buttonVideoHeight, fps: buttonVideoFps)
        }

        if let newHeight = settings["button_video_height"] as? Int, newHeight != buttonVideoHeight {
            setButtonVideoSettings(width: buttonVideoWidth, height: newHeight, fps: buttonVideoFps)
        }

        if let newPhotoSize = settings["button_photo_size"] as? String,
           newPhotoSize != buttonPhotoSize
        {
            setButtonPhotoSize(newPhotoSize)
        }

        if let newDefaultWearable = settings["default_wearable"] as? String,
           newDefaultWearable != defaultWearable
        {
            defaultWearable = newDefaultWearable
            Bridge.saveSetting("default_wearable", newDefaultWearable)
        }
    }
}

private extension MentraManager {
    func buildConnectedGlassesInfo(isGlassesConnected: Bool, simulatedConnected: Bool)
        -> [String: Any]
    {
        var connectedGlasses: [String: Any] = [:]

        if isGlassesConnected {
            connectedGlasses = [
                "model_name": defaultWearable,
                "battery_level": sgc?.batteryLevel ?? -1,
                "glasses_app_version": sgc?.glassesAppVersion ?? "",
                "glasses_build_number": sgc?.glassesBuildNumber ?? "",
                "glasses_device_model": sgc?.glassesDeviceModel ?? "",
                "glasses_android_version": sgc?.glassesAndroidVersion ?? "",
                "glasses_ota_version_url": sgc?.glassesOtaVersionUrl ?? "",
            ]
        } else if simulatedConnected {
            connectedGlasses["model_name"] = defaultWearable
        }

        if sgc is G1 {
            connectedGlasses["case_removed"] = sgc?.caseRemoved ?? true
            connectedGlasses["case_open"] = sgc?.caseOpen ?? true
            connectedGlasses["case_charging"] = sgc?.caseCharging ?? false
            connectedGlasses["case_battery_level"] = sgc?.caseBatteryLevel ?? -1

            if let serialNumber = sgc?.glassesSerialNumber, !serialNumber.isEmpty {
                connectedGlasses["glasses_serial_number"] = serialNumber
                connectedGlasses["glasses_style"] = sgc?.glassesStyle ?? ""
                connectedGlasses["glasses_color"] = sgc?.glassesColor ?? ""
            }
        }

        if let live = sgc as? MentraLive {
            if let wifiSsid = live.wifiSsid, !wifiSsid.isEmpty {
                connectedGlasses["glasses_wifi_ssid"] = wifiSsid
                connectedGlasses["glasses_wifi_connected"] = live.wifiConnected
                connectedGlasses["glasses_wifi_local_ip"] = live.wifiLocalIp ?? ""
            }

            connectedGlasses["glasses_hotspot_enabled"] = live.isHotspotEnabled ?? false
            connectedGlasses["glasses_hotspot_ssid"] = live.hotspotSsid ?? ""
            connectedGlasses["glasses_hotspot_password"] = live.hotspotPassword ?? ""
            connectedGlasses["glasses_hotspot_gateway_ip"] = live.hotspotGatewayIp ?? ""
        }

        if let bluetoothName = sgc?.getConnectedBluetoothName() {
            connectedGlasses["bluetooth_name"] = bluetoothName
        }

        return connectedGlasses
    }

    func buildGlassesSettings() -> [String: Any] {
        [
            "brightness": brightness,
            "auto_brightness": autoBrightness,
            "dashboard_height": dashboardHeight,
            "dashboard_depth": dashboardDepth,
            "head_up_angle": headUpAngle,
            "button_mode": buttonPressMode,
            "button_photo_size": buttonPhotoSize,
            "button_video_settings": [
                "width": buttonVideoWidth,
                "height": buttonVideoHeight,
                "fps": buttonVideoFps,
            ],
            "button_max_recording_time_minutes": buttonMaxRecordingTimeMinutes,
            "button_camera_led": buttonCameraLed,
        ]
    }
}

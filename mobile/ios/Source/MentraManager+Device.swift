//
//  MentraManager+Device.swift
//  MentraOS_Manager
//
//  Created by Codex on 3/17/24.
//

import Foundation

extension MentraManager {
    func initSGC(_ wearable: String) {
        Bridge.log("Initializing manager for wearable: \(wearable)")
        guard sgc == nil else { return }

        if wearable.contains("G1") {
            sgc = G1()
        } else if wearable.contains("Live") {
            sgc = MentraLive()
        } else if wearable.contains("Mach1") {
            sgc = Mach1()
        } else if wearable.contains("Frame") || wearable.contains("Brilliant Labs") {
            sgc = FrameManager()
        }
    }

    func initSGCCallbacks() {
        // TODO: make sure this functionality is baked into the SGCs!
    }

    func handleConnectionStateChange() {
        Bridge.log("Mentra: Glasses: connection state changed!")
        guard let sgc else { return }

        if sgc.ready {
            handleDeviceReady()
        } else {
            handleDeviceDisconnected()
            handle_request_status()
        }
    }

    func disconnectWearable() {
        sendText(" ")
        Task {
            connectTask?.cancel()
            sgc?.disconnect()
            isSearching = false
            handle_request_status()
        }
    }

    func forgetSmartGlasses() {
        disconnectWearable()
        defaultWearable = ""
        deviceName = ""
        sgc?.forget()
        sgc = nil
        Bridge.saveSetting("default_wearable", "")
        Bridge.saveSetting("device_name", "")
        handle_request_status()
    }

    func handleSearchForCompatibleDeviceNames(_ modelName: String) {
        Bridge.log("Mentra: Searching for compatible device names for: \(modelName)")
        if modelName.contains("Simulated") {
            defaultWearable = "Simulated Glasses"
            handle_request_status()
            return
        }
        if modelName.contains("G1") {
            pendingWearable = "Even Realities G1"
        } else if modelName.contains("Live") {
            pendingWearable = "Mentra Live"
        } else if modelName.contains("Mach1") || modelName.contains("Z100") {
            pendingWearable = "Mach1"
        }
        initSGC(pendingWearable)
        sgc?.findCompatibleDevices()
    }

    func handle_connect_wearable(_ deviceName: String, modelName: String? = nil) {
        Bridge.log(
            "Mentra: Connecting to modelName: \(modelName ?? "nil") deviceName: \(deviceName) defaultWearable: \(defaultWearable) pendingWearable: \(pendingWearable) selfDeviceName: \(self.deviceName)"
        )

        if let modelName {
            pendingWearable = modelName
        }

        if pendingWearable.contains("Simulated") {
            Bridge.log(
                "Mentra: Pending wearable is simulated, setting default wearable to Simulated Glasses"
            )
            defaultWearable = "Simulated Glasses"
            handle_request_status()
            return
        }

        if pendingWearable.isEmpty, defaultWearable.isEmpty {
            Bridge.log("Mentra: No pending or default wearable, returning")
            return
        }

        if pendingWearable.isEmpty, !defaultWearable.isEmpty {
            Bridge.log("Mentra: No pending wearable, using default wearable: \(defaultWearable)")
            pendingWearable = defaultWearable
        }

        Task {
            disconnectWearable()

            try? await Task.sleep(nanoseconds: 100 * 1_000_000)
            self.isSearching = true
            handle_request_status()

            if !deviceName.isEmpty {
                self.deviceName = deviceName
            }

            initSGC(self.pendingWearable)
            sgc?.connectById(self.deviceName)
        }
    }

    func handleDeviceReady() {
        guard let sgc else {
            Bridge.log("Mentra: SGC is nil, returning")
            return
        }

        Bridge.log("Mentra: handleDeviceReady(): \(sgc.type)")
        Bridge.sendBatteryStatus(level: sgc.batteryLevel ?? -1, charging: false)
        Bridge.sendGlassesConnectionState(modelName: defaultWearable, status: "CONNECTED")

        pendingWearable = ""
        defaultWearable = sgc.type
        isSearching = false
        handle_request_status()

        if defaultWearable.contains("G1") {
            handleG1Ready()
        } else if defaultWearable.contains("Mach1") {
            handleMach1Ready()
        }

        Bridge.saveSetting("default_wearable", defaultWearable)
        Bridge.saveSetting("device_name", deviceName)
    }

    func handleDeviceDisconnected() {
        Bridge.log("Mentra: Device disconnected")
        handle_microphone_state_change([], false)
        Bridge.sendGlassesConnectionState(modelName: defaultWearable, status: "DISCONNECTED")
        handle_request_status()
    }

    func startBufferRecording() {
        sgc?.startBufferRecording()
    }

    func stopBufferRecording() {
        sgc?.stopBufferRecording()
    }

    func isSomethingConnected() -> Bool {
        if sgc?.ready == true {
            return true
        }
        if defaultWearable.contains("Simulated") {
            return true
        }
        return false
    }
}

private extension MentraManager {
    func handleG1Ready() {
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await sgc?.setSilentMode(false)
            await sgc?.getBatteryStatus()

            if shouldSendBootingMessage {
                sendText("// BOOTING MENTRAOS")
            }

            try? await Task.sleep(nanoseconds: 400_000_000)
            sgc?.setHeadUpAngle(headUpAngle)
            try? await Task.sleep(nanoseconds: 400_000_000)
            sgc?.setBrightness(brightness, autoMode: autoBrightness)

            if shouldSendBootingMessage {
                sendText("// MENTRAOS CONNECTED")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                sendText(" ")
            }

            shouldSendBootingMessage = false
            handle_request_status()
        }
    }

    func handleMach1Ready() {
        Task {
            sendText("MENTRAOS CONNECTED")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            clearDisplay()
            handle_request_status()
        }
    }
}

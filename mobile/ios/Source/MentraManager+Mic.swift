//
//  MentraManager+Mic.swift
//  MentraOS_Manager
//
//  Created by Codex on 3/17/24.
//

import Foundation

#if canImport(UIKit)
    import UIKit
#endif

extension MentraManager {
    func handleGlassesMicData(_ rawLC3Data: Data) {
        guard rawLC3Data.count > 2 else {
            Bridge.log("Received invalid PCM data size: \(rawLC3Data.count)")
            return
        }

        let lc3Data = rawLC3Data.subdata(in: 2 ..< rawLC3Data.count)
        guard !lc3Data.isEmpty else {
            Bridge.log("No LC3 data after removing command bytes")
            return
        }

        if bypassVad || bypassVadForPCM {
            Bridge.log(
                "Mentra: Glasses mic VAD bypassed - bypassVad=\(bypassVad), bypassVadForPCM=\(bypassVadForPCM)"
            )
            checkSetVadStatus(speaking: true)
            emptyVadBuffer()

            let pcmData = PcmConverter().decode(lc3Data) as Data
            Bridge.sendMicData(pcmData)
            return
        }

        let pcmData = PcmConverter().decode(lc3Data) as Data
        guard !pcmData.isEmpty else {
            Bridge.log("PCM conversion resulted in empty data")
            return
        }

        guard let vad else {
            Bridge.log("VAD not initialized")
            return
        }

        let pcmDataArray = pcmData.withUnsafeBytes { pointer -> [Int16] in
            Array(
                UnsafeBufferPointer(
                    start: pointer.bindMemory(to: Int16.self).baseAddress,
                    count: pointer.count / MemoryLayout<Int16>.stride
                ))
        }

        vad.checkVAD(pcm: pcmDataArray) { [weak self] state in
            guard let self else { return }
            Bridge.log("VAD State: \(state)")
        }

        if vad.currentState() == .speeching {
            checkSetVadStatus(speaking: true)
            emptyVadBuffer()
            Bridge.sendMicData(pcmData)
        } else {
            checkSetVadStatus(speaking: false)
            addToVadBuffer(pcmData)
        }
    }

    func handlePcm(_ pcmData: Data) {
        guard let vad else {
            Bridge.log("VAD not initialized")
            return
        }

        if bypassVad || bypassVadForPCM {
            if shouldSendPcmData {
                Bridge.sendMicData(pcmData)
            }

            if shouldSendTranscript {
                transcriber?.acceptAudio(pcm16le: pcmData)
            }
            return
        }

        let pcmDataArray = pcmData.withUnsafeBytes { pointer -> [Int16] in
            Array(
                UnsafeBufferPointer(
                    start: pointer.bindMemory(to: Int16.self).baseAddress,
                    count: pointer.count / MemoryLayout<Int16>.stride
                ))
        }

        vad.checkVAD(pcm: pcmDataArray) { [weak self] state in
            guard let self else { return }
            Bridge.log("VAD State: \(state)")
        }

        if vad.currentState() == .speeching {
            checkSetVadStatus(speaking: true)
            emptyVadBuffer()

            if shouldSendPcmData {
                Bridge.sendMicData(pcmData)
            }

            if shouldSendTranscript {
                transcriber?.acceptAudio(pcm16le: pcmData)
            }
        } else {
            checkSetVadStatus(speaking: false)
            addToVadBuffer(pcmData)
        }
    }

    func handle_microphone_state_change(_ requiredData: [SpeechRequiredDataType], _ bypassVad: Bool) {
        var normalizedRequiredData = normalizeRequiredData(requiredData)
        Bridge.log(
            "Mentra: MIC: @@@@@@@@ changing mic with requiredData: \(normalizedRequiredData) bypassVad=\(bypassVad) enforceLocalTranscription=\(enforceLocalTranscription) @@@@@@@@@@@@@@@@"
        )
        Bridge.log(
            "Mentra: MIC: state before decision -> micEnabled=\(micEnabled), micSessionActive=\(micSessionActive), sensingEnabled=\(sensingEnabled), isHeadUp=\(isHeadUp), hasForegroundAppOpen=\(hasForegroundAppOpen), micActivationMode=\(micActivationMode.rawValue), headUpTimeoutEnabled=\(headUpMicTimeoutEnabled), headUpTimeoutElapsed=\(headUpMicTimeoutElapsed)"
        )

        let outputs = resolveSpeechOutputs(for: normalizedRequiredData)
        shouldSendPcmData = outputs.sendPcm
        shouldSendTranscript = outputs.sendTranscript

        currentRequiredData = normalizedRequiredData
        vadBuffer.removeAll()

        micEnabled = !normalizedRequiredData.isEmpty

        let requestActive = micEnabled
        let sensorsAllowMic = sensingEnabled
        let headUp = isHeadUp

        if !requestActive || !sensorsAllowMic {
            micSessionActive = false
        }

        var shouldEnableMic = requestActive && sensorsAllowMic
        let micBlocked =
            micBlockedByTimeout && micActivationMode.requiresHeadUp && !hasForegroundAppOpen

        if micBlocked {
            shouldEnableMic = false
            micSessionActive = false
        } else if shouldEnableMic {
            if micActivationMode == .alwaysOn || hasForegroundAppOpen || isHeadUpEffective {
                micSessionActive = true
            } else {
                shouldEnableMic = false
                micSessionActive = false
            }
        }

        Bridge.log(
            "Mentra: MIC: mid decision -> requestActive=\(requestActive), sensorsAllowMic=\(sensorsAllowMic), rawHeadUp=\(headUp), effectiveHeadUp=\(isHeadUpEffective), hasForegroundAppOpen=\(hasForegroundAppOpen), micActivationMode=\(micActivationMode.rawValue), micBlockedByTimeout=\(micBlockedByTimeout), shouldEnableMic=\(shouldEnableMic), micSessionActive=\(micSessionActive)"
        )

        let allowMicSession = shouldEnableMic

        Task {
            let isBackground: Bool
            #if canImport(UIKit)
                isBackground = UIApplication.shared.applicationState == .background
            #else
                isBackground = false
            #endif

            let glassesHasMic = (sgc?.hasMic ?? getGlassesHasMic()) && (sgc?.ready == true)

            // Determine if mic should be active at all
            var shouldBeActive =
                allowMicSession
                    && !(micBlockedByTimeout && micActivationMode.requiresHeadUp
                        && !hasForegroundAppOpen)

            if !shouldBeActive {
                // Ensure everything is off
                await sgc?.setMicEnabled(false)
                setOnboardMicEnabled(false)
                micSessionActive = false
                Bridge.log("Mentra: MIC: final decision -> disabled (blocked/toggled off)")
                return
            }

            // Choose audio source (favor glasses when available for stability)
            var useGlassesMic = false
            var useOnboardMic = false

            switch preferredMic {
            case .glasses:
                useGlassesMic = glassesHasMic
                useOnboardMic = !glassesHasMic && !onboardMicUnavailable
            case .phone:
                // Auto-upgrade to glasses mic if available and keep it active persistently
                if glassesHasMic {
                    preferredMic = .glasses
                    Bridge.saveSetting("preferred_mic", "glasses")
                    useGlassesMic = true
                    useOnboardMic = false
                } else {
                    useOnboardMic = !onboardMicUnavailable
                }
            }

            // iOS background: if background and phone mic requested, prefer glasses when present
            if isBackground && !useGlassesMic && glassesHasMic {
                useGlassesMic = true
                useOnboardMic = false
            }

            micSessionActive = true

            Bridge.log(
                "Mentra: MIC: final decision -> appState=\(isBackground ? "background" : "foreground"), preferred=\(preferredMic.rawValue), glassesHasMic=\(glassesHasMic), useGlassesMic=\(useGlassesMic), useOnboardMic=\(useOnboardMic), onboardMicUnavailable=\(onboardMicUnavailable)"
            )

            if sgc?.hasMic ?? false {
                await sgc?.setMicEnabled(useGlassesMic)
            }

            setOnboardMicEnabled(useOnboardMic)
        }
    }

    func setOnboardMicEnabled(_ isEnabled: Bool) {
        Task {
            if isEnabled {
                guard PhoneMic.shared.checkPermissions() else {
                    Bridge.log("Microphone permissions not granted. Cannot enable microphone.")
                    return
                }

                let success = PhoneMic.shared.startRecording()
                if !success, getGlassesHasMic() {
                    await enableGlassesMic(true)
                }
            } else {
                PhoneMic.shared.stopRecording()
            }
        }
    }

    func enableGlassesMic(_: Bool) async {
        await sgc?.setMicEnabled(true)
    }
}

// MARK: - Private helpers

private extension MentraManager {
    func normalizeRequiredData(_ requiredData: [SpeechRequiredDataType])
        -> [SpeechRequiredDataType]
    {
        var requiredData = requiredData
        if offlineModeEnabled, !requiredData.contains(.PCM_OR_TRANSCRIPTION),
           !requiredData.contains(.TRANSCRIPTION)
        {
            requiredData.append(.TRANSCRIPTION)
        }
        return requiredData
    }

    func resolveSpeechOutputs(for requiredData: [SpeechRequiredDataType])
        -> (sendPcm: Bool, sendTranscript: Bool)
    {
        var sendPcm = false
        var sendTranscript = false

        if requiredData.contains(.PCM) && requiredData.contains(.TRANSCRIPTION) {
            sendPcm = true
            sendTranscript = true
        } else if requiredData.contains(.PCM) {
            sendPcm = true
        } else if requiredData.contains(.TRANSCRIPTION) {
            sendTranscript = true
        } else if requiredData.contains(.PCM_OR_TRANSCRIPTION) {
            if enforceLocalTranscription {
                sendTranscript = true
            } else {
                sendPcm = true
            }
        }

        return (sendPcm, sendTranscript)
    }

    func checkSetVadStatus(speaking: Bool) {
        if speaking != isSpeaking {
            isSpeaking = speaking
            Bridge.sendVadStatus(isSpeaking)
        }
    }

    func emptyVadBuffer() {
        while !vadBuffer.isEmpty {
            let chunk = vadBuffer.removeFirst()
            Bridge.sendMicData(chunk)
        }
    }

    func addToVadBuffer(_ chunk: Data) {
        let maxBufferSize = 20
        vadBuffer.append(chunk)
        while vadBuffer.count > maxBufferSize {
            vadBuffer.removeFirst()
        }
    }
}

//
//  MentraManager+Head.swift
//  MentraOS_Manager
//
//  Created by Codex on 3/17/24.
//

import Foundation

extension MentraManager {
    enum HeadRecomputeReason: String {
        case headPositionChanged = "head_position_changed"
        case headUpTimeoutElapsed = "head_up_timeout_elapsed"
        case foregroundAppChanged = "foreground_app_changed"
        case timeoutCancelled = "head_up_timeout_cancelled"
        case manual
    }

    /// True when the UI/mic should treat the head as "up".
    var isHeadUpEffective: Bool {
        isHeadUp && (!micBlockedByTimeout || hasForegroundAppOpen)
    }

    /// UI-specific gating that mirrors the legacy dashboard heuristics.
    var isHeadUpEffectiveForUI: Bool {
        isHeadUp
            && !(headUpMicTimeoutEnabled && headUpMicTimeoutElapsed && !hasForegroundAppOpen)
    }

    func updateHeadUp(_ isHeadUp: Bool) {
        let previous = self.isHeadUp
        self.isHeadUp = isHeadUp

        Bridge.log("Mentra: HEAD: updateHeadUp(prev=\(previous) -> now=\(isHeadUp))")

        if isHeadUp {
            headUpMicTimeoutElapsed = false
            micBlockedByTimeout = false
            scheduleHeadUpTimeoutIfNeeded()
        } else {
            cancelHeadUpTimeout()
        }

        if previous != isHeadUp {
            recomputeMicAndUI(.headPositionChanged)
        } else {
            sendCurrentState(isHeadUpEffective)
        }

        Bridge.sendHeadUp(isHeadUp)
    }

    func setForegroundAppOpen(_ active: Bool) {
        let previous = hasForegroundAppOpen
        hasForegroundAppOpen = active

        Bridge.log(
            "Mentra: FG_APP: setForegroundAppOpen(prev=\(previous) -> now=\(active)), rawHeadUp=\(isHeadUp)"
        )

        Bridge.showBanner(
            type: "info", message: active ? "Foreground app: ON" : "Foreground app: OFF"
        )

        if active {
            // Foreground app opened: cancel any pending timeout without resetting flags.
            // This preserves "one-shot per head-up" semantics until head goes down.
            headUpMicTimeoutWorkItem?.cancel()
            headUpMicTimeoutWorkItem = nil
            Bridge.log("Mentra: HEAD: timeout canceled due to foreground app open (no reset)")
        } else {
            // Foreground app closed: do not reset elapsed/blocked. Only schedule if still eligible.
            scheduleHeadUpTimeoutIfNeeded()
        }

        recomputeMicAndUI(.foregroundAppChanged)
    }

    func scheduleHeadUpTimeoutIfNeeded() {
        headUpMicTimeoutWorkItem?.cancel()

        // Only applicable when "head_up" activation is in use and no foreground app is open
        guard isHeadUp, headUpMicTimeoutEnabled, micActivationMode.requiresHeadUp,
              !hasForegroundAppOpen
        else {
            return
        }

        // Run only once per head-up cycle; do not reschedule after it has elapsed/blocked
        guard !headUpMicTimeoutElapsed && !micBlockedByTimeout else {
            Bridge.log(
                "Mentra: HEAD: timeout already elapsed/blocked for this head-up cycle; not rescheduling"
            )
            return
        }

        let seconds = headUpMicTimeoutSeconds

        Bridge.log(
            "Mentra: HEAD: scheduling timeout in \(seconds)s (isHeadUp=\(isHeadUp), hasFG=\(hasForegroundAppOpen))"
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            guard self.isHeadUp, !self.hasForegroundAppOpen else {
                Bridge.log(
                    "Mentra: HEAD: timeout fired but conditions changed; ignoring (isHeadUp=\(self.isHeadUp), hasFG=\(self.hasForegroundAppOpen))"
                )
                return
            }

            self.headUpMicTimeoutElapsed = true
            self.micBlockedByTimeout = true
            self.micSessionActive = false
            self.headUpMicTimeoutWorkItem = nil

            Bridge.log(
                "Mentra: HEAD: timeout elapsed (\(seconds)s). micBlockedByTimeout=true; recomputing"
            )

            self.recomputeMicAndUI(.headUpTimeoutElapsed)
        }

        headUpMicTimeoutWorkItem = workItem
        sendStateQueue.asyncAfter(deadline: .now() + .seconds(seconds), execute: workItem)
    }

    func cancelHeadUpTimeout() {
        headUpMicTimeoutWorkItem?.cancel()
        headUpMicTimeoutWorkItem = nil
        headUpMicTimeoutElapsed = false
        micBlockedByTimeout = false

        Bridge.log("Mentra: HEAD: timeout canceled and elapsed cleared")
    }

    func recomputeMicAndUI(_ reason: HeadRecomputeReason) {
        Bridge.log(
            "Mentra: RECOMPUTE: reason=\(reason.rawValue), rawHeadUp=\(isHeadUp), effectiveHeadUp=\(isHeadUpEffective), hasFG=\(hasForegroundAppOpen), timeoutEnabled=\(headUpMicTimeoutEnabled), timeoutElapsed=\(headUpMicTimeoutElapsed)"
        )

        handle_microphone_state_change(currentRequiredData, bypassVadForPCM)
        sendCurrentState(isHeadUpEffective)
    }
}

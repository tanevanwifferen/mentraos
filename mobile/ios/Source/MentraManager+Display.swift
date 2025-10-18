//
//  MentraManager+Display.swift
//  MentraOS_Manager
//
//  Created by Codex on 3/17/24.
//

import Foundation

extension MentraManager {
    func clearState() {
        sendCurrentState(sgc?.isHeadUp ?? false)
    }

    func sendCurrentState(_ requestDashboard: Bool) {
        guard !isUpdatingScreen else { return }

        let effectiveHeadUpForUI = isHeadUpEffectiveForUI
        let shouldDisplayDashboard = requestDashboard && effectiveHeadUpForUI

        Bridge.log(
            "Mentra: DISPLAY: sendCurrentState(request=\(requestDashboard), effectiveHeadUpForUI=\(effectiveHeadUpForUI), rawHeadUp=\(isHeadUp), contextualDashboard=\(contextualDashboard), timeoutElapsed=\(headUpMicTimeoutElapsed), hasFG=\(hasForegroundAppOpen))"
        )

        if requestDashboard && !shouldDisplayDashboard {
            Bridge.log(
                "Mentra: DISPLAY: WARNING: dashboard requested but effective head-up is false; forcing main view"
            )
        }

        if requestDashboard && !contextualDashboard {
            Bridge.log("Mentra: DISPLAY: contextualDashboard disabled, skip dashboard")
            return
        }

        guard isRealWearableConnected else {
            Bridge.log("Mentra: DISPLAY: no real glasses connected, skipping")
            return
        }

        guard isSomethingConnected() else {
            Bridge.log("Mentra: DISPLAY: no device connection, skipping")
            return
        }

        sendStateWorkItem?.cancel()

        let viewState = shouldDisplayDashboard ? viewStates[1] : viewStates[0]
        let layout = MentraDisplayLayout(from: viewState.layoutType)

        Task {
            await render(viewState, layout: layout)
        }
    }

    func parsePlaceholders(_ text: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "M/dd, h:mm"
        let formattedDate = dateFormatter.string(from: Date())

        let time12Format = DateFormatter()
        time12Format.dateFormat = "hh:mm"
        let time12 = time12Format.string(from: Date())

        let time24Format = DateFormatter()
        time24Format.dateFormat = "HH:mm"
        let time24 = time24Format.string(from: Date())

        let dateFormat = DateFormatter()
        dateFormat.dateFormat = "MM/dd"
        let currentDate = dateFormat.string(from: Date())

        var placeholders: [String: String] = [
            "$no_datetime$": formattedDate,
            "$DATE$": currentDate,
            "$TIME12$": time12,
            "$TIME24$": time24,
        ]

        if let battery = sgc?.batteryLevel, battery >= 0 {
            placeholders["$GBATT$"] = "\(battery)%"
        } else {
            placeholders["$GBATT$"] = ""
        }

        if !glassesWifiSsid.isEmpty {
            placeholders["$GWIFI_SSID$"] = glassesWifiSsid
        }

        placeholders["$CONNECTION_STATUS$"] = "Connected"
        placeholders["$GCLOUD$"] = "$CORE_CONNECTION$"

        var parsedText = text
        for (placeholder, value) in placeholders {
            parsedText = parsedText.replacingOccurrences(of: placeholder, with: value)
        }
        return parsedText
    }

    func handle_display_text(_ params: [String: Any]) {
        guard let text = params["text"] as? String else {
            Bridge.log("Mentra: display_text missing text parameter")
            return
        }

        Bridge.log("Mentra: Displaying text: \(text)")
        sendText(text)
    }

    func handle_display_event(_ event: [String: Any]) {
        guard let view = event["view"] as? String else {
            Bridge.log("Mentra: invalid view")
            return
        }

        let isDashboard = view == "dashboard"
        let stateIndex = isDashboard ? 1 : 0

        guard let layout = event["layout"] as? [String: Any] else {
            Bridge.log("Mentra: layout payload missing")
            return
        }

        let layoutType = layout["layoutType"] as? String ?? MentraDisplayLayout.textWall.rawValue
        var text = layout["text"] as? String ?? " "
        var topText = layout["topText"] as? String ?? " "
        var bottomText = layout["bottomText"] as? String ?? " "
        var title = layout["title"] as? String ?? " "
        let data = layout["data"] as? String ?? ""

        text = parsePlaceholders(text)
        topText = parsePlaceholders(topText)
        bottomText = parsePlaceholders(bottomText)
        title = parsePlaceholders(title)

        var newViewState = ViewState(
            topText: topText,
            bottomText: bottomText,
            title: title,
            layoutType: layoutType,
            text: text,
            data: data,
            animationData: nil
        )

        if layoutType == "bitmap_animation" {
            if let frames = layout["frames"] as? [String],
               let interval = layout["interval"] as? Double
            {
                newViewState.animationData = [
                    "frames": frames,
                    "interval": interval,
                    "repeat": layout["repeat"] as? Bool ?? true,
                ]
                Bridge.log(
                    "Mentra: Parsed bitmap_animation with \(frames.count) frames, interval: \(interval)ms"
                )
            } else {
                Bridge.log("Mentra: ERROR: bitmap_animation missing frames or interval")
            }
        }

        let currentState = viewStates[stateIndex]
        let newStateKey =
            newViewState.layoutType + newViewState.text + newViewState.topText
                + newViewState.bottomText + newViewState.title + (newViewState.data ?? "")
        let currentStateKey =
            currentState.layoutType + currentState.text + currentState.topText
                + currentState.bottomText + currentState.title + (currentState.data ?? "")

        guard newStateKey != currentStateKey else {
            return
        }

        Bridge.log(
            "Updating view state \(stateIndex) with \(layoutType) \(text) \(topText) \(bottomText)"
        )

        viewStates[stateIndex] = newViewState
        sendCurrentState(isDashboard)
    }

    func clearDisplay() {
        guard let sgc else { return }

        if sgc is G1 {
            let g1 = sgc as? G1
            g1?.clearDisplay()
            g1?.sendTextWall(" ")

            if powerSavingMode {
                sendStateWorkItem?.cancel()
                Bridge.log("Mentra: Clearing display after 3 seconds")

                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    if self.isHeadUp {
                        return
                    }
                    g1?.clearDisplay()
                }
                sendStateWorkItem = workItem
                sendStateQueue.asyncAfter(deadline: .now() + 3, execute: workItem)
            }
        } else {
            sgc.clearDisplay()
        }
    }

    func sendText(_ text: String) {
        guard let sgc else { return }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearDisplay()
            return
        }

        sgc.sendTextWall(text)
    }
}

private extension MentraManager {
    var isRealWearableConnected: Bool {
        !defaultWearable.contains("Simulated") && !defaultWearable.isEmpty
    }

    @MainActor
    func render(_ viewState: ViewState, layout: MentraDisplayLayout) async {
        Bridge.log("Mentra: DISPLAY: rendering layoutType=\(layout.rawValue)")
        switch layout {
        case .textWall:
            sendText(viewState.text)
        case .doubleTextWall:
            sgc?.sendDoubleTextWall(viewState.topText, viewState.bottomText)
            sgc?.sendDoubleTextWall(viewState.topText, viewState.bottomText)
        case .referenceCard:
            sendText("\(viewState.title)\n\n\(viewState.text)")
        case .bitmap:
            guard let data = viewState.data else {
                Bridge.log("Mentra: ERROR: bitmap_view missing data field")
                return
            }
            Bridge.log("Mentra: Processing bitmap_view with base64 data, length: \(data.count)")
            await sgc?.displayBitmap(base64ImageData: data)
        case .clear:
            Bridge.log("Mentra: Processing clear_view layout - clearing display")
            clearDisplay()
        case .unknown:
            Bridge.log("Mentra: DISPLAY: unknown layout \(viewState.layoutType)")
        }
    }
}

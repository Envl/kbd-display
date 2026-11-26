import AppKit
import SwiftUI

struct KeyboardConnection: Equatable {
    struct Display: Identifiable, Equatable {
        let id: String
        let name: String
    }

    var displays: [Display] = []
    var selectedID: String?
    var hasOutput = false
    var captureFailed = false

    var waitingForDisplay: Bool {
        guard let selectedID else { return false }
        return !displays.contains { $0.id == selectedID }
    }
}

struct KeyboardSetup: View {
    let connection: KeyboardConnection
    let monitoring: Bool
    let paused: Bool
    let selectOutput: (String?) -> Void
    let requestAccess: () -> Void
    let customize: () -> Void

    var body: some View {
        Section("Connect the keyboard display") {
            Text("Connect the Action75’s display to your Mac with a video-capable cable. In Displays settings, select the keyboard screen and set “Use as” to “Extended display”.")
                .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                Link("Open Displays Settings…", destination: url)
            }
        }
        Section("Choose the keyboard screen") {
            if connection.displays.isEmpty {
                Label("No extended display available", systemImage: "display")
            }
            if !connection.displays.isEmpty || connection.selectedID != nil {
                Picker("Output", selection: Binding(get: { connection.selectedID }, set: selectOutput)) {
                    Text("Output Off").tag(String?.none)
                    if connection.waitingForDisplay {
                        Text("Saved display (disconnected)").tag(connection.selectedID)
                    }
                    ForEach(connection.displays) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                }
            }
            if connection.captureFailed {
                Text("Couldn’t start the selected display.")
                Button("Try Again") { selectOutput(connection.selectedID) }
            } else if connection.waitingForDisplay {
                Text("Reconnect the saved screen to resume output.")
            } else if connection.hasOutput {
                Label("Display connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        Section("Allow keyboard effects while typing") {
            if monitoring {
                Label("Input Monitoring is on", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("In Input Monitoring, turn on kbd-display so key presses in other apps can light up the keyboard.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Input Monitoring…", action: requestAccess)
            }
        }
        if connection.hasOutput && monitoring && !paused {
            Section("Try it") {
                Text("Press a letter and watch the matching key on the keyboard display.")
                Button("Customize Effects", action: customize)
            }
        }
    }
}

#if os(iOS)
import SwiftUI

struct DiagnosticsSettingsView: View {
    @Bindable var model: DiagnosticsViewModel
    let profile: UserProfile?

    @State private var selectedMode: DiagnosticsConsentChoice = .ask
    @State private var selectedDestination: DiagnosticsDestinationChoice = .hosted
    @State private var showAlwaysConfirmation = false
    @State private var showNeverConfirmation = false

    var body: some View {
        List {
            SettingsPageHeader(
                title: "Diagnostics",
                subtitle: "Capture, review, and securely send diagnostic reports.",
                systemImage: "stethoscope",
                tint: .orange
            )
            .settingsPageHeaderRow()

            availabilitySection
            preferencesSection
            pendingSection
            manualSection
            sentHistorySection
        }
        .settingsListChrome()
        .navigationTitle("")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .task {
            await model.load(profile: profile)
            selectedMode = model.consentMode
            selectedDestination = model.selectedDestination
        }
        .onChange(of: model.consentMode) { _, mode in
            selectedMode = mode
        }
        .onChange(of: model.selectedDestination) { _, destination in
            selectedDestination = destination
        }
    }

    private var availabilitySection: some View {
        Section {
            LabeledContent("Status", value: model.featureState.title)
            LabeledContent("Destination", value: model.destinationServerName)
        } header: {
            Text("Feature State")
        } footer: {
            if model.featureState == .offline {
                Text("Showing the last known diagnostics state. Reports stay on this device while the server is offline.")
            }
        }
        .listRowBackground(Color.siloSurfaceElevated.opacity(0.92))
    }

    private var preferencesSection: some View {
        Section {
            Picker("Send Reports To", selection: $selectedDestination) {
                Text("Silo Diagnostics").tag(DiagnosticsDestinationChoice.hosted)
                Text("My Silo Server").tag(DiagnosticsDestinationChoice.selfHosted)
            }
            .onChange(of: selectedDestination) { oldValue, newValue in
                guard oldValue != newValue, newValue != model.selectedDestination else { return }
                Task { await model.setDestination(newValue) }
            }

            Toggle("Debug Logging", isOn: $model.debugLoggingEnabled)
                .tint(.siloAccent)

            Picker("Crash Reports", selection: $selectedMode) {
                Text("Ask").tag(DiagnosticsConsentChoice.ask)
                if model.allowsAlwaysSend {
                    Text("Always").tag(DiagnosticsConsentChoice.always)
                }
                Text("Never").tag(DiagnosticsConsentChoice.never)
            }
            .disabled(!model.canChangeConsent)
            .onChange(of: selectedMode) { oldValue, newValue in
                guard oldValue != newValue, newValue != model.consentMode else { return }
                requestModeChange(newValue)
            }
            .confirmationDialog(
                "Always Send Crash Reports?",
                isPresented: $showAlwaysConfirmation,
                titleVisibility: .visible
            ) {
                Button("Always Send") {
                    Task { await model.setConsentMode(.always) }
                }
                Button("Cancel", role: .cancel, action: cancelModeChange)
            } message: {
                Text("Any pending reports and future crash or hang reports for this server account will be sent automatically. You can change this at any time.")
            }
            .alert("Turn Off Crash Reports?", isPresented: $showNeverConfirmation) {
                Button("Turn Off and Delete", role: .destructive) {
                    Task { await model.setConsentMode(.never) }
                }
                Button("Cancel", role: .cancel, action: cancelModeChange)
            } message: {
                if model.selectedDestination == .hosted {
                    Text("Pending local reports will be deleted. Reports already received by Silo Diagnostics will also be queued for deletion. The in-memory basic log will continue running and is never sent without an explicit action.")
                } else {
                    Text("Pending reports for this server account will be deleted. The in-memory basic log will continue running and is never sent without an explicit action.")
                }
            }
        } header: {
            Text("Capture")
        } footer: {
            if model.selectedDestination == .hosted {
                Text(model.hostedPrivacyDisclosure)
            } else {
                Text("Crash report consent is tied to this server account. Debug logging is a setting for this device.")
            }
        }
        .listRowBackground(Color.siloSurfaceElevated.opacity(0.92))
    }

    private var pendingSection: some View {
        Section {
            if model.pendingReports.isEmpty {
                Text("No pending reports")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.pendingReports) { report in
                    NavigationLink {
                        DiagnosticsReportDetailView(report: report, model: model)
                    } label: {
                        DiagnosticsPendingReportRow(report: report)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            Task { await model.delete(report) }
                        }
                    }
                }
            }
        } header: {
            Text("Pending Reports (\(model.pendingReports.count))")
        }
        .listRowBackground(Color.siloSurfaceElevated.opacity(0.92))
    }

    private var manualSection: some View {
        Section {
            Button("Send Diagnostics Now", systemImage: "paperplane.fill") {
                Task { await model.createAndSendManualReport() }
            }
            .disabled(!model.featureState.isUploadAvailable || model.isWorking)

            if !model.debugLoggingEnabled {
                Label(
                    "Debug logging is off. This report contains only the last few minutes of basic logs.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            if model.isWorking {
                ProgressView("Preparing diagnostics…")
            }

            if let notice = model.notice {
                Text(notice.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } footer: {
            if model.selectedDestination == .hosted {
                Text("A hosted report includes device capability details and recent redacted diagnostic logs. It omits account, profile, server address, and playback session identifiers.")
            } else {
                Text("A manual report includes device capability details, recent playback session identifiers, and recent diagnostic logs for this server.")
            }
        }
        .listRowBackground(Color.siloSurfaceElevated.opacity(0.92))
    }

    private var sentHistorySection: some View {
        Section("Sent History") {
            if model.sentHistory.isEmpty {
                Text("No reports sent yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.sentHistory) { item in
                    LabeledContent {
                        Text(item.sentAtDate ?? .distantPast, format: .dateTime.month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(item.shortID)
                            .textSelection(.enabled)
                    }
                    .contextMenu {
                        Button("Copy ID", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = item.shortID
                        }
                    }
                }
            }
        }
        .listRowBackground(Color.siloSurfaceElevated.opacity(0.92))
    }

    private func requestModeChange(_ mode: DiagnosticsConsentChoice) {
        switch mode {
        case .ask:
            Task { await model.setConsentMode(.ask) }
        case .always:
            showAlwaysConfirmation = true
        case .never:
            showNeverConfirmation = true
        }
    }

    private func cancelModeChange() {
        selectedMode = model.consentMode
    }
}

private extension DiagnosticsSentReport {
    var sentAtDate: Date? {
        DiagnosticsDates.date(from: sentAt)
    }
}
#endif

#if os(iOS)
import SwiftUI

struct DiagnosticsSettingsView: View {
    @Bindable var model: DiagnosticsViewModel
    let profile: UserProfile?

    @State private var selectedMode: DiagnosticsConsentChoice = .ask
    @State private var selectedDestination: DiagnosticsDestinationChoice = .hosted
    @State private var showAlwaysConfirmation = false
    @State private var showNeverConfirmation = false
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            availabilitySection
            preferencesSection
            pendingSection
            manualSection
            sentHistorySection
        }
        .settingsListChrome()
        .navigationTitle(Text(.settingsDiagnostics))
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
            LabeledContent {
                Text(model.featureState.title)
            } label: {
                Text(.diagnosticsRowStatus)
            }
            .accessibilityElement(children: .combine)
            LabeledContent {
                Text(model.destinationServerName)
            } label: {
                Text(.diagnosticsRowDestination)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text(.diagnosticsSectionFeatureState)
        } footer: {
            if model.featureState == .offline {
                Text(.diagnosticsAvailabilityOfflineDetail)
            }
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var preferencesSection: some View {
        Section {
            Picker(.diagnosticsRowSendReportsTo, selection: $selectedDestination) {
                Text(.diagnosticsDestinationHosted).tag(DiagnosticsDestinationChoice.hosted)
                Text(.diagnosticsDestinationMyServer).tag(DiagnosticsDestinationChoice.selfHosted)
            }
            .onChange(of: selectedDestination) { oldValue, newValue in
                guard oldValue != newValue, newValue != model.selectedDestination else { return }
                Task { await model.setDestination(newValue) }
            }

            Toggle(.diagnosticsRowDebugLogging, isOn: $model.debugLoggingEnabled)
                .tint(.siloSwitchOn)

            Picker(.diagnosticsRowCrashReports, selection: $selectedMode) {
                Text(.diagnosticsCrashReportsAsk).tag(DiagnosticsConsentChoice.ask)
                if model.allowsAlwaysSend {
                    Text(.diagnosticsCrashReportsAlways).tag(DiagnosticsConsentChoice.always)
                }
                Text(.diagnosticsCrashReportsNever).tag(DiagnosticsConsentChoice.never)
            }
            .disabled(!model.canChangeConsent)
            .onChange(of: selectedMode) { oldValue, newValue in
                guard oldValue != newValue, newValue != model.consentMode else { return }
                requestModeChange(newValue)
            }
            .confirmationDialog(
                Text(.diagnosticsAlwaysSendConfirmTitle),
                isPresented: $showAlwaysConfirmation,
                titleVisibility: .visible
            ) {
                Button(.diagnosticsAlwaysSendConfirm) {
                    Task { await model.setConsentMode(.always) }
                }
                Button(.commonCancel, role: .cancel, action: cancelModeChange)
            } message: {
                Text(.diagnosticsAlwaysSendSettingsMessage)
            }
            .alert(Text(.diagnosticsTurnOffTitle), isPresented: $showNeverConfirmation) {
                Button(.diagnosticsTurnOffConfirm, role: .destructive) {
                    Task { await model.setConsentMode(.never) }
                }
                Button(.commonCancel, role: .cancel, action: cancelModeChange)
            } message: {
                if model.selectedDestination == .hosted {
                    Text(.diagnosticsTurnOffHostedMessage)
                } else {
                    Text(.diagnosticsTurnOffSelfHostedMessage)
                }
            }
        } header: {
            Text(.diagnosticsSectionCapture)
        } footer: {
            if model.selectedDestination == .hosted {
                Text(model.hostedPrivacyDisclosure)
            } else {
                Text(.diagnosticsCaptureSelfHostedFooter)
            }
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var pendingSection: some View {
        Section {
            if model.pendingReports.isEmpty {
                Text(.diagnosticsPendingNone)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.pendingReports) { report in
                    NavigationLink {
                        DiagnosticsReportDetailView(report: report, model: model)
                    } label: {
                        DiagnosticsPendingReportRow(report: report)
                    }
                    .swipeActions {
                        Button(.diagnosticsEraseConfirm, role: .destructive) {
                            Task { await model.delete(report) }
                        }
                    }
                }
            }
        } header: {
            Text(.diagnosticsSectionPending(model.pendingReports.count))
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var manualSection: some View {
        Section {
            Button(.settingsDiagnosticsSend, systemImage: "paperplane.fill") {
                Task { await model.createAndSendManualReport() }
            }
            .disabled(!model.featureState.isUploadAvailable || model.isWorking)

            if !model.debugLoggingEnabled {
                Label(
                    .diagnosticsSendDebugOffFooterTv,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            if model.isWorking {
                ProgressView {
                    Text(.diagnosticsPreparing)
                }
            }

            if let notice = model.notice {
                Text(verbatim: notice.text(in: locale))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } footer: {
            if model.selectedDestination == .hosted {
                Text(.diagnosticsManualHostedFooter)
            } else {
                Text(.diagnosticsManualSelfHostedFooter)
            }
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var sentHistorySection: some View {
        Section {
            if model.sentHistory.isEmpty {
                Text(.diagnosticsSentHistoryNone)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.sentHistory) { item in
                    LabeledContent {
                        Text(item.sentAtDate ?? .distantPast, format: .dateTime.month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(verbatim: item.shortID)
                            .textSelection(.enabled)
                    }
                    .contextMenu {
                        Button(.diagnosticsCopyId, systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = item.shortID
                        }
                    }
                }
            }
        } header: {
            Text(.diagnosticsSectionSentHistory)
        }
        .listRowBackground(Color.siloGroupedCell)
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

#if os(tvOS)
import SwiftUI

struct TVDiagnosticsSettingsPane: View {
    @Bindable var model: DiagnosticsViewModel
    let detailFocus: FocusState<TVSettingsDetailFocus?>.Binding

    @State private var showConsentPicker = false
    @State private var showDestinationPicker = false
    @State private var selectedReport: PendingReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TVSettingsSectionHeader("FEATURE STATE")
            TVSettingsInfoRow(title: "Status", value: model.featureState.title)
            TVSettingsInfoRow(title: "Destination", value: model.destinationServerName)

            TVSettingsSectionHeader("CAPTURE")
            TVSettingsPickerRow(
                title: "Send Reports To",
                value: model.selectedDestination.title,
                action: { showDestinationPicker = true }
            )
            .focused(detailFocus, equals: .top)

            TVSettingsToggleRow(
                title: "Debug Logging",
                isOn: model.debugLoggingEnabled
            ) {
                model.debugLoggingEnabled.toggle()
            }

            TVSettingsPickerRow(
                title: "Crash Reports",
                value: modeTitle,
                action: { showConsentPicker = true }
            )
            .disabled(!model.canChangeConsent)

            if model.selectedDestination == .hosted {
                TVSettingsFooter(model.hostedPrivacyDisclosure)
            } else {
                TVSettingsFooter("Crash report consent is tied to this server account. Debug logging is a setting for this Apple TV.")
            }

            TVSettingsSectionHeader("PENDING REPORTS (\(model.pendingReports.count))")
            if model.pendingReports.isEmpty {
                TVSettingsInfoRow(title: "Reports", value: "None")
            } else {
                ForEach(model.pendingReports) { report in
                    Button {
                        selectedReport = report
                    } label: {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(typeTitle(for: report.binding.type))
                                    .font(.system(size: 26))
                                Text(report.binding.capturedAtDate, format: .dateTime.month().day().hour().minute())
                                    .font(.system(size: 19))
                                    .opacity(0.62)
                            }
                            Spacer(minLength: 16)
                            Text("Expires \(expiryDate(for: report), format: .relative(presentation: .named))")
                                .font(.system(size: 20))
                                .opacity(0.62)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 18, weight: .semibold))
                                .opacity(0.55)
                        }
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                }
            }

            TVSettingsSectionHeader("MANUAL REPORT")
            Button("Send Diagnostics Now", systemImage: "paperplane.fill") {
                Task { await model.createAndSendManualReport() }
            }
            .buttonStyle(TVSettingsPaneRowStyle())
            .disabled(!model.featureState.isUploadAvailable || model.isWorking)

            if !model.debugLoggingEnabled {
                TVSettingsFooter("Debug logging is off. This report contains only the last few minutes of basic logs.")
            }

            if model.isWorking {
                ProgressView("Preparing diagnostics…")
                    .padding(.horizontal, 24)
            }

            if let notice = model.notice {
                TVSettingsFooter(notice.message)
            }

            TVSettingsSectionHeader("SENT HISTORY")
            if model.sentHistory.isEmpty {
                TVSettingsInfoRow(title: "Reports", value: "None")
            } else {
                ForEach(model.sentHistory) { item in
                    TVSettingsInfoRow(title: item.shortID, value: sentDate(item.sentAt))
                }
            }
        }
        .fullScreenCover(isPresented: $showConsentPicker) {
            TVDiagnosticsConsentScreen(model: model)
        }
        .fullScreenCover(isPresented: $showDestinationPicker) {
            TVDiagnosticsDestinationScreen(model: model)
        }
        .fullScreenCover(item: $selectedReport) { report in
            TVDiagnosticsPendingReportScreen(report: report, model: model)
        }
    }

    private var modeTitle: String {
        switch model.consentMode {
        case .ask: return "Ask"
        case .always: return "Always"
        case .never: return "Never"
        }
    }

    private func typeTitle(for type: ReportType) -> String {
        switch type {
        case .crash, .nativeCrash: return "Crash"
        case .hang, .anr: return "Not Responding"
        case .abnormalExit: return "Unclean Shutdown"
        case .manual: return "Manual Report"
        }
    }

    private func expiryDate(for report: PendingReport) -> Date {
        report.binding.capturedAtDate.addingTimeInterval(PendingReportStore.expiryInterval)
    }

    private func sentDate(_ value: String) -> String {
        guard let date = DiagnosticsDates.date(from: value) else { return "Sent" }
        return date.formatted(.dateTime.month().day().hour().minute())
    }
}
#endif

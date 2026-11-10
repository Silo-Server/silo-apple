#if os(tvOS)
import SwiftUI

struct TVDiagnosticsSettingsPane: View {
    @Bindable var model: DiagnosticsViewModel
    let detailFocus: FocusState<TVSettingsDetailFocus?>.Binding

    @State private var showConsentPicker = false
    @State private var showDestinationPicker = false
    @State private var selectedReport: PendingReport?
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TVSettingsSectionHeader(.diagnosticsSectionFeatureStateTv)
            TVSettingsInfoRow(title: .diagnosticsRowStatus, value: model.featureState.title)
            TVSettingsInfoRow(title: .diagnosticsRowDestination, value: model.destinationServerName)

            TVSettingsSectionHeader(.diagnosticsSectionCaptureTv)
            TVSettingsPickerRow(
                title: .diagnosticsRowSendReportsTo,
                value: model.selectedDestination.title,
                action: { showDestinationPicker = true }
            )
            .focused(detailFocus, equals: .top)

            TVSettingsToggleRow(
                title: .diagnosticsRowDebugLogging,
                isOn: model.debugLoggingEnabled
            ) {
                model.debugLoggingEnabled.toggle()
            }

            TVSettingsPickerRow(
                title: .diagnosticsRowCrashReports,
                value: modeTitle,
                action: { showConsentPicker = true }
            )
            .disabled(!model.canChangeConsent)

            if model.selectedDestination == .hosted {
                TVSettingsFooter(model.hostedPrivacyDisclosure)
            } else {
                TVSettingsFooter(.diagnosticsCaptureSelfHostedFooterAppleTv)
            }

            TVSettingsSectionHeader(.diagnosticsSectionPendingTv(model.pendingReports.count))
            if model.pendingReports.isEmpty {
                TVSettingsInfoRow(title: .diagnosticsRowReports, value: .settingsDiagnosticsNone)
            } else {
                ForEach(model.pendingReports) { report in
                    Button {
                        selectedReport = report
                    } label: {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(report.binding.type.listTitle)
                                    .font(.system(size: 26))
                                Text(report.binding.capturedAtDate, format: .dateTime.month().day().hour().minute())
                                    .font(.system(size: 19))
                                    .opacity(0.62)
                            }
                            Spacer(minLength: 16)
                            Text(.diagnosticsReportExpiresRelative(
                                expiryDate(for: report).formatted(.relative(presentation: .named).locale(locale))
                            ))
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

            TVSettingsSectionHeader(.diagnosticsSectionManualReportTv)
            Button(.settingsDiagnosticsSend, systemImage: "paperplane.fill") {
                Task { await model.createAndSendManualReport() }
            }
            .buttonStyle(TVSettingsPaneRowStyle())
            .disabled(!model.featureState.isUploadAvailable || model.isWorking)

            if !model.debugLoggingEnabled {
                TVSettingsFooter(.diagnosticsSendDebugOffFooterTv)
            }

            if model.isWorking {
                ProgressView {
                    Text(.diagnosticsPreparing)
                }
                    .padding(.horizontal, 24)
            }

            if let notice = model.notice {
                TVSettingsFooter(.verbatim(notice.text(in: locale)))
            }

            TVSettingsSectionHeader(.diagnosticsSectionSentHistoryTv)
            if model.sentHistory.isEmpty {
                TVSettingsInfoRow(title: .diagnosticsRowReports, value: .settingsDiagnosticsNone)
            } else {
                ForEach(model.sentHistory) { item in
                    TVSettingsInfoRow(title: .verbatim(item.shortID), value: sentDate(item.sentAt))
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

    private var modeTitle: LocalizedStringResource {
        switch model.consentMode {
        case .ask: return .diagnosticsCrashReportsAsk
        case .always: return .diagnosticsCrashReportsAlways
        case .never: return .diagnosticsCrashReportsNever
        }
    }

    private func expiryDate(for report: PendingReport) -> Date {
        report.binding.capturedAtDate.addingTimeInterval(PendingReportStore.expiryInterval)
    }

    private func sentDate(_ value: String) -> LocalizedStringResource {
        guard let date = DiagnosticsDates.date(from: value) else { return .diagnosticsSentHistorySentFallback }
        return .verbatim(date.formatted(.dateTime.month().day().hour().minute().locale(locale)))
    }
}
#endif

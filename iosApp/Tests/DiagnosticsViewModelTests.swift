import XCTest
@testable import Silo

@MainActor
final class DiagnosticsViewModelTests: XCTestCase {
    func testOutOfOrderDestinationRefreshCannotPublishStaleState() async throws {
        let suiteName = "diagnostics-view-model-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let destinationStore = DiagnosticsDestinationStore(defaults: defaults)
        destinationStore.select(.hosted)
        let consentStore = DiagnosticsConsentStore(
            defaults: defaults,
            onNeverSelected: { _ in }
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DiagnosticsViewModel-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let pendingStore = PendingReportStore(rootDirectory: root)
        let coordinator = DiagnosticsCoordinator(
            consentStore: consentStore,
            destinationStore: destinationStore,
            pendingStore: pendingStore
        )
        let provider = ControlledStatusProvider(
            hosted: makeSnapshot(destination: .hosted, status: .disabled),
            selfHosted: makeSnapshot(destination: .selfHosted, status: .available)
        )
        let model = DiagnosticsViewModel(
            coordinator: coordinator,
            consentStore: consentStore,
            pendingStore: pendingStore,
            destinationStore: destinationStore,
            statusRefresher: { destination in
                await provider.status(for: destination)
            },
            cachedStatusProvider: { _ in nil }
        )
        defer { DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(nil) }

        let slowRefresh = Task { await model.setDestination(.selfHosted) }
        await provider.waitForSelfHostedRequest()

        await model.setDestination(.hosted)
        XCTAssertEqual(model.selectedDestination, .hosted)
        XCTAssertEqual(model.featureState, .disabledByServer)

        provider.resumeSelfHostedRequest()
        await slowRefresh.value

        XCTAssertEqual(model.selectedDestination, .hosted)
        XCTAssertEqual(model.featureState, .disabledByServer)
        XCTAssertEqual(model.consentMode, .ask)
    }

    func testDestinationChangeImmediatelyClosesPreviousCaptureContext() {
        let binding = DiagnosticsBinding(
            serverInstanceID: "previous-destination",
            accountUserID: "account"
        )
        DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(
            DiagnosticsCoordinator.BreadcrumbConsentContext(
                binding: binding,
                noticeVersion: 1
            )
        )
        defer { DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(nil) }

        XCTAssertEqual(DiagnosticsCoordinator.currentDiagnosticsBinding, binding)

        DiagnosticsCoordinator.diagnosticsDestinationWillChange()

        XCTAssertNil(DiagnosticsCoordinator.currentDiagnosticsBinding)
    }

    private func makeSnapshot(
        destination: DiagnosticsDestinationChoice,
        status: DiagnosticsAvailabilityStatus
    ) -> DiagnosticsStatusSnapshot {
        let response = DiagnosticsStatusResponse(
            status: status,
            serverInstanceId: destination == .hosted
                ? HostedDiagnosticsCapabilities.pinnedCollectorID
                : "self-hosted-instance",
            acceptedSchemaVersions: [1],
            maxBundleBytes: 1_048_576,
            maxManifestBytes: 65_536,
            retentionDays: 30,
            consentNoticeVersion: 1,
            uploadChunkBytes: nil
        )
        let binding = destination == .hosted
            ? DiagnosticsBinding.hosted(serverRegistryID: "server", accountUserID: "account")
            : DiagnosticsBinding(serverInstanceID: "self-hosted-instance", accountUserID: "account")
        return DiagnosticsStatusSnapshot(status: response, binding: binding)
    }

    @MainActor
    private final class ControlledStatusProvider {
        private let hosted: DiagnosticsStatusSnapshot
        private let selfHosted: DiagnosticsStatusSnapshot
        private var selfHostedRequested = false
        private var requestWaiters: [CheckedContinuation<Void, Never>] = []
        private var selfHostedContinuation: CheckedContinuation<DiagnosticsStatusSnapshot, Never>?

        init(hosted: DiagnosticsStatusSnapshot, selfHosted: DiagnosticsStatusSnapshot) {
            self.hosted = hosted
            self.selfHosted = selfHosted
        }

        func status(for destination: DiagnosticsDestinationChoice) async -> DiagnosticsStatusSnapshot {
            guard destination == .selfHosted else { return hosted }
            selfHostedRequested = true
            requestWaiters.forEach { $0.resume() }
            requestWaiters.removeAll()
            return await withCheckedContinuation { continuation in
                selfHostedContinuation = continuation
            }
        }

        func waitForSelfHostedRequest() async {
            guard !selfHostedRequested else { return }
            await withCheckedContinuation { continuation in
                requestWaiters.append(continuation)
            }
        }

        func resumeSelfHostedRequest() {
            selfHostedContinuation?.resume(returning: selfHosted)
            selfHostedContinuation = nil
        }
    }
}

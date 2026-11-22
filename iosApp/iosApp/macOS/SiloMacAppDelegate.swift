#if os(macOS)
import AppKit

/// Holds a quit for the playing plan's summary. Players end their plans as
/// the app is asked to quit, and the app waits up to
/// ``PlanSummaryJournal/quitWait`` for the summaries on their way. One that
/// doesn't make it is kept on the device and sent at the next launch.
@MainActor
final class SiloMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NotificationCenter.default.post(name: PlanSummaryJournal.appWillQuit, object: nil)
        let journal = PlanSummaryJournal.shared
        guard journal.hasWorkInFlight else { return .terminateNow }
        Task {
            await journal.waitForWork(upTo: PlanSummaryJournal.quitWait)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif

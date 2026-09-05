import Foundation

/// Maps a failed "Check again" on the needs-setup screen to the text shown
/// under the button. Shared by the iOS and tvOS views so both tell the user
/// the server needs an update instead of claiming it could not be reached:
/// `AuthService.checkServer` rethrows `APIv2Error.serverUpdateRequired` for a
/// server that first answered needs-setup and later answered v1-only, and the
/// Home pill is not visible while the user is still on the setup screen.
enum ServerNeedsSetupMessage {
    /// `unreachable` is the view's own generic text, used for every error
    /// other than a v1-only verdict.
    static func forError(_ error: Error, unreachable: String) -> String {
        if case APIv2Error.serverUpdateRequired = error {
            return APIv2Error.serverUpdateRequiredMessage
        }
        return unreachable
    }
}

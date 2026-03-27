import Foundation
import Testing
@testable import DeskBar

struct PermissionsManagerTests {
    @Test
    func accessibilitySettingsURLsPreferModernSystemSettingsLink() {
        #expect(
            PermissionsManager.accessibilitySettingsURLs.map(\.absoluteString) == [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ]
        )
    }
}

#if !os(tvOS)
import SwiftUI

#if os(macOS)
/// A settings switch with its label on the leading side and the switch on
/// the trailing side, the same shape as a pop-up row. The Mac's default
/// checkbox made toggle rows shorter than the rows around them.
private struct MacSettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            Button {
                configuration.isOn.toggle()
            } label: {
                MacSettingsSwitch(isOn: configuration.isOn)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
        } label: {
            configuration.label
        }
        // One named switch for assistive technology, as the system toggle
        // is: the drawn capsule has no name of its own.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A monochrome switch: white with a dark knob when on, a dim track with a
/// light knob when off. The system switch is green when on, which was the
/// only colour on the Mac's settings pages, and a white tint on it hides
/// its white knob.
private struct MacSettingsSwitch: View {
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = SiloTheme.macSettingsSwitchSize
        let knob = size.height - 4
        Capsule()
            .fill(isOn ? Color.siloPrimary : Color.white.opacity(0.16))
            .frame(width: size.width, height: size.height)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? Color.siloPageCanvas : Color.white.opacity(0.85))
                    .frame(width: knob, height: knob)
                    .padding(2)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
            .animation(reduceMotion ? nil : .easeOut(duration: SiloTheme.fastDuration), value: isOn)
    }
}
#endif

extension View {
    func settingsListChrome() -> some View {
        #if os(macOS)
        // A desktop window is far wider than a settings row needs: an
        // unconstrained list puts each label and its control at opposite
        // edges. Keep settings in a centred column, and give forms the
        // grouped style so their rows lay out as labelled cards.
        // The list itself is narrowed: a Mac list ignores content margins,
        // so insetting only its content is not an option.
        siloGroupedListStyle()
            .formStyle(.grouped)
            .toggleStyle(MacSettingsToggleStyle())
            .siloScrollContentBackgroundHidden()
            .frame(maxWidth: SiloTheme.macSettingsColumnWidth)
            .frame(maxWidth: .infinity)
            .background(SettingsBackdrop())
        #else
        siloGroupedListStyle()
            .siloScrollContentBackgroundHidden()
            .background(SettingsBackdrop())
        #endif
    }

    /// Settings pickers open as a menu on macOS and push a choice list on iOS.
    func settingsPickerStyle() -> some View {
        #if os(macOS)
        return pickerStyle(.menu)
        #else
        return pickerStyle(.navigationLink)
        #endif
    }
}
#endif

import AppKit
import BangsCore
import ServiceManagement
import SwiftUI

/// A pane's coloured icon, as in System Settings.
private struct PaneIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(pane.color.gradient)
            .overlay(Image(systemName: pane.symbol).font(.system(size: size * 0.55, weight: .medium)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

/// The settings window's sidebar, one row a pane.
struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel
    /// Observed for the sidebar's badge.
    @ObservedObject var updater: Updater

    var body: some View {
        List(selection: Binding(get: { model.pane }, set: { if let pane = $0 { model.pane = pane } })) {
            ForEach(Array(SettingsPane.groups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group.panes) { pane in
                        HStack(spacing: 8) {
                            PaneIcon(pane: pane)
                            Text(pane.title)
                        }
                        .badge(badge(pane))
                        .tag(pane)
                    }
                } header: {
                    if let title = group.title { Text(title) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Hooks a newer Bangs needs to rewrite, and whether a newer Bangs is out.
    private func badge(_ pane: SettingsPane) -> Text? {
        switch pane {
        case .agents:
            let outdated = model.rows.filter { $0.state == .outdated }.count
            return outdated > 0 ? Text("\(outdated)").foregroundStyle(.orange) : nil
        case .about:
            if case .available = updater.state { return Text("新").foregroundStyle(Color.accentColor) }
            return nil
        default:
            return nil
        }
    }
}

/// The pane chosen in the sidebar.
struct SettingsDetail: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences
    let toolbox: Toolbox

    var body: some View {
        Group {
            switch model.pane {
            case .general: GeneralPane(model: model, preferences: preferences)
            case .agents: AgentsPane(model: model, preferences: preferences, history: toolbox.history)
            case .files: FilesPane(model: model, preferences: preferences, search: toolbox.files)
            case .clipboard: ClipboardPane(model: model, preferences: preferences, toolbox: toolbox)
            case .screenshot: ScreenshotPane(model: model, preferences: preferences)
            case .translate: TranslatePane(model: model, preferences: preferences, translator: toolbox.translator)
            case .focus: FocusPane(model: model, preferences: preferences, timer: toolbox.focus)
            case .calendar: CalendarPane(model: model, preferences: preferences, agenda: toolbox.agenda)
            case .shelf: ShelfPane(model: model, preferences: preferences)
            case .battery: BatteryPane(model: model, preferences: preferences, charge: toolbox.charge)
            case .shortcuts: ShortcutsPane(model: model, preferences: preferences)
            case .permissions: PermissionsPane(model: model, agenda: toolbox.agenda, files: toolbox.files)
            case .about: AboutPane(updater: toolbox.updater, preferences: preferences)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A grouped form, the error (if any) at its foot.
struct Pane<Content: View>: View {
    @ObservedObject var model: SettingsModel
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.system(size: 12))
            }
        }
        .formStyle(.grouped)
    }
}

/// A grey second line under a control's label.
func note(_ text: String) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
}

/// A section's footer, read left to right like the rows above it.
func footer(_ text: String) -> some View {
    note(text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
}

/// The top of a tool page: what the tool is, and whether its tab shows in the island.
struct Hero: View {
    let pane: SettingsPane
    @ObservedObject var preferences: Preferences

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                PaneIcon(pane: pane, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pane.title).font(.system(size: 15, weight: .semibold))
                    if let summary = pane.summary {
                        Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let tool = pane.tool {
                    Text("在刘海里显示").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                    Toggle("在刘海里显示", isOn: Binding(get: { preferences.shows(tool) }, set: { preferences.setShows(tool, $0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// A missing permission, said where it matters, with the way to grant it.
struct PermissionBanner: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(text).font(.system(size: 12))
                Spacer()
                Button("允许…", action: action)
            }
        }
    }
}

/// The shortcuts of one tool, recorded in place; the Shortcuts page shows the same ones.
struct ShortcutRows: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences
    let tool: Tool?
    var footnote: String?
    /// These shortcuts instead of the tool's.
    var only: [ShortcutAction]?

    var body: some View {
        Section {
            ForEach(only ?? ShortcutAction.allCases.filter { $0.tool == tool }, id: \.self) { action in
                LabeledContent(action.title) {
                    ShortcutRecorder(preferences: preferences, action: action, taken: model.takenShortcuts.contains(action))
                }
            }
        } header: {
            Text("快捷键")
        } footer: {
            if let footnote { footer(footnote) }
        }
    }
}

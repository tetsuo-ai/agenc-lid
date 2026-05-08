import AppKit
import Foundation
import QuartzCore

// MARK: - Brand

private enum Brand {
    static let appName = "agenc-lid"

    // Surface colors (match design/agenc-lid-v2-mockups.svg gradient stops)
    static let void = NSColor(hex: 0x090B10)
    static let panelTopOff = NSColor(hex: 0x101116)
    static let panelMidOff = NSColor(hex: 0x151725)
    static let panelBotOff = NSColor(hex: 0x241A2F)
    static let panelTopOn = NSColor(hex: 0x101116)
    static let panelMidOn = NSColor(hex: 0x10241B)
    static let panelBotOn = NSColor(hex: 0x153B2A)

    // Text
    static let text = NSColor(hex: 0xF8F7FF)
    static let textMid = NSColor(white: 1.0, alpha: 0.74)
    static let textMuted = NSColor(white: 1.0, alpha: 0.62)
    static let textFaint = NSColor(white: 1.0, alpha: 0.50)
    static let textGhost = NSColor(white: 1.0, alpha: 0.46)

    // Lines
    static let stroke = NSColor(white: 1.0, alpha: 0.14)
    static let strokeSoft = NSColor(white: 1.0, alpha: 0.10)
    static let strokeRow = NSColor(white: 1.0, alpha: 0.12)
    static let rowFill = NSColor(white: 1.0, alpha: 0.045)

    // Accents
    static let orange = NSColor(hex: 0xF97316)
    static let purple = NSColor(hex: 0x8956C2)
    static let danger = NSColor(hex: 0xFF6A2F)
    static let safe = NSColor(hex: 0x76E4A6)

    static func display(_ size: CGFloat, weight: NSFont.Weight = .bold) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255.0,
            green: CGFloat((hex >> 8) & 0xff) / 255.0,
            blue: CGFloat(hex & 0xff) / 255.0,
            alpha: alpha
        )
    }
}

// MARK: - Domain models

private enum SleepDisabledState: Equatable {
    case enabled
    case disabled
    case unknown(String)

    var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }
}

private struct PowerInfo {
    let source: String
    let batteryPercent: Int?

    var isBattery: Bool {
        source.localizedCaseInsensitiveContains("Battery")
    }

    var displayText: String {
        if let batteryPercent {
            return "\(source) \(batteryPercent)%"
        }
        return source
    }
}

private struct CommandResult {
    let status: Int32
    let output: String
    let error: String
}

private struct PmsetSetting {
    let key: String
    let value: String
    let note: String?

    var displayName: String {
        switch key {
        case "SleepDisabled": return "Lid sleep override"
        case "sleep": return "System sleep timer"
        case "displaysleep": return "Display sleep"
        default: return key
        }
    }

    var prettyValue: String {
        if key == "SleepDisabled" {
            return value == "1" ? "ON" : "OFF"
        }
        if ["sleep", "displaysleep", "disksleep"].contains(key), let minutes = Int(value) {
            return minutes == 0 ? "NEVER" : "\(minutes)m"
        }
        if value == "1" { return "ON" }
        if value == "0" { return "OFF" }
        return value.uppercased()
    }
}

// MARK: - Power manager (unchanged behaviour)

private final class PowerManager {
    private let tokenFile = "/var/tmp/com.agenc.lid.timer-token"

    func readSleepDisabledState() -> SleepDisabledState {
        let result = run("/usr/bin/pmset", arguments: ["-g"])
        guard result.status == 0 else {
            return .unknown(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let setting = parsePmsetSettings(result.output).first(where: { $0.key == "SleepDisabled" }) {
            return setting.value == "1" ? .enabled : .disabled
        }

        return .disabled
    }

    func readPowerInfo() -> PowerInfo {
        let result = run("/usr/bin/pmset", arguments: ["-g", "ps"])
        guard result.status == 0 else {
            return PowerInfo(source: "Power unknown", batteryPercent: nil)
        }

        let lines = result.output.components(separatedBy: .newlines)
        let firstLine = lines.first ?? ""
        let source: String
        if firstLine.localizedCaseInsensitiveContains("Battery Power") {
            source = "Battery"
        } else if firstLine.localizedCaseInsensitiveContains("AC Power") {
            source = "Power adapter"
        } else {
            source = "Power unknown"
        }

        let percent = lines.compactMap { line -> Int? in
            guard let percentRange = line.range(of: #"(\d+)%"#, options: .regularExpression) else {
                return nil
            }
            return Int(line[percentRange].dropLast())
        }.first

        return PowerInfo(source: source, batteryPercent: percent)
    }

    func readPmsetSettings() -> [PmsetSetting] {
        let result = run("/usr/bin/pmset", arguments: ["-g"])
        guard result.status == 0 else {
            return [PmsetSetting(key: "pmset", value: "error", note: result.error)]
        }
        return parsePmsetSettings(result.output)
    }

    func readPmsetRaw() -> String {
        let result = run("/usr/bin/pmset", arguments: ["-g"])
        guard result.status == 0 else {
            return result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func enableIndefinitely() throws {
        try runAuthorized("/bin/rm -f \(shellQuote(tokenFile)); /usr/bin/pmset -a disablesleep 1")
    }

    func enable(for seconds: Int) throws {
        let token = UUID().uuidString
        let timerScript = [
            "/bin/sleep \(seconds)",
            "if [ \"$(/bin/cat \(shellQuote(tokenFile)) 2>/dev/null)\" = \(shellQuote(token)) ]; then /usr/bin/pmset -a disablesleep 0; /bin/rm -f \(shellQuote(tokenFile)); fi"
        ].joined(separator: "; ")

        let command = [
            "/bin/echo \(shellQuote(token)) > \(shellQuote(tokenFile))",
            "/usr/bin/pmset -a disablesleep 1",
            "/usr/bin/nohup /bin/sh -c \(shellQuote(timerScript)) >/dev/null 2>&1 &"
        ].joined(separator: "; ")

        try runAuthorized(command)
    }

    func disable() throws {
        try runAuthorized("/bin/rm -f \(shellQuote(tokenFile)); /usr/bin/pmset -a disablesleep 0")
    }

    private func parsePmsetSettings(_ output: String) -> [PmsetSetting] {
        var settings: [PmsetSetting] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed != "System-wide power settings:" else { continue }
            guard trimmed != "Currently in use:" else { continue }

            let pair = splitPmsetLine(trimmed)
            guard !pair.key.isEmpty, !pair.value.isEmpty else { continue }

            let parsed = splitValueAndNote(pair.value)
            settings.append(PmsetSetting(key: pair.key, value: parsed.value, note: parsed.note))
        }

        if !settings.contains(where: { $0.key == "SleepDisabled" }) {
            settings.insert(PmsetSetting(key: "SleepDisabled", value: "0", note: "Not present in pmset output"), at: 0)
        }

        return settings
    }

    private func splitPmsetLine(_ line: String) -> (key: String, value: String) {
        if let range = line.range(of: #"\s{2,}"#, options: .regularExpression) {
            let key = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (key, value)
        }

        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return (line, "") }
        let valueStart = parts.index(before: parts.endIndex)
        return (parts[..<valueStart].joined(separator: " "), String(parts[valueStart]))
    }

    private func splitValueAndNote(_ text: String) -> (value: String, note: String?) {
        guard let noteStart = text.firstIndex(of: "(") else {
            return (text.trimmingCharacters(in: .whitespaces), nil)
        }

        let value = String(text[..<noteStart]).trimmingCharacters(in: .whitespaces)
        let note = String(text[noteStart...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        return (value, note.isEmpty ? nil : note)
    }

    private func run(_ executable: String, arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(status: 1, output: "", error: error.localizedDescription)
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, output: output, error: error)
    }

    private func runAuthorized(_ shellCommand: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \(appleScriptQuote(shellCommand)) with administrator privileges"
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let trimmed = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "agenc-lid.PowerManager",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: trimmed.isEmpty ? "The privileged command was cancelled or failed." : trimmed]
            )
        }
    }

    private func appleScriptQuote(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

// MARK: - App delegate

private protocol ControlPanelActions: AnyObject {
    func enableIndefinitely()
    func enableOneHour()
    func enableFourHours()
    func disableNow()
    func quit()
}

private final class AppDelegate: NSObject, NSApplicationDelegate, ControlPanelActions {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let powerManager = PowerManager()
    private let popover = NSPopover()
    private let panelController = ControlPanelViewController()
    private var refreshTimer: Timer?
    private var state: SleepDisabledState = .unknown("Not checked yet")
    private var powerInfo = PowerInfo(source: "Power unknown", batteryPercent: nil)
    private var settings: [PmsetSetting] = []
    private var rawPmset: String = ""
    private var activeSessionLabel: String?

    private var isPreviewMode: Bool {
        ProcessInfo.processInfo.environment["AGENC_LID_SHOW_PANEL"] == "1"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panelController.actions = self
        panelController.onPreferredSizeChange = { [weak self] size in
            self?.popover.contentSize = size
        }
        configurePopover()
        configureStatusButton()
        refreshStatus()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        if isPreviewMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showPopover()
                if ProcessInfo.processInfo.environment["AGENC_LID_PREVIEW_VIEW"]?.lowercased() == "details" {
                    self?.panelController.showDetailsForPreview()
                    self?.popover.contentSize = self?.panelController.preferredContentSize ?? NSSize(width: 360, height: 460)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 460)
        popover.contentViewController = panelController
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popoverDidClose),
            name: NSPopover.didCloseNotification,
            object: popover
        )
    }

    @objc private func popoverDidClose() {
        // Cancel any in-flight animations on the panel content. Without this,
        // an animation interrupted mid-flight can leave subviews stuck at
        // alphaValue = 0 the next time the popover opens.
        panelController.cancelAllAnimations()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.imagePosition = .imageOnly
        button.toolTip = Brand.appName
        updateStatusIcon()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        refreshStatus()
        popover.contentSize = panelController.preferredContentSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func workspaceDidWake() {
        refreshStatus()
    }

    func enableIndefinitely() {
        guard confirmEnable(message: "Keep this Mac awake until you turn it off?") else { return }
        activeSessionLabel = "Until reset"
        performPrivilegedChange {
            try powerManager.enableIndefinitely()
        }
    }

    func enableOneHour() {
        guard confirmEnable(message: "Keep this Mac awake for 1 hour?") else { return }
        activeSessionLabel = "1 hour"
        performPrivilegedChange {
            try powerManager.enable(for: 60 * 60)
        }
    }

    func enableFourHours() {
        guard confirmEnable(message: "Keep this Mac awake for 4 hours?") else { return }
        activeSessionLabel = "4 hours"
        performPrivilegedChange {
            try powerManager.enable(for: 4 * 60 * 60)
        }
    }

    func disableNow() {
        refreshStatus()
        guard state != .disabled else { return }

        performPrivilegedChange {
            try powerManager.disable()
        }
        activeSessionLabel = nil
    }

    func quit() {
        refreshStatus()

        guard state.isEnabled else {
            NSApp.terminate(nil)
            return
        }

        let alert = themedAlert()
        alert.messageText = "agenc-lid is still on"
        alert.informativeText = "Lid sleep is disabled. Turn it off before quitting unless you intentionally want it to stay active."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Turn Off and Quit")
        alert.addButton(withTitle: "Quit Leaving On")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                try powerManager.disable()
                NSApp.terminate(nil)
            } catch {
                showError(error)
            }
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
        default:
            return
        }
    }

    private func confirmEnable(message: String) -> Bool {
        let alert = themedAlert()
        alert.messageText = message
        alert.informativeText = "This changes a system-wide pmset value. Keep the Mac ventilated while it is on."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func performPrivilegedChange(_ change: () throws -> Void) {
        do {
            try change()
            refreshStatus()
        } catch {
            showError(error)
            refreshStatus()
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "agenc-lid could not change sleep settings"
        alert.runModal()
    }

    private func themedAlert() -> NSAlert {
        let alert = NSAlert()
        alert.icon = Bundle.main.image(forResource: "BrandMark")
        return alert
    }

    private func refreshStatus() {
        state = powerManager.readSleepDisabledState()
        powerInfo = powerManager.readPowerInfo()
        settings = powerManager.readPmsetSettings()
        rawPmset = powerManager.readPmsetRaw()

        if isPreviewMode {
            switch ProcessInfo.processInfo.environment["AGENC_LID_PREVIEW_STATE"]?.lowercased() {
            case "on":
                state = .enabled
                if activeSessionLabel == nil {
                    activeSessionLabel = "4 hours"
                }
            case "off":
                state = .disabled
                activeSessionLabel = nil
            default:
                break
            }
        }

        if state == .disabled {
            activeSessionLabel = nil
        }

        panelController.refresh(
            state: state,
            powerInfo: powerInfo,
            settings: settings,
            rawPmset: rawPmset,
            activeSessionLabel: activeSessionLabel
        )
        popover.contentSize = panelController.preferredContentSize
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let image: NSImage?
        let iconName = state.isEnabled ? "MenuBarIconOn" : "MenuBarIconOff"
        if let url = Bundle.main.url(forResource: iconName, withExtension: "png") {
            image = NSImage(contentsOf: url)
        } else {
            image = NSImage(systemSymbolName: state.isEnabled ? "bolt.circle.fill" : "moon.zzz", accessibilityDescription: Brand.appName)
        }

        image?.isTemplate = false
        image?.size = NSSize(width: 20, height: 20)
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = nil
        statusItem.button?.toolTip = "\(Brand.appName): \(state.isEnabled ? "On" : "Off")"
    }
}

// MARK: - Layout constants

private enum Layout {
    static let popoverWidth: CGFloat = 360
    static let popoverHeight: CGFloat = 470
    static let cardInset: CGFloat = 0
    static let cardPaddingX: CGFloat = 24
    static let cardPaddingTop: CGFloat = 22
    static let cardPaddingBottom: CGFloat = 22
    static let cardCornerRadius: CGFloat = 22
    static let buttonHeight: CGFloat = 50
    static let buttonRadius: CGFloat = 13
    static let pillRadius: CGFloat = 13
    static let pmsetRowHeight: CGFloat = 30
}

// MARK: - Control panel

private final class ControlPanelViewController: NSViewController {
    weak var actions: ControlPanelActions?
    var onPreferredSizeChange: ((NSSize) -> Void)?

    private let root = RootBackgroundView()
    private let mainCard = CardPanelView()
    private let detailsCard = CardPanelView()
    private let footerView = NSView()

    private let titleLabel = label(Brand.appName, font: Brand.display(20, weight: .bold), color: Brand.text)
    private let stateBadge = StatusBadgeView()

    private let statusLabel = label("STATUS", font: Brand.mono(10, weight: .bold), color: Brand.textGhost, kern: 1.5)
    private let headlineLabel = label("Normal sleep", font: Brand.display(28, weight: .bold), color: Brand.text)
    private let subtitleLabel = label("Closing the lid sleeps this Mac.", font: Brand.display(13, weight: .medium), color: Brand.textMid)
    private let powerLabel = label("Battery 0%", font: Brand.mono(11, weight: .semibold), color: Brand.textFaint)

    private let keepAwakeLabel = label("KEEP AWAKE", font: Brand.mono(10, weight: .bold), color: Brand.orange, kern: 1.5)

    private let sessionCard = SessionCardView()
    private let cardContentHost = NSView()

    private lazy var oneHourButton = makeRoundedButton("1 HOUR", target: self, action: #selector(enableOneHour), kind: .orange)
    private lazy var fourHoursButton = makeRoundedButton("4 HOURS", target: self, action: #selector(enableFourHours), kind: .orange)
    private lazy var untilResetButton = makeRoundedButton("UNTIL RESET", target: self, action: #selector(enableIndefinitely), kind: .purple)
    private lazy var turnOffButton = makeRoundedButton("TURN OFF", target: self, action: #selector(disableNow), kind: .danger)

    private lazy var detailsButton = makeFooterButton("DETAILS", target: self, action: #selector(showDetails))
    private lazy var quitButton = makeFooterButton("QUIT", target: self, action: #selector(quit))

    // Details view
    private let detailsTitle = label("Details", font: Brand.display(20, weight: .bold), color: Brand.text)
    private lazy var doneButton = makeFooterButton("DONE", target: self, action: #selector(hideDetails))
    private let powerSectionLabel = label("POWER", font: Brand.mono(10, weight: .bold), color: Brand.orange, kern: 1.5)
    private let pmsetSectionLabel = label("PMSET", font: Brand.mono(10, weight: .bold), color: Brand.orange, kern: 1.5)
    private let powerRow = PillRowView()
    private let lidOverrideRow = PlainRowView(title: "Lid sleep override")
    private let systemSleepRow = PlainRowView(title: "System sleep timer")
    private let displaySleepRow = PlainRowView(title: "Display sleep")
    private lazy var copyButton = makeRoundedButton(
        "COPY RAW PMSET",
        target: self,
        action: #selector(copyPmset),
        kind: .ghost
    )

    private var rawPmset = ""
    private var mainPreferredContentSize = NSSize(width: Layout.popoverWidth, height: Layout.popoverHeight)
    private var detailsPreferredSize = NSSize(width: Layout.popoverWidth, height: Layout.popoverHeight - 38)
    private var sessionDescriptorBinding: ((String) -> Void)?

    override func loadView() {
        preferredContentSize = mainPreferredContentSize
        view = root
        buildLayout()
    }

    func refresh(
        state: SleepDisabledState,
        powerInfo: PowerInfo,
        settings: [PmsetSetting],
        rawPmset: String,
        activeSessionLabel: String?
    ) {
        self.rawPmset = rawPmset
        let isOn = state.isEnabled

        mainCard.isOnState = isOn
        stateBadge.update(isOn: isOn)

        headlineLabel.stringValue = isOn ? "Lid awake" : "Normal sleep"
        subtitleLabel.stringValue = isOn
            ? "Agents keep running when lid closes."
            : "Closing the lid sleeps this Mac."

        powerLabel.stringValue = powerStatusText(for: powerInfo, isOn: isOn)

        // Tear down and rebuild card content from scratch — bulletproof against
        // stale alpha values, NSStackView animation interruptions, hidden flags
        // left over from showDetails / hideDetails, etc.
        rebuildCardContent(isOn: isOn)

        // Make sure the card itself and footer are visible if we're not in
        // details mode. (showDetails sets mainCard.isHidden = true.)
        if detailsCard.isHidden {
            mainCard.isHidden = false
            footerView.isHidden = false
        }
        mainCard.alphaValue = 1
        detailsCard.alphaValue = 1

        let descriptor: String
        if let label = activeSessionLabel {
            descriptor = "\(label) armed"
        } else if isOn {
            descriptor = "Active"
        } else {
            descriptor = ""
        }
        sessionCard.update(descriptor: descriptor)

        // Details panel rows
        powerRow.update(title: "Battery", value: batteryValue(for: powerInfo))
        lidOverrideRow.update(value: state.isEnabled ? "ON" : "OFF",
                              accent: state.isEnabled ? Brand.safe : Brand.text)
        systemSleepRow.update(value: value(for: "sleep", in: settings))
        displaySleepRow.update(value: value(for: "displaysleep", in: settings))

        if !detailsCard.isHidden {
            preferredContentSize = detailsPreferredSize
        } else {
            preferredContentSize = mainPreferredContentSize
        }

        // Force the popover content to relayout after toggling control groups
        mainCard.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    // MARK: - Layout

    private func buildLayout() {
        root.translatesAutoresizingMaskIntoConstraints = false

        mainCard.translatesAutoresizingMaskIntoConstraints = false
        detailsCard.translatesAutoresizingMaskIntoConstraints = false
        footerView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(mainCard)
        root.addSubview(detailsCard)
        root.addSubview(footerView)

        let cardSidePadding: CGFloat = 12
        let cardTopPadding: CGFloat = 12
        let cardBottomPadding: CGFloat = 8

        NSLayoutConstraint.activate([
            mainCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: cardSidePadding),
            mainCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -cardSidePadding),
            mainCard.topAnchor.constraint(equalTo: root.topAnchor, constant: cardTopPadding),

            detailsCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: cardSidePadding),
            detailsCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -cardSidePadding),
            detailsCard.topAnchor.constraint(equalTo: root.topAnchor, constant: cardTopPadding),
            detailsCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -cardBottomPadding),

            footerView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            footerView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            footerView.topAnchor.constraint(equalTo: mainCard.bottomAnchor, constant: 6),
            footerView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            footerView.heightAnchor.constraint(equalToConstant: 30)
        ])

        buildMainCard()
        buildDetailsCard()
        buildFooter()

        detailsCard.isHidden = true
    }

    private func buildMainCard() {
        // Static host pinned to mainCard. Content gets torn down and rebuilt
        // on every refresh — no isHidden games, no stale layout state.
        cardContentHost.translatesAutoresizingMaskIntoConstraints = false
        mainCard.addSubview(cardContentHost)

        NSLayoutConstraint.activate([
            cardContentHost.leadingAnchor.constraint(equalTo: mainCard.leadingAnchor, constant: Layout.cardPaddingX),
            cardContentHost.trailingAnchor.constraint(equalTo: mainCard.trailingAnchor, constant: -Layout.cardPaddingX),
            cardContentHost.topAnchor.constraint(equalTo: mainCard.topAnchor, constant: Layout.cardPaddingTop),
            cardContentHost.bottomAnchor.constraint(equalTo: mainCard.bottomAnchor, constant: -Layout.cardPaddingBottom),
            mainCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 388)
        ])
    }

    private func rebuildCardContent(isOn: Bool) {
        // Tear down everything in the host. This guarantees no stale alpha,
        // no stuck NSStackView animations, no half-attached subviews.
        for sub in cardContentHost.subviews { sub.removeFromSuperview() }

        let header = headerRow(title: titleLabel, badge: stateBadge)
        let info = NSStackView(views: [statusLabel, headlineLabel, subtitleLabel, powerLabel])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 6
        info.setCustomSpacing(2, after: statusLabel)
        info.setCustomSpacing(8, after: headlineLabel)

        let controls: NSView
        if isOn {
            let onStack = NSStackView(views: [sessionCard, turnOffButton])
            onStack.orientation = .vertical
            onStack.alignment = .leading
            onStack.spacing = 12
            onStack.translatesAutoresizingMaskIntoConstraints = false
            controls = onStack
        } else {
            let twoButtonRow = NSStackView(views: [oneHourButton, fourHoursButton])
            twoButtonRow.orientation = .horizontal
            twoButtonRow.distribution = .fillEqually
            twoButtonRow.spacing = 12

            let offStack = NSStackView(views: [keepAwakeLabel, twoButtonRow, untilResetButton])
            offStack.orientation = .vertical
            offStack.alignment = .leading
            offStack.spacing = 10
            offStack.translatesAutoresizingMaskIntoConstraints = false
            controls = offStack
        }

        let stack = NSStackView(views: [header, info, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.setCustomSpacing(22, after: header)
        stack.translatesAutoresizingMaskIntoConstraints = false

        cardContentHost.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cardContentHost.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cardContentHost.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cardContentHost.topAnchor)
        ])

        // Width constraints applied AFTER all views are in the hierarchy.
        for view in [header, info, controls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if let onStack = controls as? NSStackView, isOn {
            for v in [sessionCard, turnOffButton] {
                v.widthAnchor.constraint(equalTo: onStack.widthAnchor).isActive = true
            }
        } else if let offStack = controls as? NSStackView {
            for v in offStack.arrangedSubviews {
                v.widthAnchor.constraint(equalTo: offStack.widthAnchor).isActive = true
            }
        }

        // Reset alpha + remove animations on every subview, defensively.
        func resetTree(_ view: NSView) {
            view.alphaValue = 1
            view.layer?.opacity = 1
            view.layer?.removeAllAnimations()
            view.isHidden = false
            for sub in view.subviews { resetTree(sub) }
        }
        resetTree(cardContentHost)
    }

    private func buildDetailsCard() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        detailsCard.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: detailsCard.leadingAnchor, constant: Layout.cardPaddingX),
            content.trailingAnchor.constraint(equalTo: detailsCard.trailingAnchor, constant: -Layout.cardPaddingX),
            content.topAnchor.constraint(equalTo: detailsCard.topAnchor, constant: Layout.cardPaddingTop),
            content.bottomAnchor.constraint(equalTo: detailsCard.bottomAnchor, constant: -Layout.cardPaddingBottom)
        ])

        let header = headerRow(title: detailsTitle, badge: doneButton)

        let pmsetRows = NSStackView(views: [lidOverrideRow, systemSleepRow, displaySleepRow])
        pmsetRows.orientation = .vertical
        pmsetRows.alignment = .leading
        pmsetRows.spacing = 0
        pmsetRows.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            header,
            powerSectionLabel,
            powerRow,
            pmsetSectionLabel,
            pmsetRows,
            spacerView(),
            copyButton
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(22, after: header)
        stack.setCustomSpacing(10, after: powerSectionLabel)
        stack.setCustomSpacing(20, after: powerRow)
        stack.setCustomSpacing(8, after: pmsetSectionLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        for view in [header, powerRow, pmsetRows, copyButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for row in [lidOverrideRow, systemSleepRow, displaySleepRow] {
            row.widthAnchor.constraint(equalTo: pmsetRows.widthAnchor).isActive = true
        }
        powerSectionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        pmsetSectionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func buildFooter() {
        detailsButton.translatesAutoresizingMaskIntoConstraints = false
        quitButton.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(detailsButton)
        footerView.addSubview(quitButton)

        NSLayoutConstraint.activate([
            detailsButton.leadingAnchor.constraint(equalTo: footerView.leadingAnchor),
            detailsButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),

            quitButton.trailingAnchor.constraint(equalTo: footerView.trailingAnchor),
            quitButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor)
        ])
    }

    private func headerRow(title: NSView, badge: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(title)
        row.addSubview(badge)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            badge.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 30)
        ])
        return row
    }

    private func spacerView() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    private func powerStatusText(for info: PowerInfo, isOn: Bool) -> String {
        let suffix = isOn && info.isBattery ? " / keep ventilated" : ""
        if let percent = info.batteryPercent {
            let prefix = info.isBattery ? "Battery" : info.source
            return "\(prefix) \(percent)%\(suffix)"
        }
        return info.source + suffix
    }

    private func batteryValue(for info: PowerInfo) -> String {
        if let percent = info.batteryPercent {
            return "\(percent)%"
        }
        return info.source.uppercased()
    }

    private func value(for key: String, in settings: [PmsetSetting]) -> String {
        settings.first(where: { $0.key == key })?.prettyValue ?? "—"
    }

    // MARK: - Actions

    @objc private func enableOneHour() { actions?.enableOneHour() }
    @objc private func enableFourHours() { actions?.enableFourHours() }
    @objc private func enableIndefinitely() { actions?.enableIndefinitely() }
    @objc private func disableNow() { actions?.disableNow() }
    @objc private func quit() { actions?.quit() }

    @objc private func showDetails() {
        preferredContentSize = detailsPreferredSize
        onPreferredSizeChange?(preferredContentSize)

        // Hard swap with no animation — animations getting interrupted by the
        // popover dismissing left views stuck at alphaValue = 0.
        mainCard.alphaValue = 1
        detailsCard.alphaValue = 1
        mainCard.isHidden = true
        detailsCard.isHidden = false
        footerView.isHidden = true
    }

    func showDetailsForPreview() {
        preferredContentSize = detailsPreferredSize
        mainCard.alphaValue = 1
        detailsCard.alphaValue = 1
        mainCard.isHidden = true
        detailsCard.isHidden = false
        footerView.isHidden = true
        onPreferredSizeChange?(preferredContentSize)
    }

    @objc private func hideDetails() {
        preferredContentSize = mainPreferredContentSize
        onPreferredSizeChange?(preferredContentSize)

        mainCard.alphaValue = 1
        detailsCard.alphaValue = 1
        mainCard.isHidden = false
        detailsCard.isHidden = true
        footerView.isHidden = false
    }

    func cancelAllAnimations() {
        // Walk the view tree and reset alpha + remove any in-flight CALayer
        // animations. Belt-and-braces against transient popover dismissal
        // killing AppKit's implicit fade animations.
        func walk(_ view: NSView) {
            view.alphaValue = 1
            view.layer?.opacity = 1
            view.layer?.removeAllAnimations()
            for sub in view.subviews { walk(sub) }
        }
        walk(view)
    }

    @objc private func copyPmset() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawPmset, forType: .string)
        copyButton.attributedTitle = buttonTitle("COPIED", color: Brand.safe, kern: 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.attributedTitle = buttonTitle("COPY RAW PMSET", color: Brand.textMuted, kern: 1.0)
        }
    }
}

// MARK: - Buttons

private enum ButtonKind {
    case orange
    case purple
    case danger
    case ghost
}

private func makeRoundedButton(
    _ title: String,
    target: AnyObject,
    action: Selector,
    kind: ButtonKind,
    height: CGFloat = Layout.buttonHeight,
    radius: CGFloat = Layout.buttonRadius
) -> NSButton {
    let button = HoverButton(title: title, target: target, action: action)
    button.bezelStyle = .regularSquare
    button.isBordered = false
    button.wantsLayer = true
    button.layer?.cornerRadius = radius
    button.layer?.borderWidth = 1.4
    button.heightAnchor.constraint(equalToConstant: height).isActive = true

    let fill: NSColor
    let border: NSColor
    let textColor: NSColor

    switch kind {
    case .orange:
        fill = Brand.orange.withAlphaComponent(0.18)
        border = Brand.orange
        textColor = Brand.text
    case .purple:
        fill = Brand.purple.withAlphaComponent(0.18)
        border = Brand.purple
        textColor = Brand.text
    case .danger:
        fill = Brand.danger.withAlphaComponent(0.18)
        border = Brand.danger
        textColor = Brand.text
    case .ghost:
        fill = Brand.rowFill
        border = Brand.strokeRow
        textColor = Brand.textMuted
    }

    button.baseBackgroundColor = fill
    button.baseBorderColor = border
    button.layer?.backgroundColor = fill.cgColor
    button.layer?.borderColor = border.cgColor
    button.attributedTitle = buttonTitle(title.uppercased(), color: textColor, kern: 1.0)
    return button
}

private func makeFooterButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
    let button = HoverButton(title: title, target: target, action: action)
    button.bezelStyle = .regularSquare
    button.isBordered = false
    button.wantsLayer = true
    button.attributedTitle = buttonTitle(title.uppercased(), color: Brand.textMuted, kern: 1.0)
    button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    return button
}

private func buttonTitle(_ title: String, color: NSColor, kern: CGFloat) -> NSAttributedString {
    NSAttributedString(
        string: title,
        attributes: [
            .font: Brand.mono(11, weight: .heavy),
            .foregroundColor: color,
            .kern: kern
        ]
    )
}

// MARK: - Custom views

private final class RootBackgroundView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Brand.void.setFill()
        bounds.fill()
    }
}

private final class CardPanelView: NSView {
    override var isFlipped: Bool { true }
    var isOnState: Bool = false {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let path = NSBezierPath(roundedRect: rect, xRadius: Layout.cardCornerRadius, yRadius: Layout.cardCornerRadius)
        path.addClip()

        let colors: [NSColor]
        if isOnState {
            colors = [Brand.panelTopOn, Brand.panelMidOn, Brand.panelBotOn]
        } else {
            colors = [Brand.panelTopOff, Brand.panelMidOff, Brand.panelBotOff]
        }

        let gradient = NSGradient(colors: colors, atLocations: [0.0, 0.6, 1.0], colorSpace: .sRGB)
        gradient?.draw(in: rect, angle: 305) // top-left -> bottom-right (mockup angle)

        Brand.stroke.setStroke()
        let strokePath = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.6, dy: 0.6),
            xRadius: Layout.cardCornerRadius - 0.6,
            yRadius: Layout.cardCornerRadius - 0.6
        )
        strokePath.lineWidth = 1.2
        strokePath.stroke()
    }
}

private final class StatusBadgeView: NSView {
    private let textField = NSTextField(labelWithString: "OFF")
    private let backgroundLayer = CALayer()
    private var isOn = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Layout.pillRadius
        layer?.borderWidth = 1.0

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.alignment = .center
        textField.maximumNumberOfLines = 1
        addSubview(textField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 50),
            textField.centerXAnchor.constraint(equalTo: centerXAnchor),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])

        update(isOn: false)
    }

    func update(isOn: Bool) {
        self.isOn = isOn
        let title = isOn ? "ON" : "OFF"
        let color = isOn ? Brand.safe : Brand.textMuted
        let fill = isOn ? Brand.safe.withAlphaComponent(0.15) : NSColor(white: 1.0, alpha: 0.07)
        let border = isOn ? Brand.safe.cgColor : NSColor(white: 1.0, alpha: 0.16).cgColor

        textField.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [
                .font: Brand.mono(10, weight: .heavy),
                .foregroundColor: color,
                .kern: 1.2
            ]
        )
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border
    }
}

private final class SessionCardView: NSView {
    private let labelField = NSTextField(labelWithString: "ACTIVE SESSION")
    private let descriptorField = NSTextField(labelWithString: "Active")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 1.0
        layer?.borderColor = Brand.safe.withAlphaComponent(0.40).cgColor
        layer?.backgroundColor = Brand.safe.withAlphaComponent(0.10).cgColor

        labelField.translatesAutoresizingMaskIntoConstraints = false
        descriptorField.translatesAutoresizingMaskIntoConstraints = false

        labelField.attributedStringValue = NSAttributedString(
            string: "ACTIVE SESSION",
            attributes: [
                .font: Brand.mono(10, weight: .bold),
                .foregroundColor: Brand.safe,
                .kern: 1.5
            ]
        )

        descriptorField.font = Brand.display(20, weight: .bold)
        descriptorField.textColor = Brand.text
        descriptorField.maximumNumberOfLines = 1

        addSubview(labelField)
        addSubview(descriptorField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 64),
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            labelField.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            descriptorField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            descriptorField.topAnchor.constraint(equalTo: labelField.bottomAnchor, constant: 4),
            descriptorField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(descriptor: String) {
        descriptorField.stringValue = descriptor.isEmpty ? "Active" : descriptor
    }
}

private final class PillRowView: NSView {
    private let titleField = NSTextField(labelWithString: "Battery")
    private let valueField = NSTextField(labelWithString: "—")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1.0
        layer?.borderColor = Brand.strokeRow.cgColor
        layer?.backgroundColor = Brand.rowFill.cgColor

        titleField.translatesAutoresizingMaskIntoConstraints = false
        valueField.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = Brand.mono(13, weight: .semibold)
        titleField.textColor = Brand.textMid
        titleField.maximumNumberOfLines = 1

        valueField.font = Brand.mono(13, weight: .heavy)
        valueField.textColor = Brand.text
        valueField.alignment = .right
        valueField.maximumNumberOfLines = 1

        addSubview(titleField)
        addSubview(valueField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 50),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(title: String, value: String) {
        titleField.stringValue = title
        valueField.stringValue = value
    }
}

private final class PlainRowView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleField.translatesAutoresizingMaskIntoConstraints = false
        valueField.translatesAutoresizingMaskIntoConstraints = false

        titleField.stringValue = title
        titleField.font = Brand.mono(13, weight: .semibold)
        titleField.textColor = Brand.textMid
        titleField.maximumNumberOfLines = 1

        valueField.font = Brand.mono(13, weight: .heavy)
        valueField.textColor = Brand.text
        valueField.alignment = .right
        valueField.maximumNumberOfLines = 1

        addSubview(titleField)
        addSubview(valueField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Layout.pmsetRowHeight),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(value: String, accent: NSColor = Brand.text) {
        valueField.stringValue = value
        valueField.textColor = accent
    }
}

private final class HoverButton: NSButton {
    var baseBackgroundColor: NSColor?
    var baseBorderColor: NSColor?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let baseBackgroundColor else {
            alphaValue = 0.85
            return
        }
        layer?.backgroundColor = baseBackgroundColor.blended(withFraction: 0.20, of: .white)?.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if let baseBackgroundColor {
            layer?.backgroundColor = baseBackgroundColor.cgColor
        } else {
            alphaValue = 1.0
        }
    }
}

// MARK: - Helpers

private func label(_ text: String, font: NSFont, color: NSColor, kern: CGFloat = 0) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    if kern != 0 {
        field.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .kern: kern
            ]
        )
    } else {
        field.font = font
        field.textColor = color
    }
    field.maximumNumberOfLines = 0
    field.lineBreakMode = .byWordWrapping
    return field
}

// MARK: - Boot

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()

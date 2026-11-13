import AppKit
import CoreAudio
import ServiceManagement

/// Owns the NSStatusItem and builds the menu on demand.
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var idleIcon: NSImage?
    private var statusIcon: NSImage?
    private var dimStatusIcon: NSImage?
    private var blinkTimer: Timer?
    private var isBlinkVisible = true
    private let audioManager = AudioDeviceManager.shared
    private let processDetector = ProcessDetector.shared

    deinit {
        blinkTimer?.invalidate()
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        idleIcon = NSImage(systemSymbolName: "mic", accessibilityDescription: "Microphone inactive")
        idleIcon?.isTemplate = true

        let iconPointSize = (statusItem.button?.font?.pointSize ?? NSFont.systemFontSize) * 0.9
        let configuration = NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: .regular)
        statusIcon = makeIcon(named: "circle.fill", color: .systemRed,
                              accessibilityDescription: "Microphone in use", configuration: configuration)
        dimStatusIcon = makeIcon(named: "circle.fill", color: .systemRed.withAlphaComponent(0.25),
                                 accessibilityDescription: "Microphone in use", configuration: configuration)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        updateTitle()

        // Listen for device changes
        audioManager.onDeviceChanged = { [weak self] in
            self?.updateTitle()
        }
    }

    // MARK: - Title

    private func updateTitle() {
        let activeDevices = audioManager.activeInputDevices()

        if activeDevices.isEmpty {
            blinkTimer?.invalidate()
            blinkTimer = nil
            statusItem.button?.title = ""
            statusItem.button?.image = idleIcon
            statusItem.button?.imagePosition = .imageOnly
            statusItem.button?.setAccessibilityTitle("Microphone inactive")
        } else {
            statusItem.button?.title = activeDevices.map { $0.1 }.joined(separator: ", ")
            statusItem.button?.imagePosition = .imageLeft
            statusItem.button?.setAccessibilityTitle("Microphone in use")

            if blinkTimer == nil {
                isBlinkVisible = true
                blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.isBlinkVisible.toggle()
                    self.updateBlinkImage()
                }
            }
            updateBlinkImage()
        }
    }

    private func updateBlinkImage() {
        statusItem.button?.image = isBlinkVisible ? statusIcon : dimStatusIcon
    }

    private func makeIcon(named name: String, color: NSColor, accessibilityDescription: String,
                          configuration: NSImage.SymbolConfiguration) -> NSImage? {
        let paletteConfiguration = configuration.applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(paletteConfiguration)
        image?.isTemplate = false
        return image
    }

    // MARK: - Menu Building

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        buildMenu(menu)
    }

    private func buildMenu(_ menu: NSMenu) {
        // Section: Apps using microphone
        let detection = processDetector.detectAppsUsingMicrophone()

        let headerItem = NSMenuItem(title: "Using Microphone:", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        headerItem.attributedTitle = NSAttributedString(
            string: "Using Microphone:",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        menu.addItem(headerItem)

        switch detection.method {
        case .micInactive:
            let item = NSMenuItem(title: "  Not active", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)

        case .logAttribution, .privateAPI:
            if detection.apps.isEmpty {
                let item = NSMenuItem(title: "  Unknown process", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                for app in detection.apps {
                    let item = NSMenuItem(title: "  \(app.name)", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    if let icon = app.icon {
                        let resized = resizeImage(icon, to: NSSize(width: 16, height: 16))
                        item.image = resized
                    }
                    menu.addItem(item)
                }
            }

        case .tccHeuristic:
            if detection.apps.isEmpty {
                let item = NSMenuItem(title: "  Active (app unknown)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                for app in detection.apps {
                    let item = NSMenuItem(title: "  \(app.name)", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    if let icon = app.icon {
                        let resized = resizeImage(icon, to: NSSize(width: 16, height: 16))
                        item.image = resized
                    }
                    menu.addItem(item)
                }
            }

            // Show fallback notice
            let noticeItem = NSMenuItem(
                title: "  ⚠ Approximate detection",
                action: nil,
                keyEquivalent: ""
            )
            noticeItem.isEnabled = false
            noticeItem.attributedTitle = NSAttributedString(
                string: "  ⚠ Approximate — may show extra apps",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
            menu.addItem(noticeItem)

        case .noAccess:
            let item = NSMenuItem(title: "  Mic active — app detection unavailable", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)

            let helpItem = NSMenuItem(
                title: "  Open Privacy Settings...",
                action: #selector(openFDASettings(_:)),
                keyEquivalent: ""
            )
            helpItem.target = self
            helpItem.attributedTitle = NSAttributedString(
                string: "  Open Privacy Settings...",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.linkColor,
                ]
            )
            menu.addItem(helpItem)
        }

        menu.addItem(.separator())

        // Section: Input Device switcher
        let deviceHeader = NSMenuItem(title: "Input Device:", action: nil, keyEquivalent: "")
        deviceHeader.isEnabled = false
        deviceHeader.attributedTitle = NSAttributedString(
            string: "Input Device:",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        menu.addItem(deviceHeader)

        let currentDeviceID = audioManager.defaultInputDeviceID()
        let devices = audioManager.availableInputDevices()
        for (deviceID, name) in devices {
            let item = NSMenuItem(
                title: "  \(name)",
                action: #selector(switchDevice(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = Int(deviceID)
            if deviceID == currentDeviceID {
                item.state = .on
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Launch at login toggle
        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit MicBar",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func statusItemClicked() {
        statusItem.button?.performClick(nil)
    }

    @objc private func switchDevice(_ sender: NSMenuItem) {
        let deviceID = AudioDeviceID(sender.tag)
        audioManager.setDefaultInputDevice(deviceID)
        updateTitle()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if sender.state == .on {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("MicBar: Failed to toggle launch at login: \(error)")
        }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    @objc private func openFDASettings(_ sender: NSMenuItem) {
        // Opens System Settings > Privacy & Security > Full Disk Access
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    private func isLaunchAtLoginEnabled() -> Bool {
        return SMAppService.mainApp.status == .enabled
    }

    private func resizeImage(_ image: NSImage, to size: NSSize) -> NSImage {
        let resized = NSImage(size: size)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        resized.unlockFocus()
        return resized
    }
}

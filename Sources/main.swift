import AppKit
import CoreGraphics
import IOKit
import IOKit.graphics
import OSLog
import ServiceManagement

let log = Logger(subsystem: "com.iltekin.Unplug", category: "safety")
let repositoryURL = URL(string: "https://github.com/iltekin/unplug")!

// Private CoreGraphics/SkyLight API: BetterDisplay'in "disconnect" özelliğinin kullandığı çağrı.
// Ekranı yazılımsal olarak bağlantıdan koparır; monitöre giden sinyal kesilir.
@_silgen_name("CGSConfigureDisplayEnabled")
func CGSConfigureDisplayEnabled(_ config: CGDisplayConfigRef, _ display: CGDirectDisplayID, _ enabled: Bool) -> CGError

// Kapatılmış ekranlar CGGetOnlineDisplayList'ten düşer; bu liste onları da içerir.
@_silgen_name("CGSGetDisplayList")
func CGSGetDisplayList(_ maxCount: UInt32, _ displays: UnsafeMutablePointer<CGDirectDisplayID>?, _ count: UnsafeMutablePointer<UInt32>) -> CGError

struct Display {
    let id: CGDirectDisplayID
    let name: String
    let active: Bool
    let builtin: Bool
}

final class DisplayManager {
    private let defaults = UserDefaults.standard
    private let namesKey = "displayNames"          // [String(id): name]

    /// Kapalı ekranın adı sistemden okunamadığı için açıkken görülen adlar saklanır.
    private var knownNames: [String: String] {
        get { defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: namesKey) }
    }

    func displays() -> [Display] {
        var names = knownNames
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                names[String(id)] = screen.localizedName
            }
        }
        knownNames = names

        var ids = Set(onlineDisplayIDs()).union(allDisplayIDs())

        // Kapalı ekran fişi çekilince de sistem listesinde kalır; kabloyla bağlı olmayanları gösterme.
        let hardware = attachedHardware()
        ids = ids.filter { id in
            CGDisplayIsActive(id) != 0 || CGDisplayIsBuiltin(id) != 0 || hardware.contains { $0.matches(id) }
        }

        return ids.map { id in
            // Açık/kapalı durumu her zaman sistemden: macOS ekranı kendisi de geri açabilir
            // (örneğin fişi çekilip yeniden takılınca).
            let active = CGDisplayIsActive(id) != 0
            let name = names[String(id)] ?? hardware.first(where: { $0.matches(id) })?.name ?? String(format: NSLocalizedString("Display %u", comment: "Fallback display name"), id)
            return Display(id: id, name: name, active: active, builtin: CGDisplayIsBuiltin(id) != 0)
        }
        .sorted { ($0.builtin ? 0 : 1, $0.name) < ($1.builtin ? 0 : 1, $1.name) }
    }

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// Kapalılar dahil tüm ekranlar; üretici kimliği olmayan boş yer tutucular atlanır.
    private func allDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGSGetDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayVendorNumber($0) != 0 }
    }

    private struct AttachedHardware {
        let vendor: UInt32
        let product: UInt32?
        var name: String? = nil

        func matches(_ id: CGDirectDisplayID) -> Bool {
            vendor == CGDisplayVendorNumber(id) && (product == nil || product == CGDisplayModelNumber(id))
        }
    }

    /// Kabloyla bağlı ekranların üretici/model kimlikleri. Apple Silicon'da her ekran çıkışının
    /// bir framebuffer'ı vardır ve yalnızca bağlı bir ekran varken "DisplayAttributes" taşır;
    /// Intel Mac'lerde bağlı her ekran için bir IODisplayConnect bulunur.
    private func attachedHardware() -> [AttachedHardware] {
        var result: [AttachedHardware] = []
        for serviceClass in ["IOMobileFramebuffer", "IODisplayConnect"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                if let attributes = IORegistryEntryCreateCFProperty(service, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                   let product = attributes["ProductAttributes"] as? [String: Any],
                   let vendor = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value {
                    result.append(AttachedHardware(vendor: vendor, product: (product["ProductID"] as? NSNumber)?.uint32Value,
                                                   name: product["ProductName"] as? String))
                } else if serviceClass == "IODisplayConnect",
                          let info = IODisplayCreateInfoDictionary(service, 0)?.takeRetainedValue() as? [String: Any],
                          let vendor = (info[kDisplayVendorID] as? NSNumber)?.uint32Value {
                    result.append(AttachedHardware(vendor: vendor, product: (info[kDisplayProductID] as? NSNumber)?.uint32Value))
                }
            }
        }
        return result
    }

    private var lastSafetyState = ""

    /// Gerçekten görüntü veren ekran sayısı. Sistemin ekran listesi fişi çekilen ekranı bir süre
    /// açık göstermeye devam edebildiği için harici ekranlar ancak kablosu da bağlıysa sayılır.
    /// Üreticisi olmayan 1x1'lik sahte ekran da sayılmaz.
    private func activeDisplayCount() -> Int {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let active = ids.prefix(Int(count))
        let hardware = attachedHardware()
        let real = active.filter { id in
            CGDisplayVendorNumber(id) != 0
                && (CGDisplayIsBuiltin(id) != 0 || hardware.contains { $0.matches(id) })
        }

        let state = "active=\(Array(active)) real=\(real) attached=\(hardware.map { "\($0.vendor)/\($0.product.map(String.init) ?? "-")" })"
        if state != lastSafetyState {
            log.notice("Safety check: \(state, privacy: .public)")
            lastSafetyState = state
        }
        return real.count
    }

    private let builtinKey = "builtinDisplayID"

    /// Hiç ekran kalmayınca macOS dahili ekranı listelerden düşürebiliyor; kimliğini önceden sakla.
    private func rememberBuiltinDisplay() {
        if let id = (onlineDisplayIDs() + allDisplayIDs()).first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            defaults.set(Int(id), forKey: builtinKey)
        }
    }

    /// Örneğin dahili ekran kapalıyken harici ekranın fişi çekilirse hiç ekran kalmaz;
    /// bu durumda önce dahili ekranı, o da olmazsa listedeki diğer ekranları geri açar.
    func restoreIfNoActiveDisplay() {
        guard activeDisplayCount() == 0 else {
            rememberBuiltinDisplay()
            return
        }

        if let builtin = defaults.object(forKey: builtinKey) as? Int {
            let id = CGDirectDisplayID(builtin)
            log.notice("No active display left, turning on built-in display \(id): \(self.setEnabled(id, true) ? "ok" : "failed", privacy: .public)")
            return
        }

        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        _ = CGSGetDisplayList(UInt32(ids.count), &ids, &count)
        let candidates = ids.prefix(Int(count)).filter { CGDisplayIsActive($0) == 0 }
        log.notice("No active display left and built-in unknown, turning on \(Array(candidates), privacy: .public)")
        for id in candidates { setEnabled(id, true) }
    }

    /// Dahili ekran artık menüden kapatılamıyor; eski bir sürümle kapatılmış kaldıysa geri aç.
    /// Kapak kapalıyken dahili ekran zaten kapalıdır, o zaman dokunma.
    func turnOnBuiltinDisplayIfLidOpen() {
        rememberBuiltinDisplay()
        guard !isLidClosed(), let builtin = defaults.object(forKey: builtinKey) as? Int else { return }
        let id = CGDirectDisplayID(builtin)
        guard CGDisplayIsActive(id) == 0 else { return }
        log.notice("Built-in display \(id) was off, turning it on: \(self.setEnabled(id, true) ? "ok" : "failed", privacy: .public)")
    }

    private func isLidClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        let state = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
        return state ?? false
    }

    @discardableResult
    func setEnabled(_ display: Display, _ enabled: Bool) -> Bool {
        setEnabled(display.id, enabled)
    }

    @discardableResult
    func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGSConfigureDisplayEnabled(config, id, enabled) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        // forSession: oturum kapanınca/yeniden başlatınca ekranlar kendiliğinden geri gelir.
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}

/// Menü pencereleri hiçbir zaman "key" olmadığı için NSSwitch orada hep pasif (gri) çizilir.
/// Bu yüzden açıkken yeşil görünen kendi anahtarımızı çiziyoruz.
final class ToggleSwitch: NSControl {
    var state: NSControl.StateValue = .off { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 42, height: 24) }
    // Menünün buzlu arka planı rengi soldurmasın.
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let isOn = state == .on
        let track = bounds.insetBy(dx: 1, dy: 1)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2)
        (isOn ? NSColor.systemGreen : NSColor.tertiaryLabelColor).setFill()
        trackPath.fill()

        let knobSize = track.height - 4
        let knobX = isOn ? track.maxX - knobSize - 2 : track.minX + 2
        let knob = NSRect(x: knobX, y: track.minY + 2, width: knobSize, height: knobSize)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1.5
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        state = state == .on ? .off : .on
        sendAction(action, to: target)
    }
}

/// Menüde tek bir monitör satırı: solda ad, sağda açma/kapama anahtarı.
final class DisplayRowView: NSView {
    let displayID: CGDirectDisplayID
    let toggle = ToggleSwitch()
    private let label: NSTextField
    var onChange: ((DisplayRowView) -> Void)?

    init(display: Display) {
        displayID = display.id
        label = NSTextField(labelWithString: display.name)
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 32))

        let icon = NSImageView(image: NSImage(
            systemSymbolName: display.builtin ? "laptopcomputer" : "display",
            accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        toggle.state = display.active ? .on : .off
        toggle.target = self
        toggle.action = #selector(switchChanged)

        for view in [icon, label, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func switchChanged() { onChange?(self) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let manager = DisplayManager()
    private var statusItem: NSStatusItem!
    private var rows: [DisplayRowView] = []
    private var appNapBlocker: NSObjectProtocol?
    private var builtinActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: NSLocalizedString("Displays", comment: "Menu header"))
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Fiş çekme/takma gibi her ekran değişikliğinde ekransız kalıp kalmadığımızı kontrol et.
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
            Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue().scheduleSafetyCheck()
        }, Unmanaged.passUnretained(self).toOpaque())
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(scheduleSafetyCheck),
            name: NSWorkspace.didWakeNotification, object: nil)
        // Değişiklik bildirimi kaçarsa kullanıcı ekransız kalmasın diye ayrıca düzenli kontrol.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.manager.restoreIfNoActiveDisplay()
        }
        // Penceresiz arka plan uygulaması App Nap'e girip bu kontrolü geciktirmesin.
        appNapBlocker = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Turns a display back on if none is left")
        manager.restoreIfNoActiveDisplay()
        manager.turnOnBuiltinDisplayIfLidOpen()

        // Bilgisayar her açıldığında Unplug da açılsın.
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }

    @objc private func showAbout() {
        let credits = NSMutableAttributedString(
            string: NSLocalizedString("Turn displays on and off from the menu bar.", comment: "About panel description") + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(
            string: repositoryURL.absoluteString,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: repositoryURL]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private var safetyCheck: DispatchWorkItem?

    /// Değişiklikler art arda geldiği için sistem durulunca tek sefer kontrol eder.
    @objc func scheduleSafetyCheck() {
        safetyCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.manager.restoreIfNoActiveDisplay() }
        safetyCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Dahili ekran kapatılamaz: kapalıyken harici ekranın fişi çekilirse kullanıcı ekransız kalır.
        let all = manager.displays()
        builtinActive = all.contains { $0.builtin && $0.active }
        let displays = all.filter { !$0.builtin }

        let header = NSMenuItem(title: NSLocalizedString("Displays", comment: "Menu header"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if displays.isEmpty {
            let empty = NSMenuItem(title: NSLocalizedString("No external displays", comment: "Empty menu state"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        rows = displays.map { display in
            let row = DisplayRowView(display: display)
            row.onChange = { [weak self] row in self?.switchChanged(row) }
            let item = NSMenuItem()
            item.view = row
            menu.addItem(item)
            return row
        }
        updateSwitchAvailability()

        menu.addItem(.separator())
        let about = NSMenuItem(title: NSLocalizedString("About", comment: "About menu item"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        about.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: nil)
        menu.addItem(about)
        menu.addItem(NSMenuItem(title: NSLocalizedString("Quit", comment: "Quit menu item"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func switchChanged(_ row: DisplayRowView) {
        let enable = row.toggle.state == .on
        // Ekran düzeni değişince menü çubuğu yer değiştirir ama açık menü eski yerinde kalır;
        // bu yüzden değişiklikten önce menüyü kapat.
        statusItem.menu?.cancelTracking()
        guard let display = manager.displays().first(where: { $0.id == row.displayID }),
              manager.setEnabled(display, enable) else {
            row.toggle.state = enable ? .off : .on
            NSSound.beep()
            return
        }
        updateSwitchAvailability()
    }

    /// Son açık ekranı kapatmak kullanıcıyı ekransız bırakır; onun anahtarını kilitle.
    /// Sistem ekran durumunu gecikmeli güncellediği için anahtarların kendi durumuna bakılır.
    private func updateSwitchAvailability() {
        // Kapak kapalıyken dahili ekran açık sayılmaz; o zaman son harici ekran kilitlenir.
        let onCount = rows.filter { $0.toggle.state == .on }.count + (builtinActive ? 1 : 0)
        for row in rows {
            row.toggle.isEnabled = !(onCount <= 1 && row.toggle.state == .on)
            row.toolTip = row.toggle.isEnabled ? nil
                : NSLocalizedString("The last active display can't be turned off", comment: "Locked switch tooltip")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

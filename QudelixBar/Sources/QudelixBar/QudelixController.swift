import Foundation
import SwiftUI

/// Connection + device state, and all user actions.
///
/// Transport: USB HID over the vendor-defined interface — full duplex, the
/// device answers every request and pushes notifications unprompted.
///
/// BLETransport exists but is not used: the 5K's BLE endpoint speaks Qualcomm
/// GAIA and does not accept Qudelix commands directly (see docs/FINDINGS.md).
///
/// UI state is optimistic: writes apply locally immediately; device pushes
/// (notifications) overwrite local state when they arrive.
@MainActor
final class QudelixController: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connected(name: String)
    }

    /// Whether this particular device speaks the protocol we implement.
    ///
    /// The handshake tells us the model and firmware, so rather than writing
    /// blind we verify first: writing 10-band legacy EQ commands to a 5K Plus,
    /// to firmware 2.x, or to a device in 20-band mode silently does the wrong
    /// thing, which is worse than refusing.
    enum Compatibility: Equatable {
        case checking
        case ok
        case unsupported(title: String, detail: String)

        var canWrite: Bool { self == .ok }
    }

    @Published var compatibility: Compatibility = .checking

    @Published var connection: ConnectionState = .disconnected
    @Published var usbWired = false           // USB presence (audio path), not control
    @Published var firmwareVersion: String?
    @Published var batteryPercent: Int?
    @Published var charging = false
    @Published var sampleRate: String?
    @Published var inputSource: String?
    @Published var receivingReports = false   // true once the device answers over BLE

    // Volume (dB). 60 dB window; max is 0 dB (or +6 in 2 Vrms mode).
    @Published var volumeDb: Double = -30
    @Published var volumeMax: Double = 0
    @Published var muted = false
    var volumeRange: ClosedRange<Double> { (volumeMax - 60)...volumeMax }

    // EQ
    @Published var eqEnabled = true
    @Published var preGain: Double = 0
    @Published var bands: [QxEqBandValue] = QxEq.defaultFreqs.map {
        QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0)
    }
    @Published var presetNames: [Int: String] = [:]
    @Published var activePreset: Int?
    @Published var lastImportSummary: String?

    /// Set only by UIPreview to force a starting pane when rendering mocks.
    var previewPane: PopoverView.Pane?
    /// Set only by UIPreview: seeds the AutoEq list so it renders offline.
    var previewAutoEq: (entries: [AutoEqEntry], query: String)?
    static let presetCount = 20

    /// EQ group the device is currently using — driven by `dd.eq_mode`.
    /// 10-band user EQ by default; 20-band (b20) when the device is in that mode.
    @Published private(set) var eqGroup: QxEqGroup = .user
    var bandCount: Int { eqGroup.bandCount }

    private let hid = HIDTransport()
    private var assembler = QxPresetAssembler()
    private var state = QxDeviceState()
    private var requestedNames = false
    private var handshakeAttempt = 0

    func start() {
        hid.onDeviceConnected = { [weak self] name in
            Task { @MainActor in
                self?.usbWired = true
                self?.deviceConnected(name)
            }
        }
        hid.onDeviceRemoved = { [weak self] in
            Task { @MainActor in
                self?.usbWired = false
                self?.connection = .disconnected
                self?.receivingReports = false
                self?.batteryPercent = nil
            }
        }
        hid.onInputReport = { [weak self] _, bytes in
            Task { @MainActor in self?.handlePacket(bytes) }
        }
        hid.start()
    }

    private func deviceConnected(_ name: String) {
        connection = .connected(name: name)
        assembler.reset()
        state = QxDeviceState()
        requestedNames = false
        handshakeAttempt = 0
        // Give the interface a moment after enumeration, then run the same
        // handshake the official app sends on connect.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.sendHandshake()
        }
    }

    private func sendHandshake() {
        handshakeAttempt += 1
        // If the burst is lost the popover would sit blank until replug, so
        // retry a couple of times until the device answers.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !self.receivingReports, self.handshakeAttempt < 3,
                  case .connected = self.connection else { return }
            DebugLog.shared.log("no response — retrying handshake (\(self.handshakeAttempt + 1))")
            self.sendHandshake()
        }

        hid.send(.reqInitData, QxInit.requestPayload)   // [0, 0, At.Req]
        // sys is included for dd.eq_mode — needed to detect 20-band mode.
        hid.send(.reqDevConfig, [QxConfigMask.sys | QxConfigMask.playTime
                                 | QxConfigMask.dac | QxConfigMask.mic | QxConfigMask.batt])
        hid.send(.reqDevConfig, [0xC0])                 // sys2 | eq
        // audio | power | conn | vol — sample rate, battery, and current volume.
        hid.send(.reqDevStatus, [QxStatusMask.audio | QxStatusMask.power
                                 | QxStatusMask.conn | QxStatusMask.vol])
        hid.send(.reqEqPreset, [eqGroup.requestMask])
    }

    // MARK: - RX

    /// Report framing: [payloadLen, cmdHi, cmdLo, data...] — the leading
    /// report-ID byte is already stripped by HIDTransport.
    private func handlePacket(_ bytes: [UInt8]) {
        guard bytes.count >= 3 else { return }
        guard let (cmdId, data) = QxPacket.parseRx(bytes) else { return }
        // Only a packet we could actually parse counts as the device answering;
        // otherwise stray garbage cancels the handshake retry at `start()`.
        receivingReports = true
        dispatch(cmdId, data)
    }

    private func dispatch(_ cmdId: UInt16, _ data: [UInt8]) {
        DebugLog.shared.rx(cmdId, data)

        switch QxCmd(rawValue: cmdId) {
        case .rspInitData:
            if QxStatusParser.parseInitData(data, into: &state) { applyState() }
        case .rspDevStatus:
            _ = QxStatusParser.parseDevStatus(data, into: &state)
            applyState()
        case .rspDevConfig:
            _ = QxStatusParser.parseDevConfig(data, into: &state)
            applyState()
        case .rspEqPreset, .rspEqPresetL, .rspEqPresetH:
            if assembler.ingest(data) {
                applyPreset(QxUserEqPreset.decode(assembler.buffer, group: eqGroup))
                assembler.reset()
            }
        case .rspEqPresetName:
            parsePresetName(data)
        case .notification:
            parseNotification(data)
        default:
            break
        }
    }

    /// Notification (0x2000), fw >= 3: byte0 >= 128 → EQ (Et sub-param,
    /// then group byte); byte0 < 128 → [_, St flags, blocks...].
    private func parseNotification(_ data: [UInt8]) {
        guard data.count >= 2 else { return }
        if data[0] >= 128 {
            let group = data[1]
            guard group == eqGroup.rawValue || data[0] == 129 else { return }
            switch data[0] {
            case 129: if data.count >= 3 { setActivePreset(Int(data[2])) }  // eqPresetIdx
            case 130: if data.count >= 3 { eqEnabled = data[2] != 0 }       // eqEnable
            default: break
            }
        } else {
            let flags = data[1]
            var off = 2
            if flags & QxNotifyMask.status != 0 {
                off += QxStatusParser.parseDevStatus(data.tail(from: off), into: &state)
            }
            if flags & QxNotifyMask.config != 0 {
                _ = QxStatusParser.parseDevConfig(data.tail(from: off), into: &state)
            }
            applyState()
        }
    }

    /// RspEqPresetName, fw >= 3: [group, index, endOffset, utf8...]
    private func parsePresetName(_ data: [UInt8]) {
        guard data.count >= 3, data[0] == eqGroup.rawValue else { return }
        let idx = Int(data[1])
        guard (0..<Self.presetCount).contains(idx) else { return }
        let end = min(Int(data[2]), data.count)
        guard end > 3 else { return }
        let nameBytes = data[3..<end].prefix { $0 != 0 }
        guard let raw = String(bytes: nameBytes, encoding: .utf8) else { return }
        let name = Self.displayName(raw)
        if !name.isEmpty { presetNames[idx] = name }
    }

    /// Longest preset name the popover will show. The device's own field is
    /// bounded by the report size; this is about the row staying one line.
    nonisolated static let maxPresetNameLength = 32

    /// Names are stored on the device, so they are attacker-supplied in the
    /// same sense every other field is. Control and format scalars are dropped
    /// rather than escaped — a U+202E override would visually reorder the rows
    /// around it, and a newline would stretch the row.
    nonisolated static func displayName(_ s: String) -> String {
        let kept = s.unicodeScalars.filter { u in
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
        return String(String.UnicodeScalarView(kept))
            .trimmingCharacters(in: .whitespaces)
            .prefix(maxPresetNameLength)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Decide whether we may write to this device, from what the handshake told
    /// us. Only positive identification enables writing.
    private func evaluateCompatibility() {
        // Nothing conclusive yet — RspInitData hasn't landed.
        guard state.deviceId != 0, let major = state.fwMajor else { return }

        if state.deviceId != QxDeviceModel.qudelix5K {
            let known = QxDeviceModel.name(for: state.deviceId)
            compatibility = .unsupported(
                title: "\(known) isn't supported",
                detail: "This app implements the original Qudelix 5K protocol. "
                      + "\(known) uses a different EQ command set, so nothing will be written.")
            return
        }
        if major < 2 {
            compatibility = .unsupported(
                title: "Firmware \(state.fwVersion ?? "?") is too old",
                detail: "Update the 5K with the official Qudelix app, then reconnect.")
            return
        }
        if major == 2 {
            compatibility = .unsupported(
                title: "Firmware \(state.fwVersion ?? "2.x") uses a different protocol",
                detail: "Qudelix changed the EQ command format in firmware 3. "
                      + "Update with the official app, then reconnect.")
            return
        }
        compatibility = .ok
    }

    private func applyState() {
        evaluateCompatibility()
        if let mode = state.eqMode { setEqGroup(mode == 1 ? .b20 : .user) }
        if let fw = state.fwVersion { firmwareVersion = fw }
        if let b = state.batteryPercent { batteryPercent = b }
        charging = state.charging
        if let sr = state.sampleRateLabel { sampleRate = sr }
        if let src = state.inputSourceLabel { inputSource = src }
        if let m = state.usbMute { muted = m }
        if let en = state.eqEnabled { eqEnabled = en }
        if let idx = state.eqPresetIdx { setActivePreset(idx) }
        volumeMax = state.dacOutPwr2Vrms ? min(state.volumeLimitDb ?? 6, 6)
                                         : min(state.volumeLimitDb ?? 0, 0)
        // After volumeMax, so the slider's value always sits inside its range —
        // the device reports level and limit independently and can disagree.
        if let v = state.volumeDb {
            volumeDb = min(max(v, volumeRange.lowerBound), volumeRange.upperBound)
        }

        let compat: String
        switch compatibility {
        case .checking: compat = "checking"
        case .ok: compat = "ok"
        case .unsupported(let t, _): compat = "UNSUPPORTED(\(t))"
        }
        DebugLog.shared.log("compat=\(compat) model=\(state.deviceId) eqMode=\(state.eqMode.map(String.init) ?? "?")")
        DebugLog.shared.log("state: fw=\(firmwareVersion ?? "?") batt=\(batteryPercent.map { "\($0)%" } ?? "?")"
            + " vol=\(state.volumeDb.map { String(format: "%.1fdB", $0) } ?? "?")"
            + " max=\(String(format: "%.0f", volumeMax)) sr=\(sampleRate ?? "?") src=\(inputSource ?? "?")"
            + " eq=\(eqEnabled ? "on" : "off") preset=\(activePreset.map(String.init) ?? "?")"
            + " nameMask=\(String(state.presetNameMask, radix: 2))")

        // Fetch saved preset names once the name mask is known.
        if !requestedNames, state.presetNameMask != 0 {
            requestedNames = true
            for i in 0..<Self.presetCount where state.presetNameMask & (1 << i) != 0 {
                hid.send(.reqEqPresetName, [eqGroup.rawValue, UInt8(i)])
            }
        }
    }

    private func applyPreset(_ p: QxUserEqPreset) {
        guard p.bands.count == bandCount else { return }
        // The 20-band layout is derived from the firmware's parser but has not
        // been run against real hardware. If it decodes to nonsense, keep the
        // defaults rather than presenting garbage as the device's curve —
        // writing is unaffected either way.
        guard p.looksPlausible else {
            DebugLog.shared.log("preset decode implausible for group \(eqGroup) — ignoring")
            return
        }
        // `looksPlausible` is deliberately wider than the editor's range, so a
        // real device reporting a curve we can't represent still shows up
        // instead of being discarded. Clamp it to what the sliders can express
        // and what `updateBand` would write back, so the displayed and exported
        // curve is one we could actually reproduce.
        preGain = min(max(p.preGain, -12), 12)
        bands = p.bands.map { band in
            var v = band
            v.freq = max(20, min(20000, v.freq))
            v.gain = v.gain.isFinite ? max(-12, min(12, v.gain)) : 0
            v.q = v.q.isFinite ? max(0.1, min(10, v.q)) : 1.0
            return v
        }
    }

    #if DEBUG
    /// UIPreview only: force a group without a device attached.
    func applyPreviewGroup(_ group: QxEqGroup) {
        eqGroup = group
        assembler.group = group
    }
    #endif

    /// The device reports which preset slot is active. Out-of-range values are
    /// dropped rather than stored: nothing indexes an array with this, but a
    /// bogus index silently un-highlights every row.
    private func setActivePreset(_ idx: Int) {
        guard (0..<Self.presetCount).contains(idx) else { return }
        activePreset = idx
    }

    /// Rate limit for EQ-group switches. Each switch clears the cached preset
    /// names and re-requests up to 20 of them, and every send costs ~20 ms of
    /// transport queue time — so a device flipping `dd.eq_mode` in a loop can
    /// starve the user's own volume and EQ writes. Real mode changes are a
    /// human action; one per second is generous.
    private var lastGroupSwitch = Date.distantPast
    private static let groupSwitchInterval: TimeInterval = 1

    /// Re-target the EQ when the device reports a different mode.
    private func setEqGroup(_ group: QxEqGroup) {
        guard group != eqGroup else { return }
        guard Date().timeIntervalSince(lastGroupSwitch) >= Self.groupSwitchInterval else { return }
        lastGroupSwitch = Date()
        DebugLog.shared.log("EQ group → \(group) (\(group.bandCount) bands)")
        eqGroup = group
        assembler.group = group
        assembler.reset()
        bands = group.defaultFreqs.map {
            QxEqBandValue(filter: .peak, freq: $0, gain: 0, q: 1.0)
        }
        requestedNames = false
        presetNames = [:]
        hid.send(.reqEqPreset, [group.requestMask])
    }

    // MARK: - Actions

    /// Single gate for everything that writes to the hardware.
    private var canWrite: Bool {
        if case .connected = connection { return compatibility.canWrite }
        return false
    }

    func setVolume(_ db: Double) {
        guard canWrite, db.isFinite else { return }
        let clamped = max(volumeMax - 60, min(volumeMax, db))
        volumeDb = clamped
        let scaled = Int((clamped * QxScale.volume).rounded())
        hid.sendCoalesced(.setVolume,
                          [QxVolumeParam.sink.rawValue] + QxPacket.int16BE(scaled),
                          key: "volume")
    }

    func setMute(_ on: Bool) {
        guard canWrite else { return }
        muted = on
        hid.send(.setVolume, [QxVolumeParam.mute.rawValue, 0, on ? 1 : 0])
    }

    func setEqEnabled(_ on: Bool) {
        guard canWrite else { return }
        eqEnabled = on
        hid.send(.setEqEnable, [eqGroup.rawValue, on ? 1 : 0])
    }

    func loadPreset(_ index: Int) {
        guard canWrite, (0..<Self.presetCount).contains(index) else { return }
        activePreset = index
        assembler.reset()
        hid.send(.loadEqPreset, [UInt8(index)])
        hid.send(.reqEqPreset, [eqGroup.requestMask])   // refresh band values
    }

    /// Display name for a preset slot, falling back to its number.
    func presetLabel(_ index: Int) -> String {
        presetNames[index] ?? "Preset \(index + 1)"
    }

    /// Reset every band to flat (0 dB, default frequencies) and clear pre-gain.
    func flatten() {
        guard canWrite else { return }
        setPreGain(0)
        let defaults = eqGroup.defaultFreqs
        for i in 0..<bandCount {
            updateBand(i, QxEqBandValue(filter: .peak, freq: defaults[i], gain: 0, q: 1.0))
        }
        lastImportSummary = "Reset to flat"
    }

    func savePreset(_ index: Int) {
        guard canWrite, (0..<Self.presetCount).contains(index) else { return }
        hid.send(.saveEqPreset, [UInt8(index)])
    }

    func setPreGain(_ db: Double) {
        guard canWrite, db.isFinite else { return }
        let clamped = max(-12, min(12, db))
        preGain = clamped
        sendEqParam(.setEqPreGain, band: 0, scaled: Int((clamped * QxScale.gain).rounded()))
    }

    /// Every value written to the device is clamped here — a text field can
    /// produce anything, and out-of-range reports are what knock this hardware
    /// off the USB bus.
    func updateBand(_ index: Int, _ value: QxEqBandValue) {
        guard canWrite, bands.indices.contains(index), index < bandCount else { return }
        var v = value
        v.freq = max(20, min(20000, v.freq))
        v.gain = v.gain.isFinite ? max(-12, min(12, v.gain)) : 0
        v.q = v.q.isFinite ? max(0.1, min(10, v.q)) : 1.0
        bands[index] = v

        let payload: [UInt8] = [eqGroup.rawValue, QxEq.chMaskBoth, UInt8(index), v.filter.rawValue]
            + QxPacket.int16BE(v.freq)
            + QxPacket.int16BE(Int((v.gain * QxScale.gain).rounded()))
            + QxPacket.int16BE(Int((v.q * QxScale.q).rounded()))
        hid.sendCoalesced(.setEqBandParam, payload, key: "band\(index)")
    }

    // MARK: - Preset import / export

    /// Push a parsed parametric-EQ file to the device: pre-gain, then every
    /// band, then any unused bands bypassed so leftovers from the previous
    /// preset can't linger.
    func apply(_ file: ParametricEQFile) {
        guard canWrite else {
            lastImportSummary = "Not applied — this device isn't supported."
            return
        }
        if !eqEnabled { setEqEnabled(true) }
        hid.send(.setEqType, [eqGroup.rawValue, 1])   // 1 = PEQ
        setPreGain(max(-12, min(12, file.preamp)))

        for i in 0..<bandCount {
            if i < file.bands.count {
                var b = file.bands[i]
                b.gain = max(-12, min(12, b.gain))
                b.q = max(0.1, min(10, b.q))
                b.freq = max(20, min(20000, b.freq))
                updateBand(i, b)
            } else {
                var b = bands[i]
                b.filter = .bypass
                updateBand(i, b)
            }
        }
        lastImportSummary = "Applied \(file.bands.count) band(s), pre-gain "
            + String(format: "%+.1f dB", file.preamp)
            + (file.droppedBands > 0 ? " · \(file.droppedBands) extra band(s) dropped" : "")
        DebugLog.shared.log("import: \(lastImportSummary ?? "")")
    }

    /// EQ files are a few hundred bytes; refuse anything absurd rather than
    /// reading an arbitrary user-picked file entirely into memory.
    static let maxImportBytes = 1_000_000

    func importFile(at url: URL) {
        do {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maxImportBytes else {
                lastImportSummary = "That file is too large to be an EQ preset."
                return
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                lastImportSummary = "Could not read \(url.lastPathComponent) as text."
                return
            }
            guard let parsed = ParametricEQFile.parse(text) else {
                lastImportSummary = "No filters found in \(url.lastPathComponent)"
                return
            }
            apply(parsed)
        } catch {
            lastImportSummary = "Could not read file: \(error.localizedDescription)"
        }
    }

    /// Serialise the current bands in the same format we import.
    func exportText() -> String {
        var lines = [String(format: "Preamp: %.1f dB", preGain)]
        for (i, b) in bands.enumerated() {
            let token: String
            switch b.filter {
            case .peak: token = "PK"
            case .lowShelf: token = "LSC"
            case .highShelf: token = "HSC"
            case .lpf: token = "LPQ"
            case .hpf: token = "HPQ"
            case .bypass: continue
            }
            lines.append(String(format: "Filter %d: ON %@ Fc %d Hz Gain %.1f dB Q %.2f",
                                i + 1, token, b.freq, b.gain, b.q))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func refresh() {
        guard case .connected = connection else { return }
        // Read requests are safe on any model; only writes are gated.
        // Same curated mask as the handshake. `Yc.all` (0xFF) would set the
        // runtimeEq bit the firmware never uses plus an undefined bit 0x80,
        // and this device drops off the bus when it dislikes a report.
        hid.send(.reqDevStatus, [QxStatusMask.audio | QxStatusMask.power
                                 | QxStatusMask.conn | QxStatusMask.vol])
        hid.send(.reqEqPreset, [eqGroup.requestMask])
    }

    private func sendEqParam(_ cmd: QxCmd, band: Int, scaled: Int) {
        hid.sendCoalesced(cmd,
                          [eqGroup.rawValue, QxEq.chMaskBoth, UInt8(clamping: band)]
                            + QxPacket.int16BE(scaled),
                          key: "\(cmd)-\(band)")
    }
}

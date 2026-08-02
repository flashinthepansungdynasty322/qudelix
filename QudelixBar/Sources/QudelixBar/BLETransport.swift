import Foundation
import CoreBluetooth

/// BLE transport for the Qudelix 5K. Not wired up yet — the app drives the
/// device over USB HID (see `QudelixController`), because the 5K's BLE endpoint
/// speaks Qualcomm GAIA and does not accept Qudelix commands directly.
///
/// The GATT layout is discovered at runtime and logged. Adoption is deliberately
/// narrow: only the GAIA service, only its command and response characteristics,
/// and only when those characteristics really carry the properties their UUIDs
/// imply. Since every byte of a BLE advertisement is chosen by the advertiser,
/// the first device to complete a link is pinned by identifier and nothing else
/// is adopted afterwards — see `pinnedIdentifier`.
final class BLETransport: NSObject {
    /// Qualcomm GAIA v2/v3 service + endpoints (the likely candidate).
    static let gaiaService = CBUUID(string: "00001100-D102-11E1-9B23-00025B00A5A5")
    static let gaiaCommand = CBUUID(string: "00001101-D102-11E1-9B23-00025B00A5A5")
    static let gaiaResponse = CBUUID(string: "00001102-D102-11E1-9B23-00025B00A5A5")

    enum Framing: String { case raw, hidStyle }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var loggedPeripherals = Set<UUID>()
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private(set) var framing: Framing = .raw

    var onConnected: ((String) -> Void)?
    var onDisconnected: (() -> Void)?
    var onPacket: (([UInt8]) -> Void)?

    var isConnected: Bool { writeChar != nil && notifyChar != nil }

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func setFraming(_ f: Framing) {
        framing = f
        DebugLog.shared.log("BLE framing → \(f.rawValue)")
    }

    func send(_ cmd: QxCmd, _ data: [UInt8] = []) {
        guard let p = peripheral, let c = writeChar else {
            DebugLog.shared.log("BLE send dropped (not connected): \(cmd)")
            return
        }
        let payload = QxPacket.payload(cmd, data)
        let bytes: [UInt8]
        switch framing {
        case .raw:
            bytes = payload
        case .hidStyle:
            bytes = [UInt8(payload.count + 1), 0x80] + payload
        }
        DebugLog.shared.tx(cmd, data)
        let type: CBCharacteristicWriteType =
            c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data(bytes), for: c, type: type)
    }

    /// Identifier of the peripheral this app has already linked with.
    ///
    /// Trust on first use. A BLE advertisement is entirely attacker-controlled:
    /// the local name is a free-form string, and the GAIA service UUID is a
    /// generic Qualcomm identifier that many unrelated devices expose, so
    /// "named Qudelix, speaks GAIA" is not an identity. Once a link has been
    /// established the peripheral's identifier is remembered, and from then on
    /// nothing else is adopted — a spoofer has to win the very first
    /// connection, not merely be in radio range later.
    private static let pinnedKey = "BLEPinnedPeripheral"

    private var pinnedIdentifier: UUID? {
        get { UserDefaults.standard.string(forKey: Self.pinnedKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.pinnedKey) }
    }

    /// Forget the pinned device — for a "connect to a different 5K" affordance.
    func forgetPinnedDevice() {
        UserDefaults.standard.removeObject(forKey: Self.pinnedKey)
        DebugLog.shared.log("BLE pinned device cleared")
    }

    /// Whether this peripheral may be adopted at all. Once pinned, identity is
    /// the only question; before that, the name is a filter and the real check
    /// happens against the GATT database in `didDiscoverCharacteristicsFor`.
    private func isAdoptable(_ p: CBPeripheral, advertisedName: String? = nil) -> Bool {
        if let pinned = pinnedIdentifier { return p.identifier == pinned }
        let name = advertisedName ?? p.name ?? ""
        return name.localizedCaseInsensitiveContains("qudelix")
    }

    private func beginScan() {
        DebugLog.shared.log("BLE scanning…")
        // A known device can be reconnected by identifier without scanning, and
        // without any name matching being involved.
        if let pinned = pinnedIdentifier,
           let known = central.retrievePeripherals(withIdentifiers: [pinned]).first {
            DebugLog.shared.log("BLE reconnecting to pinned device")
            adopt(known)
            return
        }
        // The 5K may already be connected at the system level — check first.
        // `withServices:` matches on the generic GAIA UUID, which any Qualcomm
        // audio device may expose, so the candidate still has to be adoptable.
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.gaiaService])
        if let p = connected.first(where: { isAdoptable($0) }) {
            DebugLog.shared.log("BLE found system-connected: \(p.name ?? "?")")
            adopt(p)
            return
        }
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    private func adopt(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        central.stopScan()
        central.connect(p, options: nil)
    }
}

extension BLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DebugLog.shared.log("BLE state: \(central.state.rawValue)")
        if central.state == .poweredOn { beginScan() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let advServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []

        if loggedPeripherals.insert(p.identifier).inserted {
            let svc = advServices.isEmpty ? "" : " services=[\(advServices.map(\.uuidString).joined(separator: ","))]"
            DebugLog.shared.log("BLE seen: \(name.isEmpty ? "(unnamed)" : name)\(svc) rssi=\(RSSI)")
        }

        // Everything here is advertiser-controlled, so this is a filter to
        // decide what is worth connecting to — never a decision that the
        // peripheral is genuine. That comes from the GATT database below, and
        // from the pin once one exists. A device that advertises no service
        // UUIDs at all is still worth probing, since the 5K may not list them.
        guard isAdoptable(p, advertisedName: name) else { return }
        guard advServices.isEmpty || advServices.contains(Self.gaiaService) else { return }
        DebugLog.shared.log("BLE candidate: \(name) rssi=\(RSSI)")
        adopt(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        DebugLog.shared.log("BLE connected: \(p.name ?? "?") — discovering services")
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        DebugLog.shared.log("BLE connect failed: \(error?.localizedDescription ?? "?")")
        peripheral = nil
        beginScan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        DebugLog.shared.log("BLE disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        onDisconnected?()
        beginScan()
    }
}

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = p.services else { return }
        for s in services {
            DebugLog.shared.log("BLE service: \(s.uuid)")
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            DebugLog.shared.log("BLE char: \(service.uuid) / \(c.uuid) props=\(describe(c.properties))")
        }
        // Only the GAIA service. Adopting "any service with a writable and a
        // notifying characteristic" would send this protocol to whatever
        // unrelated endpoint happened to match.
        guard service.uuid == Self.gaiaService else { return }
        // The UUID says what a characteristic claims to be; the properties say
        // what it can actually do. Requiring both means a peripheral that
        // merely mirrors the GAIA UUIDs back at us doesn't get adopted.
        let writable = chars.first {
            $0.uuid == Self.gaiaCommand
                && !$0.properties.intersection([.write, .writeWithoutResponse]).isEmpty
        }
        let notifying = chars.first {
            $0.uuid == Self.gaiaResponse
                && !$0.properties.intersection([.notify, .indicate]).isEmpty
        }
        if let w = writable, let n = notifying, writeChar == nil {
            writeChar = w
            notifyChar = n
            p.setNotifyValue(true, for: n)
            // CoreBluetooth pairs only when the peripheral demands encryption,
            // and nothing here can force it. Worth recording which link we got:
            // an unencrypted one is readable by anyone in range.
            let encrypted = n.properties
                .intersection([.notifyEncryptionRequired, .indicateEncryptionRequired])
            if encrypted.isEmpty {
                DebugLog.shared.log("BLE link is unencrypted (peripheral does not require pairing)")
            }
            if pinnedIdentifier == nil {
                pinnedIdentifier = p.identifier
                DebugLog.shared.log("BLE pinned this device for future sessions")
            }
            DebugLog.shared.log("BLE adopted GAIA link: tx=\(w.uuid) rx=\(n.uuid)")
            onConnected?(p.name ?? "Qudelix 5K")
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        DebugLog.shared.log("BLE notify \(c.uuid): \(error.map { "error \($0.localizedDescription)" } ?? (c.isNotifying ? "on" : "off"))")
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, let data = c.value else { return }
        onPacket?([UInt8](data))
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let e = error { DebugLog.shared.log("BLE write error: \(e.localizedDescription)") }
    }

    private func describe(_ props: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if props.contains(.read) { out.append("read") }
        if props.contains(.write) { out.append("write") }
        if props.contains(.writeWithoutResponse) { out.append("writeNR") }
        if props.contains(.notify) { out.append("notify") }
        if props.contains(.indicate) { out.append("indicate") }
        return out.joined(separator: ",")
    }
}

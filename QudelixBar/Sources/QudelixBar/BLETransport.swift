import Foundation
import CoreBluetooth

/// BLE transport for the Qudelix 5K — the officially supported control path
/// on macOS (the USB HID path crashes the device's USB stack; see docs/).
///
/// GATT layout is discovered at runtime and logged. QCC-chip devices usually
/// expose the Qualcomm GAIA service; Qudelix may use a custom service. We
/// pick the first service that has both a writable and a notifying
/// characteristic, subscribe, and speak the same command protocol.
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

    private func beginScan() {
        DebugLog.shared.log("BLE scanning…")
        // The 5K may already be connected at the system level — check first.
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.gaiaService])
        if let p = connected.first {
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

        // Require both: "5k" alone is a very common substring, and adopting the
        // wrong peripheral would mean writing Qudelix commands to it.
        let nameMatch = name.localizedCaseInsensitiveContains("qudelix")
        let serviceMatch = advServices.isEmpty || advServices.contains(Self.gaiaService)
        guard nameMatch, serviceMatch else { return }
        DebugLog.shared.log("BLE discovered Qudelix: \(name) rssi=\(RSSI)")
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
        let writable = chars.first { $0.uuid == Self.gaiaCommand }
        let notifying = chars.first { $0.uuid == Self.gaiaResponse }
        if let w = writable, let n = notifying, writeChar == nil {
            writeChar = w
            notifyChar = n
            p.setNotifyValue(true, for: n)
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

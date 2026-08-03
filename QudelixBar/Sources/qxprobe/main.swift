import Foundation
import CoreBluetooth

// Standalone BLE probe for the Qudelix 5K GAIA endpoint.
//
// SAFETY: no blind GAIA command enumeration. The hazardous IDs, checked against
// the public ADK 4.0 `gaia` library source rather than guessed, are:
//
//   0x0104 FACTORY_DEFAULT_RESET   0x0202 DEVICE_RESET   0x0204 SET_POWER_STATE
//   0x0712 STORE_PS_KEY  0x0713 FLOOD_PS  0x0714 STORE_FULL_PS_KEY  (can brick)
//   0x0750 DELETE_PDL (wipes pairings)    0x0630-0x0634 / 0x0640-0x0643 (DFU)
//
// (An earlier note here claimed 0x0100 was DEVICE_RESET. It is not — 0x0100 is
// SET_RAW_CONFIGURATION. The real hazards are the ones listed above.)
//
// The trap worth knowing: Qudelix's own command IDs collide with those. Their
// SetLedMode is 0x0202, SetWarrantyExtension is 0x0104, ReqEqData is 0x0750. So
// sending a *native* Qudelix ID under vendor 0x000A can reboot the device or
// erase its paired-device list. The library only enters its built-in handlers
// when the vendor is 0x000A (gaiaProcessCommand), so probing under any other
// vendor ID cannot reach them — GAIA_VENDOR_NONE (0x7FFE) is the safe choice.
//
// Everything sent here is a getter, or Qudelix's own read-only ReqInitData.
//
// Each probe is delivered only while the link is actually up, and the probe
// list resumes across reconnects (the device drops the link every few seconds).

let SERVICE = CBUUID(string: "00001100-D102-11E1-9B23-00025B00A5A5")
let CMD_CHAR = CBUUID(string: "00001101-D102-11E1-9B23-00025B00A5A5")   // write
let RSP_CHAR = CBUUID(string: "00001102-D102-11E1-9B23-00025B00A5A5")   // read, notify
let DATA_CHAR = CBUUID(string: "00001103-D102-11E1-9B23-00025B00A5A5")  // read, writeNR, notify

// ReqInitData = 0x0100 with payload [0x00, 0x00, At.Req(4)]
let REQ_INIT: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x04]

/// Qualcomm's own vendor ID — the only value that reaches GAIA's built-in
/// command handlers, and therefore the only value that can be dangerous.
let GAIA_VENDOR_CSR: UInt16 = 0x000A
/// GAIA_VENDOR_NONE. Routed straight to the customer application, so command
/// IDs sent under it cannot hit a built-in reset, power-off, or flash write.
let GAIA_VENDOR_NONE: UInt16 = 0x7FFE
/// Qudelix's own GAIA vendor ID, read out of the official iOS app's binary
/// (`Qudelix_gaia.vendorID`, a UInt16 initialised to 0xF003). Commands sent
/// under it reach Qudelix's handler instead of Qualcomm's built-ins.
let QUDELIX_VENDOR: UInt16 = 0xF003
/// The alternative the same code path can select (`mov w5, #0xf001`); the app
/// branches between the two, presumably on device model or protocol generation.
let QUDELIX_VENDOR_ALT: UInt16 = 0xF001

struct Probe {
    let label: String
    let bytes: [UInt8]
    let onData: Bool   // send to 1103 rather than 1101
}

/// GAIA short framing: [vendor BE][command BE][payload].
func gaia(_ cmd: UInt16, _ payload: [UInt8] = [], vendor: UInt16 = GAIA_VENDOR_CSR) -> [UInt8] {
    [UInt8(vendor >> 8), UInt8(vendor & 0xFF), UInt8(cmd >> 8), UInt8(cmd & 0xFF)] + payload
}

let probes: [Probe] = [
    // The answer, lifted out of the official app's own binary: its Qudelix_gaia
    // class stores a UInt16 `vendorID` of 0xF003. Because that is not 0x000A,
    // the gaia library never enters its built-in command switch and hands the
    // whole packet to Qudelix's handler — which is how their protocol tunnels.
    // Both commands below are read requests.
    Probe(label: "1101 vendor F001 ReqInitData",
          bytes: gaia(0x0100, [0x00, 0x00, 0x04], vendor: QUDELIX_VENDOR_ALT), onData: false),
    Probe(label: "1101 vendor F001 ReqDevStatus(conn)",
          bytes: gaia(0x0110, [0x04], vendor: QUDELIX_VENDOR_ALT), onData: false),
    Probe(label: "1101 vendor F003 ReqInitData",
          bytes: gaia(0x0100, [0x00, 0x00, 0x04], vendor: QUDELIX_VENDOR), onData: false),
    Probe(label: "1101 vendor F003 ReqDevStatus(conn)",
          bytes: gaia(0x0110, [0x04], vendor: QUDELIX_VENDOR), onData: false),

    // Baseline: the one exchange known to work, on the endpoint that actually
    // answers. GAIA GET_API_VERSION (0x0300) is a read-only status query.
    Probe(label: "1101 GET_API_VERSION (baseline)", bytes: gaia(0x0300), onData: false),

    // Read-only queries, verified against the public ADK 4.0 gaia library
    // source. All are getters: none resets, powers off, or writes flash.
    // GET_HOST_FEATURE_INFORMATION is the discovery probe that matters — it is
    // GAIA v1's way of asking what the device actually supports.
    Probe(label: "1101 GET_HOST_FEATURE_INFORMATION", bytes: gaia(0x0320), onData: false),
    Probe(label: "1101 GET_HOST_FEATURE_INFORMATION(0)", bytes: gaia(0x0320, [0x00]), onData: false),
    Probe(label: "1101 GET_AUTH_BITMAPS", bytes: gaia(0x0580), onData: false),
    Probe(label: "1101 GET_SESSION_ENABLE", bytes: gaia(0x0584), onData: false),
    Probe(label: "1101 GET_APPLICATION_VERSION", bytes: gaia(0x0304), onData: false),
    Probe(label: "1101 GET_MODULE_ID", bytes: gaia(0x0303), onData: false),
    // The data endpoint (1103) — GAIA's bulk channel. Prime suspect.
    Probe(label: "1103 raw Qudelix", bytes: REQ_INIT, onData: true),
    Probe(label: "1103 hid-style [len+1,0x80,...]",
          bytes: [UInt8(REQ_INIT.count + 1), 0x80] + REQ_INIT, onData: true),
    Probe(label: "1103 len-prefixed [len,...]",
          bytes: [UInt8(REQ_INIT.count)] + REQ_INIT, onData: true),
    Probe(label: "1103 gaia getApiVersion", bytes: [0x00, 0x0A, 0x03, 0x00], onData: true),
    // Command endpoint with the USB framing, for completeness.
    Probe(label: "1101 hid-style [len+1,0x80,...]",
          bytes: [UInt8(REQ_INIT.count + 1), 0x80] + REQ_INIT, onData: false),
    Probe(label: "1101 raw Qudelix", bytes: REQ_INIT, onData: false),
]

/// `--enumerate` dumps the GATT database and writes nothing.
let enumerateOnly = CommandLine.arguments.contains("--enumerate")

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date())
}
func note(_ s: String) { print("\(stamp()) \(s)"); fflush(stdout) }

final class Prober: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var cmdChar, dataChar, rspChar: CBCharacteristic?
    var index = 0
    var ready = false
    var gotAnyReply = false
    var pendingServices = 0

    func run() { central = CBCentralManager(delegate: self, queue: .main) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return }
        note("scanning…")
        c.scanForPeripherals(withServices: nil)
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard (p.name ?? "").localizedCaseInsensitiveContains("qudelix") else { return }
        note("found \(p.name!) rssi=\(rssi)")
        // Passive: dump the whole advertisement. Manufacturer-specific data
        // leads with a 16-bit Bluetooth company identifier, and if Qudelix hold
        // one, that is the likeliest vendor ID for their own GAIA handler.
        for (k, v) in advertisementData.sorted(by: { $0.key < $1.key }) {
            if let d = v as? Data {
                var line = "    adv \(k): \(hex([UInt8](d)))"
                if k == CBAdvertisementDataManufacturerDataKey, d.count >= 2 {
                    // Company ID is little-endian per the Core Bluetooth spec.
                    let company = Int(d[0]) | Int(d[1]) << 8
                    line += String(format: "   -> company id 0x%04X", company)
                }
                note(line)
            } else {
                note("    adv \(k): \(v)")
            }
        }
        c.stopScan()
        peripheral = p; p.delegate = self
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        note("connected")
        ready = false
        // nil, not [SERVICE]: on USB, Qudelix's protocol rides parallel HID
        // report IDs beside GAIA's rather than inside them, so a proprietary
        // GATT service alongside the GAIA one is the obvious BLE analogue.
        // Filtering to the GAIA service would hide exactly that.
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        ready = false
        note("disconnected — resuming at probe \(index + 1) after reconnect")
        c.connect(p)
    }

    func describe(_ props: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if props.contains(.read) { out.append("read") }
        if props.contains(.write) { out.append("write") }
        if props.contains(.writeWithoutResponse) { out.append("writeNR") }
        if props.contains(.notify) { out.append("notify") }
        if props.contains(.indicate) { out.append("indicate") }
        if props.contains(.authenticatedSignedWrites) { out.append("signedWrite") }
        if props.contains(.notifyEncryptionRequired) { out.append("notifyEnc") }
        if props.contains(.indicateEncryptionRequired) { out.append("indicateEnc") }
        if props.contains(.extendedProperties) { out.append("extended") }
        if props.contains(.broadcast) { out.append("broadcast") }
        return out.isEmpty ? "none" : out.joined(separator: ",")
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let services = p.services ?? []
        note("GATT: \(services.count) service(s)")
        pendingServices = services.count
        for s in services {
            note("  service \(s.uuid)\(s.uuid == SERVICE ? "   <- GAIA" : "")"
                 + (s.isPrimary ? "" : " (secondary)"))
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            note("    char \(s.uuid) / \(c.uuid)  props=\(describe(c.properties))")
            switch c.uuid {
            case CMD_CHAR: cmdChar = c
            case DATA_CHAR: dataChar = c
            case RSP_CHAR: rspChar = c
            default: break
            }
            if c.properties.contains(.notify) { p.setNotifyValue(true, for: c) }
            if c.properties.contains(.read) { p.readValue(for: c) }
        }
        pendingServices -= 1
        if enumerateOnly {
            // Structure only — no probe writes at all. Give reads a moment to
            // land, then stop; the device tears the link down after ~5 s anyway.
            if pendingServices <= 0 {
                note("enumeration complete — collecting reads for 3s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { note("done"); exit(0) }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard p.state == .connected else { return }
            self.ready = true
            self.next()
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let d = c.value, !d.isEmpty else { return }
        let ep = c.uuid == RSP_CHAR ? "1102" : (c.uuid == DATA_CHAR ? "1103" : "1101")
        gotAnyReply = true
        note("    RX[\(ep)] \(hex([UInt8](d)))   \(interpret([UInt8](d)))")
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let e = error { note("    write error: \(e.localizedDescription)") }
    }

    func interpret(_ b: [UInt8]) -> String {
        // Qudelix native reply? [len, cmdHi, cmdLo, ...] or [cmdHi, cmdLo, ...]
        if b.count >= 3 {
            let rawCmd = Int(b[0]) << 8 | Int(b[1])
            if rawCmd == 0x0101 { return "★ Qudelix RspInitData (raw framing)!" }
            let framedCmd = Int(b[1]) << 8 | Int(b[2])
            if framedCmd == 0x0101 { return "★ Qudelix RspInitData (len-prefixed)!" }
        }
        guard b.count >= 4 else { return "" }
        let vendor = Int(b[0]) << 8 | Int(b[1])
        let cmd = Int(b[2]) << 8 | Int(b[3])
        guard cmd & 0x8000 != 0 else { return "not an ack" }
        let names = ["SUCCESS", "NOT_SUPPORTED", "NOT_AUTHENTICATED", "INSUFFICIENT_RESOURCES",
                     "AUTHENTICATING", "INVALID_PARAMETER", "INCORRECT_STATE", "IN_PROGRESS"]
        let st = b.count > 4 ? Int(b[4]) : -1
        let name = (0..<names.count).contains(st) ? names[st] : "status \(st)"
        return String(format: "gaia ack vendor=0x%04X cmd=0x%04X → %@", vendor, cmd & 0x7FFF, name)
    }

    func next() {
        guard ready, let p = peripheral, p.state == .connected else { return }
        guard index < probes.count else {
            note("all probes delivered — listening 6s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                note(self.gotAnyReply ? "done" : "done (no replies)")
                exit(0)
            }
            return
        }
        let probe = probes[index]
        guard let c = probe.onData ? dataChar : cmdChar else {
            note("skip \(probe.label): characteristic missing"); index += 1; next(); return
        }
        index += 1
        note("PROBE \(index)/\(probes.count) \(probe.label): TX \(hex(probe.bytes))")
        let type: CBCharacteristicWriteType =
            c.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(probe.bytes), for: c, type: type)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.next() }
    }
}

let prober = Prober()
prober.run()
DispatchQueue.main.asyncAfter(deadline: .now() + 90) { note("timeout"); exit(1) }
RunLoop.main.run()

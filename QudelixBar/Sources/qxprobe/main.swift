import Foundation
import CoreBluetooth

// Standalone BLE probe for the Qudelix 5K GAIA endpoint.
//
// SAFETY: no blind GAIA command enumeration. In the GAIA spec 0x0100 is
// DEVICE_RESET and nearby IDs include factory reset / DFU entry, so we only
// send the known-safe GET_API_VERSION (0x0300) plus Qudelix's own read-only
// ReqInitData through candidate framings. Nothing here writes settings.
//
// Each probe is delivered only while the link is actually up, and the probe
// list resumes across reconnects (the device drops the link every few seconds).

let SERVICE = CBUUID(string: "00001100-D102-11E1-9B23-00025B00A5A5")
let CMD_CHAR = CBUUID(string: "00001101-D102-11E1-9B23-00025B00A5A5")   // write
let RSP_CHAR = CBUUID(string: "00001102-D102-11E1-9B23-00025B00A5A5")   // read, notify
let DATA_CHAR = CBUUID(string: "00001103-D102-11E1-9B23-00025B00A5A5")  // read, writeNR, notify

// ReqInitData = 0x0100 with payload [0x00, 0x00, At.Req(4)]
let REQ_INIT: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x04]

struct Probe {
    let label: String
    let bytes: [UInt8]
    let onData: Bool   // send to 1103 rather than 1101
}

let probes: [Probe] = [
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
        c.stopScan()
        peripheral = p; p.delegate = self
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        note("connected")
        ready = false
        p.discoverServices([SERVICE])
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        ready = false
        note("disconnected — resuming at probe \(index + 1) after reconnect")
        c.connect(p)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        p.services?.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            switch c.uuid {
            case CMD_CHAR: cmdChar = c
            case DATA_CHAR: dataChar = c
            case RSP_CHAR: rspChar = c
            default: break
            }
            if c.properties.contains(.notify) { p.setNotifyValue(true, for: c) }
            if c.properties.contains(.read) { p.readValue(for: c) }
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

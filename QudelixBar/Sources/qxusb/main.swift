import Foundation
import IOKit.hid

// Qudelix 5K USB HID inspector / transport tester.
//
//   qxusb dump                        — parse and print the HID report descriptors (read-only)
//   qxusb test [options]              — open the vendor interface and exercise SET_REPORT
//
// test options:
//   --seize            open with kIOHIDOptionsTypeSeizeDevice (exclusive access)
//   --delay <ms>       gap between commands (default 300)
//   --count <n>        how many handshake commands to send (default 5)
//   --reportid <n>     output report ID (default 8)
//
// The 5K's control channel is finicky: a write that the firmware dislikes makes
// it stop responding and drop off the USB bus for a few seconds (audio glitches,
// then it re-enumerates). Nothing here changes device settings — only
// ReqInitData / ReqDevConfig / ReqDevStatus, which are read requests.

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date())
}
func note(_ s: String) { print("\(stamp()) \(s)"); fflush(stdout) }

func prop(_ d: IOHIDDevice, _ k: String) -> Any? { IOHIDDeviceGetProperty(d, k as CFString) }

func matchingDevices() -> [IOHIDDevice] {
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x0A12] as CFDictionary)
    IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    return (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>).map(Array.init) ?? []
}

func vendorInterface() -> IOHIDDevice? {
    matchingDevices().first { (prop($0, kIOHIDPrimaryUsagePageKey) as? Int) == 0xFF00 }
}

// MARK: - descriptor dump

struct Item { let tag: UInt8; let value: Int }

func items(_ bytes: [UInt8]) -> [Item] {
    var out: [Item] = []; var i = 0
    while i < bytes.count {
        let prefix = bytes[i]
        if prefix == 0xFE { guard i + 1 < bytes.count else { break }; i += 3 + Int(bytes[i + 1]); continue }
        var size = Int(prefix & 0x03); if size == 3 { size = 4 }
        var value = 0
        for j in 0..<size where i + 1 + j < bytes.count { value |= Int(bytes[i + 1 + j]) << (8 * j) }
        out.append(Item(tag: prefix & 0xFC, value: value))
        i += 1 + size
    }
    return out
}

func dump() {
    for (n, dev) in matchingDevices().enumerated() {
        let product = prop(dev, kIOHIDProductKey) as? String ?? "?"
        let up = prop(dev, kIOHIDPrimaryUsagePageKey) as? Int ?? -1
        print("\n══ device \(n + 1): \(product)  usagePage=\(String(format: "0x%04X", up))")
        for key in [kIOHIDMaxInputReportSizeKey, kIOHIDMaxOutputReportSizeKey,
                    kIOHIDMaxFeatureReportSizeKey, kIOHIDReportIntervalKey] {
            if let v = prop(dev, key) as? Int { print("   \(key) = \(v)") }
        }
        guard let data = prop(dev, "ReportDescriptor") as? Data else { continue }
        let bytes = [UInt8](data)
        print("   descriptor (\(bytes.count) B): \(hex(bytes))")
        var rid = 0, rsize = 0, rcount = 0
        var totals: [String: [Int: Int]] = [:]
        for it in items(bytes) {
            switch it.tag {
            case 0x84: rid = it.value
            case 0x74: rsize = it.value
            case 0x94: rcount = it.value
            case 0x80, 0x90, 0xB0:
                let kind = it.tag == 0x80 ? "INPUT" : (it.tag == 0x90 ? "OUTPUT" : "FEATURE")
                totals[kind, default: [:]][rid, default: 0] += rsize * rcount
            default: break
            }
        }
        for kind in ["INPUT", "OUTPUT", "FEATURE"] {
            guard let m = totals[kind], !m.isEmpty else { continue }
            print("   \(kind): " + m.keys.sorted().map { "id \($0)=\(m[$0]! / 8)B" }.joined(separator: ", "))
        }
    }
    print("")
}

// MARK: - transport test

final class Tester {
    let dev: IOHIDDevice
    let reportID: CFIndex
    /// Declared payload size for `reportID`; 63 is the 5K's report 8.
    var reportSize = 63

    /// Output report sizes by report ID, parsed from the descriptor.
    static func declaredOutputSizes(_ dev: IOHIDDevice) -> [Int: Int] {
        guard let data = prop(dev, "ReportDescriptor") as? Data else { return [:] }
        var sizes: [Int: Int] = [:]
        var rid = 0, rsize = 0, rcount = 0
        for it in items([UInt8](data)) {
            switch it.tag {
            case 0x84: rid = (0...255).contains(it.value) ? it.value : 0
            case 0x74: rsize = (0...4096).contains(it.value) ? it.value : 0
            case 0x94: rcount = (0...4096).contains(it.value) ? it.value : 0
            case 0x90:
                let (bits, over) = rsize.multipliedReportingOverflow(by: rcount)
                if !over { sizes[rid, default: 0] += bits / 8 }
            default: break
            }
        }
        return sizes
    }
    var inputBuf = [UInt8](repeating: 0, count: 1024)
    var rxCount = 0
    var onReport: (([UInt8]) -> Void)?

    init(dev: IOHIDDevice, reportID: Int) {
        self.dev = dev
        self.reportID = CFIndex(reportID)
    }

    func open(seize: Bool) -> Bool {
        let opts = seize ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : IOOptionBits(kIOHIDOptionsTypeNone)
        let r = IOHIDDeviceOpen(dev, opts)
        note("IOHIDDeviceOpen(seize: \(seize)) → \(r == kIOReturnSuccess ? "ok" : String(format: "0x%08X", UInt32(bitPattern: r)))")
        guard r == kIOReturnSuccess else { return false }

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, &inputBuf, inputBuf.count,
            { ctx, _, _, _, reportID, report, len in
                let me = Unmanaged<Tester>.fromOpaque(ctx!).takeUnretainedValue()
                var bytes = Array(UnsafeBufferPointer(start: report, count: len))
                if let f = bytes.first, Int(f) == Int(reportID) { bytes.removeFirst() }
                me.rxCount += 1
                note("    ◀ INPUT id=\(reportID): \(hex(Array(bytes.prefix(20))))")
                me.onReport?(bytes)
            }, ctx)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        return true
    }

    var includeReportID = true

    /// [len+1, 0x80, cmdHi, cmdLo, data...] zero-padded to the report size.
    ///
    /// IOKit gotcha: for devices with numbered reports, the buffer handed to
    /// IOHIDDeviceSetReport must START with the report ID (this is what hidapi
    /// does on macOS), even though the ID is also passed as its own argument.
    func send(_ label: String, cmd: UInt16, data: [UInt8]) -> Bool {
        var report = [UInt8](repeating: 0, count: reportSize)
        let payload: [UInt8] = [UInt8(cmd >> 8), UInt8(cmd & 0xFF)] + data
        report[0] = UInt8(payload.count + 1)
        report[1] = 0x80
        for (i, b) in payload.enumerated() { report[i + 2] = b }
        let buffer = includeReportID ? [UInt8(reportID)] + report : report

        let t0 = Date()
        let r = buffer.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, reportID, $0.baseAddress!, buffer.count)
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if r == kIOReturnSuccess {
            note("  ▶ \(label) ok (\(ms) ms)")
            return true
        }
        note("  ▶ \(label) FAILED 0x\(String(format: "%08X", UInt32(bitPattern: r))) after \(ms) ms")
        return false
    }

    func pump(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

// MARK: - main

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "dump"

func intArg(_ flag: String, _ fallback: Int) -> Int {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count, let v = Int(args[i + 1]) else { return fallback }
    return v
}

switch mode {
case "dump":
    dump()

case "test":
    guard let dev = vendorInterface() else {
        note("vendor (0xFF00) interface not found — is the 5K plugged in?")
        exit(1)
    }
    let seize = args.contains("--seize")
    let delayMs = intArg("--delay", 300)
    let count = intArg("--count", 5)
    let rid = intArg("--reportid", 8)
    guard (1...255).contains(rid) else { note("--reportid must be 1…255"); exit(2) }
    if rid != 8 {
        note("WARNING: report ID \(rid) uses a different declared size than 8 (63 B).")
        note("A wrong-length report makes the 5K stop responding and drop off the USB bus.")
    }
    if args.contains("--noid") {
        note("WARNING: --noid reproduces the known bus-drop bug on purpose.")
    }
    note("test: seize=\(seize) delay=\(delayMs)ms count=\(count) reportID=\(rid)")

    let t = Tester(dev: dev, reportID: rid)
    // Take the declared size for this report ID from the descriptor rather than
    // assuming 63 — IDs 1/5/7 are 65 bytes on the 5K.
    if let declared = Tester.declaredOutputSizes(dev)[rid], declared > 0 {
        t.reportSize = declared
        note("report \(rid) declared size: \(declared) B")
    }
    t.includeReportID = !args.contains("--noid")
    note("report ID in buffer: \(t.includeReportID)")
    guard t.open(seize: seize) else { exit(1) }

    // Read requests only — ReqInitData, then config/status queries.
    let seq: [(String, UInt16, [UInt8])] = [
        ("ReqInitData",   0x0100, [0x00, 0x00, 0x04]),
        ("ReqDevConfig",  0x0120, [0x3C]),
        ("ReqDevConfig",  0x0120, [0xC0]),
        ("ReqDevStatus",  0x0110, [0x04]),
        ("ReqEqPreset",   0x0123, [0x03]),
    ]

    for (i, step) in seq.prefix(count).enumerated() {
        let ok = t.send("\(i + 1). \(step.0)", cmd: step.1, data: step.2)
        if !ok { note("     (stopping — device stopped responding)"); break }
        t.pump(Double(delayMs) / 1000.0)
    }

    note("listening 4s for input reports…")
    t.pump(4)
    note("done — \(t.rxCount) input report(s) received")
    IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))

case "voltest":
    // Round-trip write test that changes nothing: read the current volume,
    // then set it to exactly that value and confirm the device echoes it back.
    guard let dev = vendorInterface() else { note("vendor interface not found"); exit(1) }
    let t = Tester(dev: dev, reportID: 8)
    var observed: Double?
    guard t.open(seize: false) else { exit(1) }

    t.onReport = { bytes in
        // [len, cmdHi, cmdLo, data...]
        guard bytes.count >= 4 else { return }
        let cmd = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
        let data = Array(bytes.dropFirst(3))
        func volFrom(_ block: [UInt8]) -> Double? {
            guard block.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(block[0]) | UInt16(block[1]) << 8)) / 60.0
        }
        if cmd == 0x0111, data.first == 0x40 {           // RspDevStatus, vol block
            observed = volFrom(Array(data.dropFirst()))
            note("    current volume = \(observed.map { String(format: "%.2f dB", $0) } ?? "?")")
        } else if cmd == 0x2000 {                        // Notification
            note("    notification: \(hex(Array(data.prefix(12))))")
        }
    }

    _ = t.send("ReqDevStatus(vol)", cmd: 0x0110, data: [0x40])
    t.pump(1.0)

    guard let current = observed else {
        note("could not read current volume — aborting without writing")
        exit(1)
    }
    let scaled = Int((current * 60).rounded())
    note("writing back the identical value (\(String(format: "%.2f", current)) dB → \(scaled)) — no net change")
    _ = t.send("SetVolume(sink, same value)", cmd: 0x0200,
               data: [0x01, UInt8((scaled >> 8) & 0xFF), UInt8(scaled & 0xFF)])
    t.pump(1.5)

    observed = nil
    _ = t.send("ReqDevStatus(vol) again", cmd: 0x0110, data: [0x40])
    t.pump(1.5)
    if let after = observed {
        let ok = abs(after - current) < 0.01
        note(ok ? "✓ WRITE PATH OK — volume unchanged at \(String(format: "%.2f dB", after))"
                : "✗ volume changed: \(current) → \(after)")
    } else {
        note("no read-back after write")
    }
    IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))

default:
    print("usage: qxusb [dump|test|voltest] [--seize] [--delay ms] [--count n] [--reportid n]")
}

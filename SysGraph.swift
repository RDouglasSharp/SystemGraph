// SysGraph.swift
// Compact floating graph: CPU (green), GPU (blue), Memory (orange) — 0-100%
// Build & run: swift SysGraph.swift
// Requires macOS 13+, Apple Silicon or Intel Mac Pro

import AppKit
import SwiftUI
import Metal
import IOKit

// ── MARK: Data Collection ─────────────────────────────────────────────────────

// CPU via host_statistics64
func cpuUsage() -> Double {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }

    let ticks = info.cpu_ticks
    let user   = Double(ticks.0)   // USER
    let system = Double(ticks.1)   // SYSTEM
    let idle   = Double(ticks.2)   // IDLE
    let nice   = Double(ticks.3)   // NICE
    let total  = user + system + idle + nice
    guard total > 0 else { return 0 }
    return min(100, (user + system + nice) / total * 100)
}

// Memory via host_vm_info64
func memoryUsage() -> Double {
    var vmStats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &vmStats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }

    let pageSize     = Double(vm_kernel_page_size)
    let active       = Double(vmStats.active_count)   * pageSize
    let wired        = Double(vmStats.wire_count)     * pageSize
    let compressed   = Double(vmStats.compressor_page_count) * pageSize
    let used         = active + wired + compressed

    guard kTotalRAM > 0 else { return 0 }
    return min(100, used / Double(kTotalRAM) * 100)
}

// GPU via IOKit — reads "PerformanceStatistics" from IOService
// Returns (utilization %, metal memory %) in one pass to avoid iterating IOAccelerator twice.
func gpuStats(totalRAM: UInt64) -> (util: Double, metalMemPct: Double) {
    let matching = IOServiceMatching("IOAccelerator")
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return (0, 0) }
    defer { IOObjectRelease(iter) }

    var bestUtil: Double = 0
    var bestMemBytes: UInt64 = 0

    var service = IOIteratorNext(iter)
    while service != 0 {
        defer { IOObjectRelease(service); service = IOIteratorNext(iter) }

        var cfProps: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &cfProps, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let props = cfProps?.takeRetainedValue() as NSDictionary? else { continue }
        guard let stats = props["PerformanceStatistics"] as? [String: Any] else { continue }

        // GPU utilization — try keys in priority order
        let utilKeys = ["GPU Activity(%)", "Device Utilization %", "gpu active", "GPU Utilization(%)"]
        for key in utilKeys {
            if let v = stats[key] as? Double { bestUtil = max(bestUtil, v); break }
            else if let v = stats[key] as? Int { bestUtil = max(bestUtil, Double(v)); break }
        }

        // Metal / GPU memory — Apple Silicon reports "In use system memory" (bytes of unified
        // memory currently held by the GPU). Discrete cards use vramUsedBytes / VRAM,usedBytes.
        let memKeys = ["In use system memory", "Alloc system memory", "vramUsedBytes", "VRAM,usedBytes"]
        for key in memKeys {
            var bytes: UInt64 = 0
            if let v = stats[key] as? UInt64       { bytes = v }
            else if let v = stats[key] as? Int     { bytes = UInt64(max(0, v)) }
            else if let v = stats[key] as? Double  { bytes = UInt64(max(0, v)) }
            if bytes > 0 { bestMemBytes = max(bestMemBytes, bytes); break }
        }
    }

    let memPct = totalRAM > 0 ? min(100, Double(bestMemBytes) / Double(totalRAM) * 100) : 0
    return (min(100, bestUtil), memPct)
}

// Cached total RAM so we don't sysctl on every tick
private let kTotalRAM: UInt64 = {
    var size: UInt64 = 0
    var len = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &size, &len, nil, 0)
    return size
}()

// ── MARK: Graph View ──────────────────────────────────────────────────────────

let kHistory = 120   // 2 minutes of 1-second samples

class GraphModel: ObservableObject {
    @Published var cpu:      [Double] = Array(repeating: 0, count: kHistory)
    @Published var mem:      [Double] = Array(repeating: 0, count: kHistory)
    @Published var gpu:      [Double] = Array(repeating: 0, count: kHistory)
    @Published var metalMem: [Double] = Array(repeating: 0, count: kHistory)
    @Published var latest: (cpu: Double, mem: Double, gpu: Double, metalMem: Double) = (0, 0, 0, 0)

    private var timer: Timer?
    // CPU delta tracking
    private var prevTicks: (UInt32,UInt32,UInt32,UInt32) = (0,0,0,0)

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let c = cpuDelta()
        let m = memoryUsage()
        let (g, mtl) = gpuStats(totalRAM: kTotalRAM)
        DispatchQueue.main.async {
            self.cpu.append(c);      if self.cpu.count      > kHistory { self.cpu.removeFirst() }
            self.mem.append(m);      if self.mem.count      > kHistory { self.mem.removeFirst() }
            self.gpu.append(g);      if self.gpu.count      > kHistory { self.gpu.removeFirst() }
            self.metalMem.append(mtl); if self.metalMem.count > kHistory { self.metalMem.removeFirst() }
            self.latest = (c, m, g, mtl)
        }
    }

    // Delta-based CPU (avoids cumulative tick overflow skewing results)
    private func cpuDelta() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let t = info.cpu_ticks
        let dUser   = Double(t.0 &- prevTicks.0)
        let dSystem = Double(t.1 &- prevTicks.1)
        let dIdle   = Double(t.2 &- prevTicks.2)
        let dNice   = Double(t.3 &- prevTicks.3)
        prevTicks = (t.0, t.1, t.2, t.3)
        let total = dUser + dSystem + dIdle + dNice
        guard total > 0 else { return 0 }
        return min(100, (dUser + dSystem + dNice) / total * 100)
    }
}

struct GraphLine: Shape {
    let values: [Double]
    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }
        var p = Path()
        let w = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * w
            let y = rect.height - CGFloat(v / 100) * rect.height
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else       { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

// Filled band between two value series (both 0–100).
// Traces upper forward then lower backward to form a closed polygon.
struct GraphBand: Shape {
    let lower: [Double]
    let upper: [Double]
    func path(in rect: CGRect) -> Path {
        let n = min(lower.count, upper.count)
        guard n > 1 else { return Path() }
        var p = Path()
        let w = rect.width / CGFloat(n - 1)
        for i in 0..<n {
            let x = CGFloat(i) * w
            let y = rect.height - CGFloat(upper[i] / 100) * rect.height
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else       { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        for i in stride(from: n - 1, through: 0, by: -1) {
            let x = CGFloat(i) * w
            let y = rect.height - CGFloat(lower[i] / 100) * rect.height
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.closeSubpath()
        return p
    }
}

struct GraphView: View {
    @ObservedObject var model: GraphModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            // grid lines at 25 / 50 / 75 %
            GeometryReader { geo in
                ForEach([25.0, 50.0, 75.0], id: \.self) { pct in
                    let y = geo.size.height - CGFloat(pct / 100) * geo.size.height
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }

            // ── Memory: stacked fills show GPU slice vs. rest ──────────────
            // MEM (vm_statistics) is the true total on unified-memory Macs;
            // MTL is already counted inside MEM, so we decompose rather than add.
            //
            //  0 → MTL   = GPU-resident (magenta band)
            //  MTL → MEM = everything else: kernel, CPU processes (orange band)
            //  top edge  = total memory pressure (orange line)
            let zeros = Array(repeating: 0.0, count: model.metalMem.count)
            GraphBand(lower: zeros, upper: model.metalMem)
                .fill(Color(red: 1.0, green: 0.2, blue: 0.9).opacity(0.30))
            GraphBand(lower: model.metalMem, upper: model.mem)
                .fill(Color.orange.opacity(0.22))
            GraphLine(values: model.metalMem)
                .stroke(Color(red: 1.0, green: 0.2, blue: 0.9), lineWidth: 1)
            GraphLine(values: model.mem)
                .stroke(Color.orange, lineWidth: 1.5)

            // GPU utilization (cyan) — on top of fills
            GraphLine(values: model.gpu)
                .stroke(Color.cyan, lineWidth: 1.5)
            // CPU (green) — topmost
            GraphLine(values: model.cpu)
                .stroke(Color(red: 0.2, green: 1.0, blue: 0.4), lineWidth: 1.5)

            // Legend + live values
            HStack(spacing: 8) {
                label("CPU",  value: model.latest.cpu,      color: Color(red: 0.2, green: 1.0, blue: 0.4))
                label("GPU",  value: model.latest.gpu,      color: .cyan)
                label("MTL",  value: model.latest.metalMem, color: Color(red: 1.0, green: 0.2, blue: 0.9))
                label("MEM",  value: model.latest.mem,      color: .orange)
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
        }
        .background(Color.black.opacity(0.85))
    }

    func label(_ name: String, value: Double, color: Color) -> some View {
        HStack(spacing: 3) {
            Rectangle().fill(color).frame(width: 8, height: 2)
            Text("\(name) \(Int(value.rounded()))%")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(color)
        }
    }
}

// ── MARK: App Entry Point ─────────────────────────────────────────────────────

// ── MARK: Per-screen position persistence ────────────────────────────────────

// Key by screen dimensions so the same layout applies to any screen of that size,
// regardless of which physical monitor or display ID is in use.
func screenKey(_ screen: NSScreen) -> String {
    "sysgraph_\(Int(screen.frame.width))x\(Int(screen.frame.height))"
}

func saveFrame(_ window: NSWindow) {
    guard let screen = window.screen else { return }
    UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: screenKey(screen))
}

func restoreFrame(_ window: NSWindow) {
    // Check each currently connected screen for a saved position
    for screen in NSScreen.screens {
        let saved = UserDefaults.standard.string(forKey: screenKey(screen)) ?? ""
        let frame = NSRectFromString(saved)
        if frame.width > 0 {
            window.setFrame(frame, display: true)
            return
        }
    }
    window.center()   // no saved position yet — center on main screen
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let model = GraphModel()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon

        let view = GraphView(model: model)
        let host = NSHostingView(rootView: view)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .floating          // always on top
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentView = host
        window.delegate = self
        restoreFrame(window)
        window.makeKeyAndOrderFront(nil)

        model.start()
    }

    // Save after every move or resize
    func windowDidMove(_ n: Notification)           { saveFrame(window) }
    func windowDidEndLiveResize(_ n: Notification)  { saveFrame(window) }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()


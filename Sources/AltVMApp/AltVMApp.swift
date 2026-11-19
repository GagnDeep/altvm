import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AltVMCore

@main
struct AltVMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        WindowGroup("AltVM", id: "library") {
            LibraryView()
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Machine…") { store.showCreate = true }.keyboardShortcut("n")
            }
            CommandMenu("Machine") {
                Button("Start") { store.perform(.start) }.keyboardShortcut("r")
                Button("Suspend") { store.perform(.suspend) }.keyboardShortcut("s", modifiers: [.command, .option])
                Button("Shut Down") { store.perform(.stop) }.keyboardShortcut("q", modifiers: [.command, .option])
                Divider()
                Button("Take Snapshot") { store.perform(.snapshot) }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Clone") { store.perform(.clone) }
            }
        }
        MenuBarExtra("AltVM", systemImage: "square.stack.3d.up") {
            MenuBarView().environmentObject(store)
        }
        Settings { SettingsView().environmentObject(store) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// ALTVM_UI_SNAPSHOT=/path/prefix renders each open window to PNG in-process (docs, UI tests;
    /// needs no Screen Recording permission). ALTVM_UI_SNAPSHOT_CREATE=1 also opens the New sheet.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let prefix = ProcessInfo.processInfo.environment["ALTVM_UI_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated {
                if ProcessInfo.processInfo.environment["ALTVM_UI_SNAPSHOT_CREATE"] != nil { Store.shared.showCreate = true }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                guard let view = w.contentView?.superview ?? w.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(i).png"))
                for (j, sheet) in [w.attachedSheet].compactMap({ $0 }).enumerated() {
                    if let sv = sheet.contentView, let r = sv.bitmapImageRepForCachingDisplay(in: sv.bounds) {
                        sv.cacheDisplay(in: sv.bounds, to: r)
                        try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(i)-sheet\(j).png"))
                    }
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let running = Store.shared.runners.values.filter { $0.state == .running || $0.state == .paused }
            guard !running.isEmpty else { return .terminateNow }
            // Suspend everything so nothing is lost; quit when done.
            Task { @MainActor in
                for r in running { try? await r.suspend() }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - model

struct VMRow: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var os: String
    var state: String
    var cpus: Int
    var memoryMiB: UInt64
    var diskUsed: UInt64
    var diskSize: UInt64
    var snapshots: Int
    var flags: [String]
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    enum Action { case start, stop, suspend, pause, resume, snapshot, clone, delete, open }

    @Published var rows: [VMRow] = []
    @Published var selection: String?
    @Published var showCreate = false
    @Published var error: String?
    @Published var busy: String?
    @Published var host = HostInfo.current()
    var runners: [String: VMRunner] = [:]
    var windows: [String: VMWindowController] = [:]
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { Store.shared.refresh() }
        }
    }

    func refresh() {
        let all = Manager.listAll()
        var new: [VMRow] = []
        for v in all {
            let name = v["name"] as? String ?? ""
            var state = v["state"] as? String ?? "stopped"
            if let r = runners[name] { state = r.state.rawValue }
            let flags = [v["isolated"] as? Bool == true ? "Isolated" : nil, v["disposable"] as? Bool == true ? "Disposable" : nil,
                         v["encrypted"] as? Bool == true ? "Encrypted" : nil].compactMap { $0 }
            new.append(VMRow(name: name, os: v["os"] as? String ?? "", state: state, cpus: v["cpus"] as? Int ?? 0,
                             memoryMiB: v["memoryMiB"] as? UInt64 ?? 0, diskUsed: v["diskPhysicalBytes"] as? UInt64 ?? 0,
                             diskSize: v["diskLogicalBytes"] as? UInt64 ?? 0, snapshots: v["snapshots"] as? Int ?? 0, flags: flags))
        }
        if new != rows { rows = new }
        if selection == nil { selection = rows.first?.name }
        host = HostInfo.current()
    }

    func perform(_ action: Action, on name: String? = nil) {
        guard let name = name ?? selection else { return }
        Task { @MainActor in
            do {
                switch action {
                case .start, .open: try await startInApp(name)
                case .stop:
                    if let r = runners[name] { try await r.stop() } else { try Manager.stop(name) }
                case .suspend:
                    if let r = runners[name] { try await r.suspend() } else { _ = try Manager.control(name, "suspend") }
                case .pause:
                    if let r = runners[name] { try await r.pause() } else { _ = try Manager.control(name, "pause") }
                case .resume:
                    if let r = runners[name] { try await r.resume() } else { _ = try Manager.control(name, "resume") }
                case .snapshot:
                    let label = "Snapshot \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
                    if let r = runners[name] { _ = try await r.liveSnapshot(name: label) } else { _ = try Manager.snapshot(name, label: label) }
                case .clone:
                    var n = "\(name)-clone"; var i = 2
                    while (try? VMLibrary.find(n)) != nil { n = "\(name)-clone\(i)"; i += 1 }
                    try VMLibrary.clone(name, to: n)
                    selection = n
                case .delete:
                    let alert = NSAlert()
                    alert.messageText = "Delete “\(name)”?"
                    alert.informativeText = "The machine, its disks and snapshots are removed permanently."
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "Delete")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    try VMLibrary.delete(name)
                    selection = nil
                }
            } catch {
                self.error = error.localizedDescription
            }
            refresh()
        }
    }

    func startInApp(_ name: String) async throws {
        if let w = windows[name] { w.showWindow(nil); w.window?.makeKeyAndOrderFront(nil); return }
        if EncryptedStore.isEncrypted(name) && !EncryptedStore.isUnlocked(name) {
            guard let pw = promptPassword(for: name) else { return }
            try EncryptedStore.unlock(name, passphrase: pw)
        }
        let bundle = try VMLibrary.find(name)
        if bundle.isRunning { throw AltVMError.running("\(name) is running in another process (started from the CLI). Control it from here, or stop it to open its display.") }
        var o = VMRunner.Options()
        o.gui = true
        o.helperExecutable = Bundle.main.url(forAuxiliaryExecutable: "avm")?.path
        let r = try VMRunner(bundle: bundle, options: o)
        r.onStateChange = { _ in Store.shared.refresh() }
        r.onExit = { _ in
            Store.shared.runners[name] = nil
            Store.shared.windows[name]?.close()
            Store.shared.windows[name] = nil
            Store.shared.refresh()
        }
        runners[name] = r
        do { try await r.start() } catch { runners[name] = nil; throw error }
        let w = VMWindowController(runner: r)
        windows[name] = w
        w.showWindow(nil)
        if !r.warnings.isEmpty { self.error = r.warnings.joined(separator: "\n") }
    }

    func promptPassword(for name: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Unlock “\(name)”"
        alert.informativeText = "This machine is encrypted. Enter its passphrase."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

// MARK: - views

struct LibraryView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selection) {
                Section("Machines") {
                    ForEach(store.rows) { row in
                        HStack(spacing: 10) {
                            Image(systemName: icon(row.os)).frame(width: 18).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name).fontWeight(.medium)
                                Text(row.state.capitalized).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle().fill(color(row.state)).frame(width: 7, height: 7)
                        }
                        .tag(row.name)
                        .contextMenu {
                            Button("Start") { store.perform(.start, on: row.name) }
                            Button("Suspend") { store.perform(.suspend, on: row.name) }
                            Button("Shut Down") { store.perform(.stop, on: row.name) }
                            Divider()
                            Button("Take Snapshot") { store.perform(.snapshot, on: row.name) }
                            Button("Clone") { store.perform(.clone, on: row.name) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([VMLibrary.bundleURL(named: row.name)]) }
                            Divider()
                            Button("Delete…", role: .destructive) { store.perform(.delete, on: row.name) }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                ToolbarItem { Button { store.showCreate = true } label: { Label("New", systemImage: "plus") } }
            }
        } detail: {
            if let sel = store.selection, let row = store.rows.first(where: { $0.name == sel }) {
                DetailView(row: row).id(row.name)
            } else {
                ContentUnavailableView {
                    Label("No machine selected", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Create a Linux machine in seconds, install macOS, or deploy a signed company image.")
                } actions: {
                    Button("New Machine…") { store.showCreate = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $store.showCreate) { CreateView().environmentObject(store) }
        .alert("AltVM", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    func icon(_ os: String) -> String {
        switch os { case "macos": return "apple.logo"; case "windows": return "pc"; case "linux": return "terminal"; default: return "cpu" }
    }
    func color(_ s: String) -> Color {
        switch s { case "running": return .green; case "paused", "suspended", "saving": return .orange; case "locked", "error": return .red; default: return .secondary.opacity(0.4) }
    }
}

struct DetailView: View {
    @EnvironmentObject var store: Store
    let row: VMRow
    @State private var spec: VMSpec?
    @State private var snapshots: [SnapshotInfo] = []
    @State private var dirty = false

    var running: Bool { row.state == "running" || row.state == "paused" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name).font(.largeTitle).fontWeight(.semibold)
                        HStack(spacing: 6) {
                            Text(spec?.os.displayName ?? row.os).foregroundStyle(.secondary)
                            ForEach(row.flags, id: \.self) { Text($0).font(.caption).padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                        }
                    }
                    Spacer()
                    actionButtons
                }
                HStack(spacing: 12) {
                    Stat(title: "State", value: row.state.capitalized)
                    Stat(title: "vCPU", value: "\(row.cpus)")
                    Stat(title: "Memory", value: String(format: "%.1f GB", Double(row.memoryMiB) / 1024))
                    Stat(title: "Disk used", value: ByteCountFormatter.string(fromByteCount: Int64(row.diskUsed), countStyle: .file))
                    Stat(title: "Snapshots", value: "\(row.snapshots)")
                }
                if let binding = Binding($spec) { SettingsForm(spec: binding, dirty: $dirty, disabled: running) }
                if dirty {
                    HStack {
                        Spacer()
                        Button("Revert") { load() }
                        Button("Save Changes") { save() }.buttonStyle(.borderedProminent)
                    }
                }
                GroupBox("Snapshots") {
                    if snapshots.isEmpty {
                        Text("No snapshots. Snapshots are instant and take no space until the machine changes.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(snapshots.reversed(), id: \.id) { s in
                        HStack {
                            Image(systemName: s.live ? "bolt.circle" : "camera")
                            VStack(alignment: .leading) {
                                Text(s.name)
                                Text(s.created.formatted(date: .abbreviated, time: .shortened) + (s.live ? " · live" : "")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") { restore(s) }.disabled(running)
                            Button(role: .destructive) { delete(s) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(24)
        }
        .onAppear(perform: load)
        .onChange(of: row.snapshots) { _, _ in load() }
    }

    @ViewBuilder var actionButtons: some View {
        HStack {
            if row.state == "running" {
                Button { store.perform(.open, on: row.name) } label: { Label("Show", systemImage: "macwindow") }
                Button { store.perform(.pause, on: row.name) } label: { Label("Pause", systemImage: "pause.fill") }
                Button { store.perform(.suspend, on: row.name) } label: { Label("Suspend", systemImage: "moon.zzz") }
                Button { store.perform(.stop, on: row.name) } label: { Label("Shut Down", systemImage: "power") }
            } else if row.state == "paused" {
                Button { store.perform(.resume, on: row.name) } label: { Label("Resume", systemImage: "play.fill") }
            } else if row.state != "locked" {
                Button { store.perform(.start, on: row.name) } label: { Label(row.state == "suspended" ? "Resume" : "Start", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
            } else {
                Button { store.perform(.start, on: row.name) } label: { Label("Unlock & Start", systemImage: "lock.open") }
            }
            Button { store.perform(.snapshot, on: row.name) } label: { Label("Snapshot", systemImage: "camera") }
        }
        .controlSize(.large)
    }

    func load() {
        guard let b = try? VMLibrary.find(row.name) else { return }
        spec = try? b.loadSpec()
        snapshots = SnapshotManager(bundle: b).list()
        dirty = false
    }

    func save() {
        guard let spec, let b = try? VMLibrary.find(row.name) else { return }
        do {
            if let p = Policy.loadActive() {
                if p.lockSettings { throw AltVMError.policy("settings are locked by \(p.organization)") }
                try p.enforce(spec)
            }
            try b.saveSpec(spec)
            AuditLog.shared.record("vm.configure", vm: spec.name, details: ["source": "app"])
            dirty = false
            store.refresh()
        } catch { store.error = error.localizedDescription }
    }

    func restore(_ s: SnapshotInfo) {
        guard let b = try? VMLibrary.find(row.name) else { return }
        do { try SnapshotManager(bundle: b).restore(s.id); store.refresh(); load() } catch { store.error = error.localizedDescription }
    }

    func delete(_ s: SnapshotInfo) {
        guard let b = try? VMLibrary.find(row.name) else { return }
        do { try SnapshotManager(bundle: b).delete(s.id); store.refresh(); load() } catch { store.error = error.localizedDescription }
    }
}

struct Stat: View {
    let title: String, value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).fontWeight(.semibold).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SettingsForm: View {
    @Binding var spec: VMSpec
    @Binding var dirty: Bool
    let disabled: Bool
    var host: HostInfo { .current() }

    var body: some View {
        GroupBox("Hardware") {
            Form {
                Picker("Profile", selection: bind(\.profile)) {
                    ForEach(WorkloadProfile.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Stepper("Processors: \(spec.cpus)", value: bind(\.cpus), in: 1...max(1, host.cpuCount))
                Stepper("Memory: \(spec.memoryMiB / 1024) GB", value: bind(\.memoryMiB), in: 1024...max(2048, host.maxVMMemoryMiB), step: 1024)
                Toggle("Adapt to battery and thermal state", isOn: bind(\.adaptiveResources))
                Stepper("Displays: \(spec.display.extraDisplays + 1)", value: bind(\.display.extraDisplays), in: 0...3)
            }
            .disabled(disabled)
        }
        GroupBox("Integration") {
            Form {
                Toggle("Share clipboard", isOn: bind(\.integration.clipboard))
                Toggle("Sound output", isOn: bind(\.integration.audioOutput))
                Toggle("Microphone", isOn: bind(\.integration.microphone))
                if spec.os == .linux { Toggle("Rosetta for x86_64 Linux apps", isOn: bind(\.integration.rosetta)) }
                Toggle("Guest agent", isOn: bind(\.integration.guestAgent))
                LabeledContent("Shared folders") {
                    VStack(alignment: .trailing) {
                        ForEach(spec.integration.sharedFolders, id: \.name) { f in
                            HStack {
                                Text("\(f.name) → \(f.hostPath)").font(.callout).lineLimit(1).truncationMode(.middle)
                                Button { spec.integration.sharedFolders.removeAll { $0.name == f.name }; dirty = true } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }
                        }
                        Button("Add Folder…") { addFolder() }
                    }
                }
            }
            .disabled(disabled)
        }
        GroupBox("Security") {
            Form {
                Toggle("Isolated (no network, clipboard, folders, mic)", isOn: bind(\.security.isolated))
                Toggle("Disposable (discard changes at shutdown)", isOn: bind(\.security.disposable))
                if spec.os != .macOS { Toggle("Secure Boot", isOn: bind(\.security.secureBoot)) }
            }
            .disabled(disabled)
        }
    }

    func bind<T>(_ kp: WritableKeyPath<VMSpec, T>) -> Binding<T> {
        Binding(get: { spec[keyPath: kp] }, set: { spec[keyPath: kp] = $0; dirty = true })
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        spec.integration.sharedFolders.append(SharedFolderSpec(name: url.lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "-"), hostPath: url.path))
        dirty = true
    }
}

struct CreateView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    enum Source: Hashable { case catalog(String), iso, image, blank }
    @State private var name = ""
    @State private var source: Source = .catalog("debian-13")
    @State private var profile: WorkloadProfile = .productivity
    @State private var file: URL?
    @State private var password = ""
    @State private var diskGiB = 64
    @State private var isolated = false
    @State private var disposable = false
    @State private var working = false
    @State private var status = ""
    @State private var progress = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Machine").font(.title2).fontWeight(.semibold)
            Form {
                TextField("Name", text: $name, prompt: Text("dev-box"))
                Picker("Install from", selection: $source) {
                    ForEach(Catalog.entries.filter { $0.kind != .manual }, id: \.id) { Text($0.title).tag(Source.catalog($0.id)) }
                    Divider()
                    Text("Installer ISO / disk image…").tag(Source.iso)
                    Text("Company golden image (.avmimg)…").tag(Source.image)
                    Text("Blank machine").tag(Source.blank)
                }
                if source == .iso || source == .image {
                    HStack {
                        Text(file?.lastPathComponent ?? "No file chosen").foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") { choose() }
                    }
                }
                Picker("Optimise for", selection: $profile) {
                    ForEach(WorkloadProfile.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                let r = ProfileEngine.resources(for: profile, os: .linux, host: .current())
                LabeledContent("Resources", value: "\(r.cpus) vCPU · \(r.memoryMiB / 1024) GB (from this Mac)")
                Stepper("Disk: \(diskGiB) GB (thin)", value: $diskGiB, in: 16...2048, step: 16)
                SecureField("Password", text: $password, prompt: Text("Optional — your SSH keys are added automatically"))
                Toggle("Isolated", isOn: $isolated)
                Toggle("Disposable", isOn: $disposable)
            }
            if working {
                ProgressView(value: progress) { Text(status).font(.caption) }
            }
            HStack {
                Text(Catalog.entries.first { Source.catalog($0.id) == source }?.notes ?? "").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || working || ((source == .iso || source == .image) && file == nil))
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = source == .image ? [UTType(filenameExtension: "avmimg") ?? .data] : [.diskImage, .data]
        if panel.runModal() == .OK { file = panel.url }
    }

    func create() {
        working = true
        var o = CreateOptions(name: name)
        o.profile = profile
        o.diskGiB = UInt64(diskGiB)
        o.password = password.isEmpty ? nil : password
        o.isolated = isolated
        o.disposable = disposable
        let src = source, f = file
        Task { @MainActor in
            do {
                switch src {
                case .catalog(let id):
                    let e = try Catalog.find(id)
                    if e.kind == .macOS {
                        _ = try await MacOSInstall.run(o, ipsw: nil) { s, p in
                            Task { @MainActor in status = s; progress = p }
                        }
                    } else {
                        o.os = e.os
                        status = "Downloading \(e.title)…"
                        let file = try await Catalog.fetch(e) { p, _ in Task { @MainActor in progress = p } }
                        status = "Creating…"
                        if e.kind == .cloudImage { try Provisioner.createFromCloudImage(o, image: file) } else { try Provisioner.createFromISO(o, iso: file) }
                    }
                case .iso: try Provisioner.createFromISO(o, iso: f!)
                case .image:
                    status = "Verifying and deploying…"
                    try GoldenImage.deploy(f!, as: name) { p in Task { @MainActor in progress = p } }
                case .blank: try Provisioner.createBlank(o)
                }
                store.refresh()
                store.selection = name
                dismiss()
                store.perform(.start, on: name)
            } catch {
                working = false
                store.error = error.localizedDescription
            }
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        ForEach(store.rows) { row in
            Menu("\(row.state == "running" ? "●" : "○") \(row.name)") {
                if row.state == "running" {
                    Button("Show") { store.perform(.open, on: row.name) }
                    Button("Suspend") { store.perform(.suspend, on: row.name) }
                    Button("Shut Down") { store.perform(.stop, on: row.name) }
                    Button("Take Snapshot") { store.perform(.snapshot, on: row.name) }
                } else {
                    Button("Start") { store.perform(.start, on: row.name) }
                }
            }
        }
        if store.rows.isEmpty { Text("No machines") }
        Divider()
        Button("New Machine…") { store.showCreate = true; NSApp.activate(ignoringOtherApps: true) }
        Button("Open AltVM") { NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button("Quit AltVM") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var policy = Policy.loadActive()
    var body: some View {
        TabView {
            Form {
                LabeledContent("Library", value: Paths.vms.path)
                LabeledContent("This Mac", value: "\(store.host.cpuCount) cores · \(store.host.memoryMiB / 1024) GB · \(store.host.onBattery ? "battery" : "AC power")")
                LabeledContent("VM limits", value: "\(store.host.maxVMCPUs) vCPU · \(store.host.maxVMMemoryMiB / 1024) GB per machine (no edition caps)")
                LabeledContent("Rosetta for Linux", value: store.host.rosettaAvailable ? "Available" : "Not supported")
            }
            .tabItem { Label("General", systemImage: "gear") }
            .padding()
            Form {
                if let policy {
                    LabeledContent("Managed by", value: policy.organization)
                    LabeledContent("Settings locked", value: policy.lockSettings ? "Yes" : "No")
                    LabeledContent("Signed images only", value: policy.requireSignedImages ? "Yes" : "No")
                    LabeledContent("Encryption required", value: policy.requireEncryption ? "Yes" : "No")
                } else {
                    Text("This Mac is not managed. IT can deploy a signed policy with MDM.").foregroundStyle(.secondary)
                }
                LabeledContent("Audit trail", value: AuditLog.shared.verify() == nil ? "Intact" : "TAMPERED")
            }
            .tabItem { Label("Organization", systemImage: "building.2") }
            .padding()
        }
        .frame(width: 520, height: 260)
    }
}

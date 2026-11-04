import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

struct PulseSettings: Codable, Equatable {
    var mode = "reset"
    var interval = 30
    var retryInterval = 5
    var notificationsEnabled = false
    var autoStart = false
    var selectedAccountId = ""
    var quietEnabled = false
    var quietStart = "23:00"
    var quietEnd = "08:00"
}

struct AccountStatus: Codable, Identifiable {
    let id: String
    let label: String
    let plan: String
    let enabled: Bool
    let status: String
    let usedPercent: Double?
    let weeklyUsedPercent: Double?
    let resetsAt: Double?
    let nextCheckAt: Double
    let lastCheckedAt: Double?
    let lastTriggeredAt: Double?
    let error: String?
    var alias = ""
    var overrideEnabled = false
    var mode = "reset"
    var interval = 30
    var retryInterval = 5
    var displayName: String { alias.isEmpty ? label : alias }
}

struct HistoryEntry: Codable, Identifiable {
    let id: String
    let at: Double
    let kind: String
    let message: String
    let accountId: String?
    var symbol: String {
        switch kind {
        case "success": return "checkmark.circle.fill"
        case "error", "warning": return "exclamationmark.triangle.fill"
        case "attempt": return "paperplane.fill"
        case "start": return "play.circle"
        case "pause", "cancelled": return "pause.circle"
        case "settings": return "slider.horizontal.3"
        case "deferred": return "moon.fill"
        default: return "arrow.clockwise.circle"
        }
    }
    var color: Color {
        switch kind {
        case "error", "warning": return .orange
        case "success": return .green
        default: return .secondary
        }
    }
}

struct PulseNotification: Codable {
    let id: String
    let title: String
    let body: String
}

struct Snapshot: Codable {
    let running: Bool
    let settings: PulseSettings
    let accounts: [AccountStatus]
    let error: String?
    let commandError: String?
    let activeId: String?
    let history: [HistoryEntry]
    let notification: PulseNotification?
    let quietUntil: Double?
    static let empty = Snapshot(running: false, settings: PulseSettings(), accounts: [], error: nil,
                                commandError: nil, activeId: nil, history: [], notification: nil, quietUntil: nil)
}

final class Model: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var snapshot = Snapshot.empty
    @Published var now = Date()
    @Published var backendError: String?
    @Published var feedback: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var process: Process?
    private var input: FileHandle?
    private var timer: Timer?
    private var notifications = Set<String>()
    var onUpdate: (() -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.now = Date()
            self?.onUpdate?()
        }
    }

    func startBackend() {
        guard let script = Bundle.main.path(forResource: "backend", ofType: "py") else {
            backendError = "Uygulama dosyaları eksik. Uygulamayı yeniden kurun."
            return
        }
        let task = Process()
        let output = Pipe()
        let commands = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-u", script] + (CommandLine.arguments.contains("--paused") ? ["--paused"] : [])
        task.standardInput = commands
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        task.environment = environment
        input = commands.fileHandleForWriting
        process = task
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.backendError = "İzleyici kapandı. Uygulamayı kapatıp yeniden açın."
                self?.onUpdate?()
            }
        }
        do {
            try task.run()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var buffer = Data()
                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<end])
                        buffer.removeSubrange(...end)
                        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: line) {
                            DispatchQueue.main.async {
                                self?.snapshot = snapshot
                                self?.backendError = nil
                                if let notice = snapshot.notification { self?.notify(notice) }
                                self?.onUpdate?()
                            }
                        }
                    }
                }
            }
        } catch {
            backendError = "Python 3 başlatılamadı. macOS komut satırı araçlarını kontrol edin."
        }
    }

    func send(_ action: String, extra: [String: Any] = [:]) {
        var command = extra
        command["action"] = action
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return }
        do { try input?.write(contentsOf: data + Data([10])) }
        catch { backendError = "İzleyiciyle bağlantı kesildi. Uygulamayı yeniden açın." }
    }

    func apply(_ settings: PulseSettings) {
        func commit(_ chosen: PulseSettings) {
            guard let data = try? JSONEncoder().encode(chosen),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            send("settings", extra: ["settings": object])
            feedback = "Ayarlar gönderildi."
        }
        if settings.notificationsEnabled && !snapshot.settings.notificationsEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DispatchQueue.main.async {
                    var chosen = settings
                    chosen.notificationsEnabled = granted
                    commit(chosen)
                    if !granted {
                        self.feedback = "Bildirim izni verilmedi. Sistem Ayarları → Bildirimler → Codex Pulse bölümünden açabilirsiniz. Diğer ayarlar kaydedildi."
                    }
                }
            }
        } else { commit(settings) }
    }

    private func notify(_ notice: PulseNotification) {
        guard notifications.insert(notice.id).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)) { _ in }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if value && !launchAtLogin { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            feedback = "Giriş Öğeleri ayarı değiştirilemedi. Sistem Ayarları → Genel → Giriş Öğeleri bölümünü kontrol edin."
        }
    }

    func exportHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CodexPulse-history.json"
        panel.title = "İşlem geçmişini dışa aktar"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(snapshot.history).write(to: url, options: .atomic)
                feedback = "Geçmiş dışa aktarıldı."
            } catch { feedback = "Geçmiş dosyası yazılamadı." }
        }
    }

    func shutdown() {
        send("quit")
        try? input?.close()
    }

    func countdown(_ timestamp: Double?) -> String {
        guard let timestamp else { return "—" }
        let seconds = max(0, Int(ceil(timestamp - now.timeIntervalSince1970)))
        if seconds == 0 { return "Yenilenme bekleniyor" }
        let days = seconds / 86400, hours = seconds / 3600 % 24, minutes = seconds / 60 % 60
        return days > 0 ? "\(days)g \(hours)sa \(minutes)dk" : String(format: "%02d:%02d:%02d", hours, minutes, seconds % 60)
    }

    var compactTitle: String {
        if backendError != nil { return "Hata" }
        if snapshot.activeId != nil { return "Kontrol" }
        let selected = snapshot.accounts.first { $0.id == snapshot.settings.selectedAccountId }
        if !snapshot.running && selected == nil { return "Duraklatıldı" }
        let account = selected ?? snapshot.accounts.filter { $0.enabled && $0.error == nil }
            .filter { $0.resetsAt != nil }.min { ($0.resetsAt ?? .infinity) < ($1.resetsAt ?? .infinity) }
        guard let account, let due = account.resetsAt else { return "İzleniyor" }
        let seconds = max(0, Int(due - now.timeIntervalSince1970))
        let name = selected == nil ? "" : String(account.displayName.prefix(10)) + " "
        let paused = snapshot.running && account.enabled ? "" : "Ⅱ "
        return paused + name + (seconds == 0 ? "Bekliyor" : String(format: "%d:%02d", seconds / 3600, seconds / 60 % 60))
    }
}

struct AccountCard: View {
    @ObservedObject var model: Model
    let account: AccountStatus
    var edit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle").font(.system(size: 27)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(account.displayName)
                    Text(account.alias.isEmpty ? "Monocode · \(account.plan.capitalized)" : account.label)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: edit) { Image(systemName: "slider.horizontal.3") }.buttonStyle(.borderless).help("Hesap ayarları")
                Toggle("Bu hesabı izle", isOn: Binding(get: { account.enabled }, set: { _ in
                    model.send("toggle", extra: ["id": account.id])
                })).toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(model.countdown(account.resetsAt)).font(.system(size: 23, weight: .medium, design: .monospaced))
                    .foregroundStyle(account.enabled ? Color.primary : Color.secondary)
                Spacer()
                Text("5 saatlik pencere").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                quota("Pencere", used: account.usedPercent)
                quota("Haftalık", used: account.weeklyUsedPercent)
            }
            HStack(alignment: .top, spacing: 6) {
                Circle().fill(account.error != nil ? Color.orange : account.enabled && model.snapshot.running ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6).padding(.top, 4)
                Text(account.error ?? (account.enabled ? account.status : "Bu hesap kapalı"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.snapshot.activeId == account.id { ProgressView().controlSize(.mini).scaleEffect(0.7) }
            }
            if let checked = account.lastCheckedAt {
                HStack {
                    Text("Kontrol \(Date(timeIntervalSince1970: checked).formatted(date: .omitted, time: .shortened))")
                    Spacer()
                    if model.snapshot.running && account.enabled {
                        Text("Sonraki \(Date(timeIntervalSince1970: account.nextCheckAt).formatted(date: .abbreviated, time: .shortened))")
                    }
                }.font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let triggered = account.lastTriggeredAt {
                Text("Son sorgu \(Date(timeIntervalSince1970: triggered).formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if account.overrideEnabled {
                Text("Özel ayar · \(account.mode == "reset" ? "süre dolunca" : "her \(account.interval) dk") · tekrar \(account.retryInterval) dk")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }
    func quota(_ label: String, used: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(label); Spacer(); Text(used.map { "%\(Int($0))" } ?? "—").monospacedDigit() }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ProgressView(value: min(100, max(0, used ?? 0)), total: 100).tint((used ?? 0) >= 95 ? .orange : .accentColor)
        }
    }
}

struct MinuteField: View {
    let title: String
    @Binding var text: String
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            TextField("Dakika", text: $text).textFieldStyle(.roundedBorder).frame(width: 70)
            Text("dk").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct GlobalSettingsView: View {
    @ObservedObject var model: Model
    @State private var draft = PulseSettings()
    @State private var interval = "30"
    @State private var retry = "5"
    @State private var validation: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            GroupBox("Kontrol davranışı") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Mod", selection: $draft.mode) {
                        Text("Sadece süre dolunca").tag("reset")
                        Text("Ara kontrol de yap").tag("periodic")
                    }.labelsHidden().pickerStyle(.segmented)
                    if draft.mode == "periodic" { MinuteField(title: "Ara kontrol sıklığı", text: $interval) }
                    MinuteField(title: "Hata / gecikme sonrası kontrol", text: $retry)
                    Text("Süre dolunca 15 saniyelik payla limit doğrulanır. Bu aralık yalnızca durum sorguları içindir; model sorgusu aynı pencere için tekrarlanmaz.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }
            GroupBox("Görünüm ve bildirimler") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Menü çubuğu", selection: $draft.selectedAccountId) {
                        Text("En yakın yenilenme").tag("")
                        ForEach(model.snapshot.accounts) { Text($0.displayName).tag($0.id) }
                    }.font(.system(size: 12))
                    Toggle("İşlem ve hata bildirimleri", isOn: $draft.notificationsEnabled).font(.system(size: 12))
                }.padding(8)
            }
            GroupBox("Sessiz saatler · Mac’in yerel saati") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Bu saatlerde otomatik sorgu gönderme", isOn: $draft.quietEnabled).font(.system(size: 12))
                    HStack {
                        Text("Başlangıç").font(.system(size: 11))
                        TextField("23:00", text: $draft.quietStart).textFieldStyle(.roundedBorder).frame(width: 65)
                        Spacer()
                        Text("Bitiş").font(.system(size: 11))
                        TextField("08:00", text: $draft.quietEnd).textFieldStyle(.roundedBorder).frame(width: 65)
                    }.disabled(!draft.quietEnabled)
                    Text("Ertelenen sorgu, sessiz saatler bitince yeniden doğrulanır. Bildirimler de sessize alınır.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }
            GroupBox("Açılış") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Uygulama açılınca izlemeyi başlat", isOn: $draft.autoStart).font(.system(size: 12))
                    Text("Kapalıysa her açılışta Başlat’a basmanız gerekir. Bu seçim mevcut izlemeyi değiştirmez.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Mac oturumu açılınca uygulamayı aç", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
                        .font(.system(size: 12))
                }.padding(8)
            }
            if let text = validation ?? model.snapshot.commandError { Text(text).font(.system(size: 11)).foregroundStyle(.orange) }
            if let text = model.feedback { Text(text).font(.system(size: 11)).foregroundStyle(.secondary) }
            Button("Ayarları kaydet") {
                guard let every = Int(interval), let again = Int(retry), (1...10080).contains(every), (1...10080).contains(again) else {
                    validation = "Dakikaları 1–10080 arasında tam sayı girin."; return
                }
                validation = nil
                draft.interval = every
                draft.retryInterval = again
                model.apply(draft)
            }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onAppear {
            draft = model.snapshot.settings
            interval = String(draft.interval)
            retry = String(draft.retryInterval)
            model.feedback = nil
        }
    }
}

struct ProfileSettingsView: View {
    @ObservedObject var model: Model
    let account: AccountStatus
    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""
    @State private var custom = false
    @State private var mode = "reset"
    @State private var interval = "30"
    @State private var retry = "5"
    @State private var validation: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Hesap ayarları").font(.system(size: 19, weight: .semibold))
            Text(account.label).font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Takma ad · ör. İş hesabı", text: $alias).textFieldStyle(.roundedBorder)
            Toggle("Bu hesap için farklı kontrol ayarları", isOn: $custom).font(.system(size: 12))
            if custom {
                Picker("Mod", selection: $mode) {
                    Text("Sadece süre dolunca").tag("reset")
                    Text("Ara kontrol de yap").tag("periodic")
                }.labelsHidden().pickerStyle(.segmented)
                if mode == "periodic" { MinuteField(title: "Ara kontrol sıklığı", text: $interval) }
                MinuteField(title: "Hata / gecikme sonrası kontrol", text: $retry)
            } else {
                Text("Genel kontrol ayarları kullanılır. Sessiz saatler ve açılış tercihi tüm hesaplar için ortaktır.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let text = validation ?? model.snapshot.commandError { Text(text).font(.system(size: 11)).foregroundStyle(.orange) }
            if let text = model.feedback { Text(text).font(.system(size: 11)).foregroundStyle(.secondary) }
            HStack {
                Button("Kapat") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Kaydet") {
                    guard let every = Int(interval), let again = Int(retry), (1...10080).contains(every), (1...10080).contains(again), alias.count <= 60 else {
                        validation = "Ad en fazla 60 karakter; dakikalar 1–10080 arasında olmalı."; return
                    }
                    validation = nil
                    model.send("profile", extra: ["id": account.id, "settings": ["alias": alias,
                                "overrideEnabled": custom, "mode": mode, "interval": every, "retryInterval": again]])
                    model.feedback = "Hesap ayarları gönderildi."
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 400)
        .onAppear {
            alias = account.alias; custom = account.overrideEnabled; mode = account.mode
            interval = String(account.interval); retry = String(account.retryInterval); model.feedback = nil
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: Model
    @State private var filter = "all"
    @State private var confirmClear = false
    var entries: [HistoryEntry] {
        model.snapshot.history.filter { filter == "all" || (filter == "success" ? $0.kind == "success" : ["error", "warning"].contains($0.kind)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Kayıtlar", selection: $filter) {
                    Text("Tümü").tag("all"); Text("Başarılı sorgular").tag("success"); Text("Hatalar").tag("error")
                }.labelsHidden()
                Spacer()
                Button { model.exportHistory() } label: { Image(systemName: "square.and.arrow.up") }.help("JSON olarak dışa aktar")
                Button { confirmClear = true } label: { Image(systemName: "trash") }.help("Geçmişi temizle")
                    .disabled(model.snapshot.history.isEmpty)
            }
            Text("Son 300 işlem bu Mac’te tutulur. Geçmişi temizlemek, aynı pencereye tekrar sorgu göndermeme kaydını silmez.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if entries.isEmpty { Text("Henüz kayıt yok.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 25) }
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.symbol).foregroundStyle(entry.color).frame(width: 18).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        let account = model.snapshot.accounts.first { $0.id == entry.accountId }
                        Text((account?.displayName ?? "Uygulama") + " · " + Date(timeIntervalSince1970: entry.at).formatted(date: .abbreviated, time: .standard))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 5)
                Divider()
            }
        }.confirmationDialog("İşlem geçmişi temizlensin mi?", isPresented: $confirmClear) {
            Button("Geçmişi temizle", role: .destructive) { model.send("clearHistory") }
            Button("Vazgeç", role: .cancel) {}
        }
    }
}

struct Panel: View {
    @ObservedObject var model: Model
    @State var tab = 0
    @State private var editingAccount: AccountStatus?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 24, weight: .medium)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex Pulse").font(.system(size: 19, weight: .semibold))
                    Text("\(model.snapshot.accounts.count) hesap · \(model.snapshot.running ? "İzleme açık" : "Duraklatıldı") · 1.1")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.send("refresh") } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Yalnızca durumu yenile · sorgu göndermez").disabled(model.snapshot.activeId != nil)
            }.padding(18)
            Picker("Bölüm", selection: $tab) {
                Text("Hesaplar").tag(0); Text("Ayarlar").tag(1); Text("Geçmiş").tag(2)
            }.labelsHidden().pickerStyle(.segmented).padding(.horizontal, 18).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    if let error = model.backendError ?? model.snapshot.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12))
                            .foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if tab == 0 {
                        if let until = model.snapshot.quietUntil {
                            Label("Sessiz saatler · \(Date(timeIntervalSince1970: until).formatted(date: .omitted, time: .shortened)) saatine kadar", systemImage: "moon.fill")
                                .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if model.snapshot.accounts.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 32)).foregroundStyle(.secondary)
                                Text("Monocode hesapları aranıyor").font(.headline)
                                Text("Monocode’da Codex hesabınıza giriş yaptıktan sonra yenile düğmesine basın.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).padding(.vertical, 30)
                        }
                        ForEach(model.snapshot.accounts) { account in
                            AccountCard(model: model, account: account) { editingAccount = account }
                        }
                    } else if tab == 1 { GlobalSettingsView(model: model) }
                    else { HistoryView(model: model) }
                }.padding(16)
            }.frame(maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if tab != 1, let error = model.snapshot.commandError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                }
                HStack(spacing: 10) {
                    Button { model.send(model.snapshot.running ? "pause" : "start") } label: {
                        Label(model.snapshot.running ? "Durdur" : "Başlat", systemImage: model.snapshot.running ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(model.backendError != nil || model.snapshot.error != nil || model.snapshot.accounts.isEmpty)
                    Menu {
                        Button("Monocode’u aç") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/MonoCode.app")) }
                        Button("Yardım") {
                            if let url = Bundle.main.url(forResource: "KULLANIM", withExtension: "md") { NSWorkspace.shared.open(url) }
                        }
                        Button("Veri klasörünü aç") {
                            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Pulse"))
                        }
                        Divider()
                        Button("Çıkış") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 26)
                }
                Text("\(model.snapshot.settings.mode == "reset" ? "Süre dolunca kontrol" : "Ara kontrol: \(model.snapshot.settings.interval) dk") · Sayaç yerel çalışır.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(16)
        }
        .frame(width: 440, height: min(740, (NSScreen.main?.visibleFrame.height ?? 820) - 60))
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editingAccount) { ProfileSettingsView(model: model, account: $0) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private let model = Model()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.codex.pulse")
        if siblings.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { NSApp.terminate(nil); return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Codex Pulse")
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self; button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.onUpdate = { [weak self] in
            guard let self else { return }
            self.item.button?.title = " " + self.model.compactTitle
            self.item.button?.toolTip = "Codex Pulse · \(self.model.snapshot.accounts.count) hesap"
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: Panel(model: model))
        model.startBackend(); model.onUpdate?()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.togglePopover() }
    }
    @objc func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let control = NSMenuItem(title: model.snapshot.running ? "Durdur" : "Başlat", action: #selector(toggleRunning), keyEquivalent: "")
            control.target = self; menu.addItem(control); menu.addItem(.separator())
            let quit = NSMenuItem(title: "Çıkış", action: #selector(quitApp), keyEquivalent: "q")
            quit.target = self; menu.addItem(quit)
            if let button = item.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button) }
        } else if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    @objc func toggleRunning() { model.send(model.snapshot.running ? "pause" : "start") }
    @objc func quitApp() { NSApp.terminate(nil) }
    @objc func didWake() { if model.snapshot.running { model.send("wake") } }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
}

let application = NSApplication.shared
if CommandLine.arguments.contains("--quit-existing") {
    let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex.pulse")
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    for app in siblings { app.terminate() }
    let deadline = Date().addingTimeInterval(6)
    while siblings.contains(where: { !$0.isTerminated }) && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    exit(siblings.contains(where: { !$0.isTerminated }) ? 1 : 0)
}
if let flag = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > flag + 1 {
    application.setActivationPolicy(.accessory)
    let preview = Model()
    let now = Date().timeIntervalSince1970
    let demoHistory = [
        HistoryEntry(id: "one", at: now, kind: "success", message: "Kısa sorgu tamamlandı", accountId: "preview-one"),
        HistoryEntry(id: "two", at: now - 20, kind: "check", message: "Limit durumu okundu · Yeni pencere açıldı", accountId: "preview-one"),
        HistoryEntry(id: "three", at: now - 180, kind: "settings", message: "Genel ayarlar kaydedildi", accountId: nil)
    ]
    preview.snapshot = Snapshot(running: true, settings: PulseSettings(), accounts: [
        AccountStatus(id: "preview-one", label: "Birinci hesap", plan: "plus", enabled: true,
                      status: "Yenilenme izleniyor", usedPercent: 8, weeklyUsedPercent: 60,
                      resetsAt: now + 11000, nextCheckAt: now + 11015, lastCheckedAt: now,
                      lastTriggeredAt: now - 7200, error: nil, alias: "İş hesabı"),
        AccountStatus(id: "preview-two", label: "İkinci hesap", plan: "plus", enabled: true,
                      status: "Durum okunamadı", usedPercent: nil, weeklyUsedPercent: nil,
                      resetsAt: nil, nextCheckAt: now + 300, lastCheckedAt: nil,
                      lastTriggeredAt: nil, error: "Monocode oturumunu ve internet bağlantısını kontrol edin.")
    ], error: nil, commandError: nil, activeId: nil, history: demoHistory, notification: nil, quietUntil: nil)
    let selectedTab = CommandLine.arguments.contains("--settings-preview") ? 1 : CommandLine.arguments.contains("--history-preview") ? 2 : 0
    let view = NSHostingView(rootView: Panel(model: preview, tab: selectedTab))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 740), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view; view.frame = window.contentLayoutRect; window.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3)); view.layoutSubtreeIfNeeded()
    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])); exit(0)
        }
    }
    exit(1)
}
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

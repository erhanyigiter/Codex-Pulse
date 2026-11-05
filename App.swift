import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

private enum AppLocalization {
    static let english: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Localizations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return catalog["en"] ?? [:]
    }()

    static func text(_ value: String, language: String) -> String {
        guard language == "en" else { return value }
        if let translated = english[value] { return translated }
        if value.hasPrefix("Codex hesabı ") { return "Codex account " + value.dropFirst("Codex hesabı ".count) }
        let prefix = "Limit durumu okundu · "
        if value.hasPrefix(prefix) {
            return (english["Limit durumu okundu"] ?? "Usage limits checked") + " · " + text(String(value.dropFirst(prefix.count)), language: language)
        }
        if value.contains(" · ") {
            return value.components(separatedBy: " · ").map { text($0, language: language) }.joined(separator: " · ")
        }
        return value
    }
}

struct PulseSettings: Codable, Equatable {
    var language = "en"
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

struct CommandResult: Codable {
    let id: String
    let ok: Bool
    let message: String?
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
    var commandResult: CommandResult? = nil
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
    private var requests: [String: (Bool, String?) -> Void] = [:]
    var onUpdate: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?

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
                                if let result = snapshot.commandResult {
                                    self?.requests.removeValue(forKey: result.id)?(result.ok, result.message)
                                }
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

    func send(_ action: String, extra: [String: Any] = [:], completion: ((Bool, String?) -> Void)? = nil) {
        var command = extra
        command["action"] = action
        let requestId = UUID().uuidString
        if let completion {
            command["requestId"] = requestId
            requests[requestId] = completion
        }
        guard let input, let data = try? JSONSerialization.data(withJSONObject: command) else {
            requests.removeValue(forKey: requestId)?(false, "İzleyiciyle bağlantı kurulamadı.")
            return
        }
        do {
            try input.write(contentsOf: data + Data([10]))
            if completion != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    self?.requests.removeValue(forKey: requestId)?(false, "Kayıt onayı alınamadı. Ayarları kontrol edip yeniden deneyin.")
                }
            }
        } catch {
            backendError = "İzleyiciyle bağlantı kesildi. Uygulamayı yeniden açın."
            requests.removeValue(forKey: requestId)?(false, backendError)
        }
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
        panel.title = tr("İşlem geçmişini dışa aktar")
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

    func tr(_ key: String) -> String {
        AppLocalization.text(key, language: snapshot.settings.language)
    }

    func fmt(_ key: String, _ values: [String: String]) -> String {
        values.reduce(tr(key)) { text, entry in text.replacingOccurrences(of: "{\(entry.key)}", with: entry.value) }
    }

    func date(_ timestamp: Double, includeDate: Bool = false, seconds: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: snapshot.settings.language == "tr" ? "tr_TR" : "en_US")
        formatter.dateStyle = includeDate ? .medium : .none
        formatter.timeStyle = seconds ? .medium : .short
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    func inlineCountdown(_ timestamp: Double?) -> String {
        guard let timestamp else { return "—" }
        return timestamp <= now.timeIntervalSince1970 ? tr("Bekliyor") : countdown(timestamp)
    }

    func countdown(_ timestamp: Double?) -> String {
        guard let timestamp else { return "—" }
        let seconds = max(0, Int(ceil(timestamp - now.timeIntervalSince1970)))
        if seconds == 0 { return tr("Yenilenme bekleniyor") }
        let days = seconds / 86400, hours = seconds / 3600 % 24, minutes = seconds / 60 % 60
        return days > 0 ? fmt("{days}g {hours}sa {minutes}dk", ["days": String(days), "hours": String(hours), "minutes": String(minutes)]) : String(format: "%02d:%02d:%02d", hours, minutes, seconds % 60)
    }

    var compactTitle: String {
        if backendError != nil { return tr("Hata") }
        if snapshot.activeId != nil { return tr("Kontrol") }
        let selected = snapshot.accounts.first { $0.id == snapshot.settings.selectedAccountId }
        if !snapshot.running && selected == nil { return tr("Duraklatıldı") }
        let account = selected ?? snapshot.accounts.filter { $0.enabled && $0.error == nil }
            .filter { $0.resetsAt != nil }.min { ($0.resetsAt ?? .infinity) < ($1.resetsAt ?? .infinity) }
        guard let account, let due = account.resetsAt else { return tr("İzleniyor") }
        let seconds = max(0, Int(due - now.timeIntervalSince1970))
        let name = selected == nil ? "" : String(account.displayName.prefix(10)) + " "
        let paused = snapshot.running && account.enabled ? "" : "Ⅱ "
        return paused + name + (seconds == 0 ? tr("Bekliyor") : String(format: "%d:%02d", seconds / 3600, seconds / 60 % 60))
    }
}

struct AccountCard: View {
    @ObservedObject var model: Model
    let account: AccountStatus
    let expanded: Bool
    var toggleExpanded: () -> Void
    var edit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.secondary).frame(width: 9)
                        Image(systemName: "person.crop.circle").font(.system(size: 27)).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(account.displayName)
                            Text(account.alias.isEmpty ? "Monocode · \(account.plan.capitalized)" : model.tr(account.label))
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(model.fmt("{name} ayrıntıları", ["name": account.displayName]))
                    .accessibilityValue(model.tr(expanded ? "Açık" : "Kapalı"))
                Spacer(minLength: 0)
                if !expanded {
                    HStack(spacing: 4) {
                        Image(systemName: "clock").font(.system(size: 9))
                        Text(model.inlineCountdown(account.resetsAt))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.035)))
                    .fixedSize().help(model.tr("Kalan süre"))
                    .accessibilityLabel(model.tr("Kalan süre") + ": " + model.countdown(account.resetsAt))
                }
                Button(action: edit) { Image(systemName: "slider.horizontal.3") }.buttonStyle(.borderless).help(model.tr("Hesap ayarları"))
                Toggle(model.tr("Bu hesabı izle"), isOn: Binding(get: { account.enabled }, set: { _ in
                    model.send("toggle", extra: ["id": account.id])
                })).toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            if expanded {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.countdown(account.resetsAt)).font(.system(size: 23, weight: .medium, design: .monospaced))
                        .foregroundStyle(account.enabled ? Color.primary : Color.secondary)
                    Spacer()
                    Text(model.tr("5 saatlik limit")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    quota("5 saatlik limit", used: account.usedPercent)
                    quota("Haftalık limit", used: account.weeklyUsedPercent)
                }
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(account.error != nil ? Color.orange : account.enabled && model.snapshot.running ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6).padding(.top, 4)
                    Text(model.tr(account.error ?? (account.enabled ? account.status : "Bu hesap kapalı")))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if model.snapshot.activeId == account.id { ProgressView().controlSize(.mini).scaleEffect(0.7) }
                }
                if let checked = account.lastCheckedAt {
                    HStack {
                        Text(model.fmt("Kontrol {time}", ["time": model.date(checked)]))
                        Spacer()
                        if model.snapshot.running && account.enabled {
                            Text(model.fmt("Sonraki {time}", ["time": model.date(account.nextCheckAt, includeDate: true)]))
                        }
                    }.font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if let triggered = account.lastTriggeredAt {
                    Text(model.fmt("Son sorgu {time}", ["time": model.date(triggered, includeDate: true)]))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if account.overrideEnabled {
                    Text(model.fmt("Özel ayar · {mode} · tekrar {minutes} dk", ["mode": account.mode == "reset" ? model.tr("süre dolunca") : model.fmt("her {minutes} dk", ["minutes": String(account.interval)]), "minutes": String(account.retryInterval)]))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }
    func quota(_ label: String, used: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(model.tr(label)); Spacer(); Text(used.map { model.snapshot.settings.language == "en" ? "\(Int($0))%" : "%\(Int($0))" } ?? "—").monospacedDigit() }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ProgressView(value: min(100, max(0, used ?? 0)), total: 100).tint((used ?? 0) >= 95 ? .orange : .accentColor)
        }
    }
}

struct MinuteField: View {
    @ObservedObject var model: Model
    let title: String
    @Binding var text: String
    var body: some View {
        HStack {
            Text(model.tr(title)).font(.system(size: 12))
            Spacer()
            TextField(model.tr("Dakika"), text: $text).textFieldStyle(.roundedBorder).frame(width: 70)
            Text(model.tr("dk")).font(.system(size: 11)).foregroundStyle(.secondary)
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
            GroupBox(model.tr("Dil")) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(model.tr("Uygulama dili"), selection: $draft.language) {
                        Text("English").tag("en")
                        Text("Türkçe").tag("tr")
                    }
                    Text(model.tr("Dil değişikliği kaydedildikten sonra uygulanır."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(8)
            }
            GroupBox(model.tr("Kontrol davranışı")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(model.tr("Mod"), selection: $draft.mode) {
                        Text(model.tr("Sadece süre dolunca")).tag("reset")
                        Text(model.tr("Ara kontrol de yap")).tag("periodic")
                    }.labelsHidden().pickerStyle(.segmented)
                    if draft.mode == "periodic" { MinuteField(model: model, title: "Ara kontrol sıklığı", text: $interval) }
                    MinuteField(model: model, title: "Hata / gecikme sonrası kontrol", text: $retry)
                    Text(model.tr("Süre dolunca 15 saniyelik payla limit doğrulanır. Bu aralık yalnızca durum sorguları içindir; model sorgusu aynı pencere için tekrarlanmaz."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }
            GroupBox(model.tr("Görünüm ve bildirimler")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(model.tr("Menü çubuğu"), selection: $draft.selectedAccountId) {
                        Text(model.tr("En yakın yenilenme")).tag("")
                        ForEach(model.snapshot.accounts) { Text($0.displayName).tag($0.id) }
                    }.font(.system(size: 12))
                    Toggle(model.tr("İşlem ve hata bildirimleri"), isOn: $draft.notificationsEnabled).font(.system(size: 12))
                }.padding(8)
            }
            GroupBox(model.tr("Sessiz saatler · Mac’in yerel saati")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(model.tr("Bu saatlerde otomatik sorgu gönderme"), isOn: $draft.quietEnabled).font(.system(size: 12))
                    HStack {
                        Text(model.tr("Başlangıç")).font(.system(size: 11))
                        TextField("23:00", text: $draft.quietStart).textFieldStyle(.roundedBorder).frame(width: 65)
                        Spacer()
                        Text(model.tr("Bitiş")).font(.system(size: 11))
                        TextField("08:00", text: $draft.quietEnd).textFieldStyle(.roundedBorder).frame(width: 65)
                    }.disabled(!draft.quietEnabled)
                    Text(model.tr("Ertelenen sorgu, sessiz saatler bitince yeniden doğrulanır. Bildirimler de sessize alınır."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }
            GroupBox(model.tr("Açılış")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(model.tr("Uygulama açılınca izlemeyi başlat"), isOn: $draft.autoStart).font(.system(size: 12))
                    Text(model.tr("Kapalıysa her açılışta Başlat’a basmanız gerekir. Bu seçim mevcut izlemeyi değiştirmez."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle(model.tr("Mac oturumu açılınca uygulamayı aç"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
                        .font(.system(size: 12))
                }.padding(8)
            }
            if let text = validation ?? model.snapshot.commandError { Text(model.tr(text)).font(.system(size: 11)).foregroundStyle(.orange) }
            if let text = model.feedback { Text(model.tr(text)).font(.system(size: 11)).foregroundStyle(.secondary) }
            Button(model.tr("Ayarları kaydet")) {
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
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(model.tr("Hesap ayarları")).font(.system(size: 19, weight: .semibold))
            Text(model.tr(account.label)).font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(model.tr("Takma ad · ör. İş hesabı"), text: $alias).textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            Toggle(model.tr("Bu hesap için farklı kontrol ayarları"), isOn: $custom).font(.system(size: 12))
            if custom {
                Picker(model.tr("Mod"), selection: $mode) {
                    Text(model.tr("Sadece süre dolunca")).tag("reset")
                    Text(model.tr("Ara kontrol de yap")).tag("periodic")
                }.labelsHidden().pickerStyle(.segmented)
                if mode == "periodic" { MinuteField(model: model, title: "Ara kontrol sıklığı", text: $interval) }
                MinuteField(model: model, title: "Hata / gecikme sonrası kontrol", text: $retry)
            } else {
                Text(model.tr("Genel kontrol ayarları kullanılır. Sessiz saatler ve açılış tercihi tüm hesaplar için ortaktır."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let text = validation ?? model.snapshot.commandError { Text(model.tr(text)).font(.system(size: 11)).foregroundStyle(.orange) }
            if let text = model.feedback { Text(model.tr(text)).font(.system(size: 11)).foregroundStyle(.secondary) }
            HStack {
                Button(model.tr("Kapat")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.tr(saving ? "Kaydediliyor…" : "Kaydet")) { save() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving)
            }
        }.padding(24).frame(width: 400).disabled(saving)
        .onAppear {
            alias = account.alias; custom = account.overrideEnabled; mode = account.mode
            interval = String(account.interval); retry = String(account.retryInterval); model.feedback = nil
        }
    }

    private func save() {
        guard !saving else { return }
        guard let every = Int(interval), let again = Int(retry), (1...10080).contains(every),
              (1...10080).contains(again), alias.count <= 60 else {
            validation = "Ad en fazla 60 karakter; dakikalar 1–10080 arasında olmalı."
            return
        }
        validation = nil
        saving = true
        model.send("profile", extra: ["id": account.id, "settings": ["alias": alias,
                    "overrideEnabled": custom, "mode": mode, "interval": every, "retryInterval": again]]) { ok, message in
            saving = false
            if ok { dismiss() }
            else { validation = message ?? "Hesap ayarları kaydedilemedi." }
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
                Picker(model.tr("Kayıtlar"), selection: $filter) {
                    Text(model.tr("Tümü")).tag("all"); Text(model.tr("Başarılı sorgular")).tag("success"); Text(model.tr("Hatalar")).tag("error")
                }.labelsHidden()
                Spacer()
                Button { model.exportHistory() } label: { Image(systemName: "square.and.arrow.up") }.help(model.tr("JSON olarak dışa aktar"))
                Button { confirmClear = true } label: { Image(systemName: "trash") }.help(model.tr("Geçmişi temizle"))
                    .disabled(model.snapshot.history.isEmpty)
            }
            Text(model.tr("Son 300 işlem bu Mac’te tutulur. Geçmişi temizlemek, aynı pencereye tekrar sorgu göndermeme kaydını silmez."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if entries.isEmpty { Text(model.tr("Henüz kayıt yok.")).font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 25) }
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.symbol).foregroundStyle(entry.color).frame(width: 18).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.tr(entry.message)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        let account = model.snapshot.accounts.first { $0.id == entry.accountId }
                        Text((account?.displayName ?? model.tr("Uygulama")) + " · " + model.date(entry.at, includeDate: true, seconds: true))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 5)
                Divider()
            }
        }.confirmationDialog(model.tr("İşlem geçmişi temizlensin mi?"), isPresented: $confirmClear) {
            Button(model.tr("Geçmişi temizle"), role: .destructive) { model.send("clearHistory") }
            Button(model.tr("Vazgeç"), role: .cancel) {}
        }
    }
}

private struct PanelHeightsKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func trackPanelHeight(_ key: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: PanelHeightsKey.self, value: [key: geometry.size.height])
        })
    }
}

struct Panel: View {
    @ObservedObject var model: Model
    @State var tab = 0
    @State private var editingAccount: AccountStatus?
    @State var expandedAccounts: Set<String> = []
    @State private var heights: [String: CGFloat] = [:]

    private var panelHeight: CGFloat {
        let maximum = min(740, (NSScreen.main?.visibleFrame.height ?? 820) - 60)
        guard tab == 0 else { return maximum }
        let rows = Array(model.snapshot.accounts.prefix(3))
        let cards = rows.reduce(CGFloat(0)) { total, account in
            total + (heights["account-" + account.id] ?? 65)
        }
        var content: CGFloat = rows.isEmpty ? (heights["empty"] ?? 120) : cards + CGFloat(max(0, rows.count - 1)) * 12
        content += model.snapshot.accounts.count > 3 ? 24 : 32
        if model.backendError != nil || model.snapshot.error != nil {
            content += (heights["error"] ?? 40) + 12
        }
        if model.snapshot.quietUntil != nil { content += (heights["quiet"] ?? 16) + 12 }
        return min(maximum, (heights["header"] ?? 115) + (heights["footer"] ?? 85) + content)
    }

    private func toggleAccount(_ id: String) {
        if expandedAccounts.contains(id) { expandedAccounts.remove(id) }
        else { expandedAccounts.insert(id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg").font(.system(size: 24, weight: .medium)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Codex Pulse").font(.system(size: 19, weight: .semibold))
                        Text(model.fmt(model.snapshot.accounts.count == 1 ? "1 hesap · {status} · {version}" : "{count} hesap · {status} · {version}", ["count": String(model.snapshot.accounts.count), "status": model.tr(model.snapshot.running ? "İzleme açık" : "Duraklatıldı"), "version": "1.2"]))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.send("refresh") } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(model.tr("Yalnızca durumu yenile · sorgu göndermez")).disabled(model.snapshot.activeId != nil)
                }.padding(18)
                Picker(model.tr("Bölüm"), selection: $tab) {
                    Text(model.tr("Hesaplar")).tag(0); Text(model.tr("Ayarlar")).tag(1); Text(model.tr("Geçmiş")).tag(2)
                }.labelsHidden().pickerStyle(.segmented).padding(.horizontal, 18).padding(.bottom, 12)
                Divider()
            }.trackPanelHeight("header")
            ScrollView {
                VStack(spacing: 12) {
                    if let error = model.backendError ?? model.snapshot.error {
                        Label(model.tr(error), systemImage: "exclamationmark.triangle").font(.system(size: 12))
                            .foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                            .trackPanelHeight("error")
                    }
                    if tab == 0 {
                        if let until = model.snapshot.quietUntil {
                            Label(model.fmt("Sessiz saatler · {time} saatine kadar", ["time": model.date(until)]), systemImage: "moon.fill")
                                .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                .trackPanelHeight("quiet")
                        }
                        if model.snapshot.accounts.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 32)).foregroundStyle(.secondary)
                                Text(model.tr("Monocode hesapları aranıyor")).font(.headline)
                                Text(model.tr("Monocode’da Codex hesabınıza giriş yaptıktan sonra yenile düğmesine basın."))
                                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).padding(.vertical, 30).trackPanelHeight("empty")
                        }
                        ForEach(model.snapshot.accounts) { account in
                            AccountCard(model: model, account: account, expanded: expandedAccounts.contains(account.id),
                                        toggleExpanded: { toggleAccount(account.id) }, edit: { editingAccount = account })
                                .trackPanelHeight("account-" + account.id)
                        }
                    } else if tab == 1 { GlobalSettingsView(model: model) }
                    else { HistoryView(model: model) }
                }.padding(16)
            }.frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if tab != 1, let error = model.snapshot.commandError {
                        Text(model.tr(error)).font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    HStack(spacing: 10) {
                        Button { model.send(model.snapshot.running ? "pause" : "start") } label: {
                            Label(model.tr(model.snapshot.running ? "Durdur" : "Başlat"), systemImage: model.snapshot.running ? "pause.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(model.backendError != nil || model.snapshot.error != nil || model.snapshot.accounts.isEmpty)
                        Menu {
                            Button(model.tr("Monocode’u aç")) { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/MonoCode.app")) }
                            Button(model.tr("Yardım")) {
                                if let url = Bundle.main.url(forResource: model.snapshot.settings.language == "tr" ? "KULLANIM" : "USAGE", withExtension: "md") { NSWorkspace.shared.open(url) }
                            }
                            Button(model.tr("Veri klasörünü aç")) {
                                NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Pulse"))
                            }
                            Divider()
                            Button(model.tr("Çıkış")) { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 26)
                    }
                    Text((model.snapshot.settings.mode == "reset" ? model.tr("Süre dolunca kontrol") : model.fmt("Ara kontrol: {minutes} dk", ["minutes": String(model.snapshot.settings.interval)])) + " · " + model.tr("Sayaç yerel çalışır."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(16)
            }.trackPanelHeight("footer")
        }
        .frame(width: 440, height: panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editingAccount) { ProfileSettingsView(model: model, account: $0) }
        .onPreferenceChange(PanelHeightsKey.self) { values in
            let rounded = values.mapValues { ceil($0 * 2) / 2 }
            if heights != rounded { heights = rounded }
        }
        .onAppear { model.onResize?(panelHeight) }
        .onChange(of: panelHeight) { model.onResize?($0) }
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
        model.onResize = { [weak self] height in
            self?.popover.contentSize = NSSize(width: 440, height: height)
        }
        popover.contentViewController = NSHostingController(rootView: Panel(model: model))
        model.startBackend(); model.onUpdate?()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.togglePopover() }
    }
    @objc func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let control = NSMenuItem(title: model.tr(model.snapshot.running ? "Durdur" : "Başlat"), action: #selector(toggleRunning), keyEquivalent: "")
            control.target = self; menu.addItem(control); menu.addItem(.separator())
            let quit = NSMenuItem(title: model.tr("Çıkış"), action: #selector(quitApp), keyEquivalent: "q")
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
    var demoAccounts = [
        AccountStatus(id: "preview-one", label: "work@example.com", plan: "plus", enabled: true,
                      status: "Yenilenme izleniyor", usedPercent: 8, weeklyUsedPercent: 60,
                      resetsAt: now + 11000, nextCheckAt: now + 11015, lastCheckedAt: now,
                      lastTriggeredAt: now - 7200, error: nil, alias: "Work"),
        AccountStatus(id: "preview-two", label: "personal@example.com", plan: "plus", enabled: true,
                      status: "Yenilenme izleniyor", usedPercent: 21, weeklyUsedPercent: 38,
                      resetsAt: now + 5400, nextCheckAt: now + 5415, lastCheckedAt: now,
                      lastTriggeredAt: nil, error: nil, alias: "Personal")
    ]
    if let countFlag = CommandLine.arguments.firstIndex(of: "--preview-count"),
       CommandLine.arguments.count > countFlag + 1, let count = Int(CommandLine.arguments[countFlag + 1]), (1...6).contains(count) {
        let original = demoAccounts
        demoAccounts = (0..<count).map { index in
            if index < original.count { return original[index] }
            return AccountStatus(id: "preview-extra-\(index)", label: "Sample account \(index + 1)", plan: "plus", enabled: true,
                                 status: "Yenilenme izleniyor", usedPercent: 12, weeklyUsedPercent: 30,
                                 resetsAt: now + 8000, nextCheckAt: now + 8015, lastCheckedAt: now,
                                 lastTriggeredAt: nil, error: nil)
        }
    }
    var previewSettings = PulseSettings()
    if CommandLine.arguments.contains("--turkish-preview") { previewSettings.language = "tr" }
    preview.snapshot = Snapshot(running: true, settings: previewSettings, accounts: demoAccounts,
                                error: nil, commandError: nil, activeId: nil, history: demoHistory, notification: nil, quietUntil: nil)
    let selectedTab = CommandLine.arguments.contains("--settings-preview") ? 1 : CommandLine.arguments.contains("--history-preview") ? 2 : 0
    let expanded: Set<String> = CommandLine.arguments.contains("--expanded-preview") ? Set(demoAccounts.prefix(2).map(\.id)) : []
    let view = NSHostingView(rootView: Panel(model: preview, tab: selectedTab, expandedAccounts: expanded))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
    preview.onResize = { height in window.setContentSize(NSSize(width: 440, height: height)) }
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

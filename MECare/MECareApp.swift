import SwiftUI
import UserNotifications
import AVFoundation

@main
struct MECareApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = MedicationStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .task {
                    await NotificationManager.shared.requestAuthorizationIfNeeded()
                    await store.rescheduleNotifications()
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.shared.registerCategories()
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let medicationID = info["medicationID"] as? String
        let doseKey = info["doseKey"] as? String

        NotificationCenter.default.post(
            name: .mecareNotificationAction,
            object: nil,
            userInfo: [
                "action": response.actionIdentifier,
                "medicationID": medicationID ?? "",
                "doseKey": doseKey ?? ""
            ]
        )
        completionHandler()
    }
}

extension Notification.Name {
    static let mecareNotificationAction = Notification.Name("MECare.NotificationAction")
}

// MARK: - Models

struct DoseTime: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var hour: Int
    var minute: Int

    var displayText: String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let date = Calendar.current.date(from: components) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ar_SA")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    var dateForPicker: Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    static func from(date: Date) -> DoseTime {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return DoseTime(hour: parts.hour ?? 8, minute: parts.minute ?? 0)
    }
}

enum FoodRelation: String, Codable, CaseIterable, Identifiable {
    case none = "بدون تعليمات"
    case before = "قبل الأكل"
    case after = "بعد الأكل"
    case withFood = "مع الأكل"

    var id: String { rawValue }
}

struct Medication: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var dose: String
    var spokenName: String
    var foodRelation: FoodRelation
    var notes: String
    var times: [DoseTime]
    var startDate: Date
    var endDate: Date?
    var notificationsEnabled: Bool
    var voiceReminderEnabled: Bool

    var displayName: String {
        dose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? name : "\(name) \(dose)"
    }
}

struct DoseLog: Identifiable, Codable, Hashable {
    enum Status: String, Codable {
        case taken
        case snoozed
    }

    var id: UUID = UUID()
    var medicationID: UUID
    var doseKey: String
    var medicationName: String
    var scheduledAt: Date
    var actionAt: Date
    var status: Status
}

struct StoreEnvelope: Codable {
    var profileName: String
    var medications: [Medication]
    var logs: [DoseLog]
}

struct DoseOccurrence: Identifiable, Hashable {
    var medication: Medication
    var doseTime: DoseTime
    var scheduledAt: Date

    var id: String { "\(medication.id.uuidString)-\(doseKey)" }

    var doseKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm"
        return formatter.string(from: scheduledAt)
    }
}

// MARK: - Store

@MainActor
final class MedicationStore: ObservableObject {
    @Published var profileName: String
    @Published var medications: [Medication]
    @Published var logs: [DoseLog]

    private var observer: NSObjectProtocol?

    init() {
        if let loaded = Self.load() {
            profileName = loaded.profileName
            medications = loaded.medications
            logs = loaded.logs
        } else {
            profileName = "سارة"
            medications = [Self.seedMedication]
            logs = []
            save()
        }

        observer = NotificationCenter.default.addObserver(
            forName: .mecareNotificationAction,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            Task { @MainActor in
                self.handleNotificationAction(note)
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    static var seedMedication: Medication {
        Medication(
            name: "Concor",
            dose: "5 mg",
            spokenName: "كونكور خمسة مليجرام",
            foodRelation: .after,
            notes: "بعد الغداء",
            times: [
                DoseTime(hour: 8, minute: 0),
                DoseTime(hour: 13, minute: 0),
                DoseTime(hour: 20, minute: 0)
            ],
            startDate: Calendar.current.startOfDay(for: Date()),
            endDate: nil,
            notificationsEnabled: true,
            voiceReminderEnabled: true
        )
    }

    func addMedication(_ medication: Medication) {
        medications.append(medication)
        persistAndReschedule()
    }

    func updateMedication(_ medication: Medication) {
        guard let index = medications.firstIndex(where: { $0.id == medication.id }) else { return }
        medications[index] = medication
        persistAndReschedule()
    }

    func deleteMedication(id: UUID) {
        medications.removeAll { $0.id == id }
        logs.removeAll { $0.medicationID == id }
        persistAndReschedule()
    }

    func updateProfileName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profileName = trimmed.isEmpty ? "المستخدم" : trimmed
        persistAndReschedule()
    }

    func markTaken(_ occurrence: DoseOccurrence) {
        logs.removeAll { $0.doseKey == occurrence.doseKey && $0.medicationID == occurrence.medication.id }
        logs.append(
            DoseLog(
                medicationID: occurrence.medication.id,
                doseKey: occurrence.doseKey,
                medicationName: occurrence.medication.displayName,
                scheduledAt: occurrence.scheduledAt,
                actionAt: Date(),
                status: .taken
            )
        )
        save()
    }

    func snooze(_ occurrence: DoseOccurrence, minutes: Int = 10) {
        logs.removeAll { $0.doseKey == occurrence.doseKey && $0.medicationID == occurrence.medication.id }
        logs.append(
            DoseLog(
                medicationID: occurrence.medication.id,
                doseKey: occurrence.doseKey,
                medicationName: occurrence.medication.displayName,
                scheduledAt: occurrence.scheduledAt,
                actionAt: Date(),
                status: .snoozed
            )
        )
        save()

        Task {
            await NotificationManager.shared.scheduleSnooze(
                userName: profileName,
                medication: occurrence.medication,
                originalDoseKey: occurrence.doseKey,
                minutes: minutes
            )
        }
    }

    func status(for occurrence: DoseOccurrence) -> DoseVisualState {
        if let log = logs.last(where: { $0.medicationID == occurrence.medication.id && $0.doseKey == occurrence.doseKey }) {
            if log.status == .taken { return .taken }
            if log.status == .snoozed { return .snoozed }
        }

        let delta = occurrence.scheduledAt.timeIntervalSinceNow
        if delta > 30 * 60 { return .upcoming }
        if delta >= -30 * 60 { return .due }
        return .missed
    }

    var todayOccurrences: [DoseOccurrence] {
        occurrences(for: Date())
    }

    var nextOccurrence: DoseOccurrence? {
        let now = Date()
        let today = occurrences(for: now)
        if let current = today.first(where: { status(for: $0) == .due }) {
            return current
        }
        if let future = today.first(where: { $0.scheduledAt > now && status(for: $0) != .taken }) {
            return future
        }
        if let missed = today.last(where: { status(for: $0) == .missed }) {
            return missed
        }

        if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) {
            return occurrences(for: tomorrow).first
        }
        return nil
    }

    func occurrences(for date: Date) -> [DoseOccurrence] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)

        return medications
            .filter { medication in
                let start = calendar.startOfDay(for: medication.startDate)
                let afterStart = dayStart >= start
                if let endDate = medication.endDate {
                    return afterStart && dayStart <= calendar.startOfDay(for: endDate)
                }
                return afterStart
            }
            .flatMap { medication in
                medication.times.compactMap { time -> DoseOccurrence? in
                    guard let scheduled = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: dayStart) else {
                        return nil
                    }
                    return DoseOccurrence(medication: medication, doseTime: time, scheduledAt: scheduled)
                }
            }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    func rescheduleNotifications() async {
        await NotificationManager.shared.reschedule(
            medications: medications,
            userName: profileName
        )
    }

    private func persistAndReschedule() {
        save()
        Task { await rescheduleNotifications() }
    }

    private func handleNotificationAction(_ note: Notification) {
        guard let userInfo = note.userInfo,
              let action = userInfo["action"] as? String,
              let medicationIDString = userInfo["medicationID"] as? String,
              let medicationID = UUID(uuidString: medicationIDString),
              let doseKey = userInfo["doseKey"] as? String,
              let medication = medications.first(where: { $0.id == medicationID }) else {
            return
        }

        let occurrence = todayOccurrences.first(where: { $0.medication.id == medicationID && $0.doseKey == doseKey })
            ?? DoseOccurrence(
                medication: medication,
                doseTime: medication.times.first ?? DoseTime(hour: 8, minute: 0),
                scheduledAt: Date()
            )

        if action == NotificationManager.takenAction {
            markTaken(occurrence)
        } else if action == NotificationManager.snoozeAction {
            snooze(occurrence)
        }
    }

    private func save() {
        do {
            let envelope = StoreEnvelope(profileName: profileName, medications: medications, logs: logs)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(envelope)
            try Self.ensureStorageDirectory()
            try data.write(to: Self.storageURL, options: [.atomic])
        } catch {
            print("MECare save error: \(error)")
        }
    }

    private static func load() -> StoreEnvelope? {
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(StoreEnvelope.self, from: data)
        } catch {
            return nil
        }
    }

    private static var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MECare", isDirectory: true).appendingPathComponent("state.json")
    }

    private static func ensureStorageDirectory() throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}

enum DoseVisualState {
    case upcoming
    case due
    case taken
    case snoozed
    case missed

    var title: String {
        switch self {
        case .upcoming: return "قادم"
        case .due: return "الآن"
        case .taken: return "تم"
        case .snoozed: return "مؤجل"
        case .missed: return "فات الموعد"
        }
    }

    var color: Color {
        switch self {
        case .upcoming: return METheme.violet
        case .due: return METheme.blue
        case .taken: return METheme.green
        case .snoozed: return METheme.orange
        case .missed: return METheme.red
        }
    }
}

// MARK: - Notifications & Spoken Reminder Audio

final class NotificationManager {
    static let shared = NotificationManager()

    static let categoryID = "MECare.MedicationReminder"
    static let takenAction = "MECare.Taken"
    static let snoozeAction = "MECare.Snooze10"

    private let center = UNUserNotificationCenter.current()
    private let audioGenerator = SpokenReminderAudioGenerator()

    private init() {}

    func registerCategories() {
        let taken = UNNotificationAction(
            identifier: Self.takenAction,
            title: "تم أخذ العلاج",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: Self.snoozeAction,
            title: "ذكّريني بعد 10 دقائق",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [taken, snooze],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func requestAuthorizationIfNeeded() async {
        do {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            }
        } catch {
            print("MECare notification authorization error: \(error)")
        }
    }

    func reschedule(medications: [Medication], userName: String) async {
        center.removeAllPendingNotificationRequests()

        let calendar = Calendar.current
        let now = Date()
        let horizon = calendar.date(byAdding: .day, value: 21, to: now) ?? now
        var candidates: [(Date, Medication, DoseTime)] = []

        for medication in medications where medication.notificationsEnabled {
            var day = calendar.startOfDay(for: max(medication.startDate, now))
            let end = min(medication.endDate ?? horizon, horizon)

            while day <= end {
                for doseTime in medication.times {
                    if let scheduled = calendar.date(bySettingHour: doseTime.hour, minute: doseTime.minute, second: 0, of: day),
                       scheduled > now {
                        candidates.append((scheduled, medication, doseTime))
                    }
                }
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = nextDay
            }
        }

        candidates.sort { $0.0 < $1.0 }
        let limited = Array(candidates.prefix(60))

        var soundCache: [UUID: UNNotificationSound] = [:]

        for (scheduled, medication, doseTime) in limited {
            let content = UNMutableNotificationContent()
            content.title = "موعد العلاج"
            content.subtitle = medication.displayName
            content.body = "يا \(userName)، حان موعد \(medication.displayName). \(medication.foodRelation.rawValue)."
            content.categoryIdentifier = Self.categoryID
            content.interruptionLevel = .timeSensitive

            let doseKey = Self.doseKey(for: scheduled)
            content.userInfo = [
                "medicationID": medication.id.uuidString,
                "doseKey": doseKey
            ]

            if medication.voiceReminderEnabled {
                if let cached = soundCache[medication.id] {
                    content.sound = cached
                } else if let sound = await customSound(userName: userName, medication: medication, doseTime: doseTime) {
                    soundCache[medication.id] = sound
                    content.sound = sound
                } else {
                    content.sound = .default
                }
            } else {
                content.sound = .default
            }

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: scheduled),
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: "MECare.\(medication.id.uuidString).\(doseKey)",
                content: content,
                trigger: trigger
            )

            do {
                try await center.add(request)
            } catch {
                print("MECare schedule error: \(error)")
            }
        }
    }

    func scheduleSnooze(
        userName: String,
        medication: Medication,
        originalDoseKey: String,
        minutes: Int
    ) async {
        let content = UNMutableNotificationContent()
        content.title = "تذكير بالعلاج"
        content.subtitle = medication.displayName
        content.body = "يا \(userName)، ما زال موعد العلاج بانتظار التأكيد."
        content.categoryIdentifier = Self.categoryID
        content.interruptionLevel = .timeSensitive
        content.userInfo = [
            "medicationID": medication.id.uuidString,
            "doseKey": originalDoseKey
        ]

        if medication.voiceReminderEnabled,
           let sound = await customSound(
                userName: userName,
                medication: medication,
                doseTime: medication.times.first ?? DoseTime(hour: 8, minute: 0)
           ) {
            content.sound = sound
        } else {
            content.sound = .default
        }

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(max(minutes, 1) * 60),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: "MECare.Snooze.\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
        } catch {
            print("MECare snooze error: \(error)")
        }
    }

    private func customSound(
        userName: String,
        medication: Medication,
        doseTime: DoseTime
    ) async -> UNNotificationSound? {
        let spokenName = medication.spokenName.trimmingCharacters(in: .whitespacesAndNewlines)
        let medicine = spokenName.isEmpty ? medication.displayName : spokenName
        let text = "يا \(userName)، حان موعد علاج \(medicine). \(medication.foodRelation.rawValue). من فضلك خذي العلاج الآن."

        guard let url = await audioGenerator.generate(
            identifier: medication.id.uuidString,
            text: text
        ) else {
            return nil
        }
        return UNNotificationSound(named: UNNotificationSoundName(url.lastPathComponent))
    }

    private static func doseKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm"
        return formatter.string(from: date)
    }
}

final class SpokenReminderAudioGenerator {
    private let synthesizer = AVSpeechSynthesizer()

    func generate(identifier: String, text: String) async -> URL? {
        let directory: URL
        do {
            directory = try soundsDirectory()
        } catch {
            print("MECare sounds directory error: \(error)")
            return nil
        }

        let fileName = "mecare_\(identifier.replacingOccurrences(of: "-", with: ""))_ar.caf"
        let destination = directory.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        return await withCheckedContinuation { continuation in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "ar-SA") ?? AVSpeechSynthesisVoice(language: "ar")
            utterance.rate = 0.42
            utterance.volume = 1.0

            var audioFile: AVAudioFile?
            var didResume = false

            synthesizer.write(utterance) { buffer in
                guard !didResume else { return }
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }

                if pcmBuffer.frameLength == 0 {
                    didResume = true
                    continuation.resume(returning: FileManager.default.fileExists(atPath: destination.path) ? destination : nil)
                    return
                }

                do {
                    if audioFile == nil {
                        audioFile = try AVAudioFile(
                            forWriting: destination,
                            settings: pcmBuffer.format.settings
                        )
                    }
                    try audioFile?.write(from: pcmBuffer)
                } catch {
                    print("MECare spoken audio error: \(error)")
                    try? FileManager.default.removeItem(at: destination)
                    didResume = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func soundsDirectory() throws -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let sounds = library.appendingPathComponent("Sounds", isDirectory: true)
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        return sounds
    }
}

// MARK: - Theme

enum METheme {
    static let background = Color(red: 0.008, green: 0.014, blue: 0.028)
    static let panel = Color(red: 0.035, green: 0.055, blue: 0.095)
    static let panel2 = Color(red: 0.055, green: 0.075, blue: 0.12)
    static let blue = Color(red: 0.05, green: 0.49, blue: 1.0)
    static let cyan = Color(red: 0.0, green: 0.82, blue: 1.0)
    static let violet = Color(red: 0.48, green: 0.27, blue: 1.0)
    static let red = Color(red: 0.96, green: 0.18, blue: 0.24)
    static let green = Color(red: 0.12, green: 0.82, blue: 0.45)
    static let orange = Color(red: 1.0, green: 0.55, blue: 0.12)
    static let secondary = Color.white.opacity(0.68)

    static let gradient = LinearGradient(
        colors: [cyan, blue, violet],
        startPoint: .leading,
        endPoint: .trailing
    )
}

struct MEOrb: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(METheme.panel)
            Circle()
                .stroke(METheme.gradient, lineWidth: max(2, size * 0.025))
                .shadow(color: METheme.blue.opacity(0.8), radius: size * 0.08)
            Circle()
                .fill(METheme.gradient.opacity(0.18))
                .padding(size * 0.12)
            Text("ME")
                .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct MEPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(METheme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.white.opacity(0.05), lineWidth: 1)
                    )
            )
    }
}

// MARK: - Root / Splash / Tabs

struct RootView: View {
    @State private var showSplash = true

    var body: some View {
        ZStack {
            METheme.background.ignoresSafeArea()
            if showSplash {
                SplashView().transition(.opacity)
            } else {
                MainTabView().transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeInOut(duration: 0.4)) {
                showSplash = false
            }
        }
    }
}

struct SplashView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            MEOrb(size: 190)
            Text("MECare")
                .font(.system(size: 46, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("ME Medication Companion")
                .font(.headline)
                .foregroundStyle(METheme.gradient)
            Text("Smart Medicine Reminder")
                .font(.title3)
                .foregroundStyle(METheme.secondary)
            Spacer()
            Text("Engineer Mahmoud Ebid")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            Text("MECare v0.5.0 Integrated")
                .font(.caption)
                .foregroundStyle(METheme.secondary)
                .padding(.bottom, 32)
        }
        .padding(.horizontal, 24)
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("الرئيسية", systemImage: "house.fill") }

            NavigationStack { MedicationsView() }
                .tabItem { Label("علاجاتي", systemImage: "pills.fill") }

            NavigationStack { DailyLogView() }
                .tabItem { Label("السجل", systemImage: "list.bullet.clipboard.fill") }

            NavigationStack { SettingsView() }
                .tabItem { Label("الإعدادات", systemImage: "gearshape.fill") }
        }
        .tint(METheme.cyan)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var store: MedicationStore
    @State private var showingAdd = false
    private let speaker = AVSpeechSynthesizer()

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header

                if let occurrence = store.nextOccurrence {
                    nextDoseCard(occurrence)
                    voiceCard(occurrence)
                } else {
                    emptyState
                }

                todayCard
                footer
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(METheme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingAdd) {
            MedicationEditorView(mode: .add)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(METheme.cyan)
                }
                Spacer()
                HStack(spacing: 10) {
                    Text("MECare").font(.title2.bold())
                    MEOrb(size: 42)
                }
                Spacer()
                Image(systemName: "bell.badge.fill")
                    .font(.title3)
                    .foregroundStyle(METheme.violet)
            }

            Text("\(greeting) يا \(store.profileName)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Text("نحن هنا لنهتم بمواعيد العلاج كل يوم")
                .foregroundStyle(METheme.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "صباح الخير" }
        if hour < 18 { return "مساء الخير" }
        return "مساء الخير"
    }

    private func nextDoseCard(_ occurrence: DoseOccurrence) -> some View {
        let state = store.status(for: occurrence)
        return MEPanel {
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    VStack(alignment: .trailing, spacing: 7) {
                        Text(state == .taken ? "تم أخذ العلاج" : "العلاج القادم")
                            .font(.headline)
                            .foregroundStyle(state.color)
                        Text(occurrence.medication.displayName)
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                        Label(occurrence.doseTime.displayText, systemImage: "clock.fill")
                        Label(occurrence.medication.foodRelation.rawValue, systemImage: "fork.knife")
                            .foregroundStyle(METheme.secondary)
                        if !occurrence.medication.notes.isEmpty {
                            Text(occurrence.medication.notes)
                                .font(.subheadline)
                                .foregroundStyle(METheme.secondary)
                        }
                    }
                    Spacer()
                    ZStack {
                        Circle().stroke(METheme.gradient, lineWidth: 2)
                        Image(systemName: "capsule.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(METheme.gradient)
                            .rotationEffect(.degrees(-35))
                    }
                    .frame(width: 94, height: 94)
                }

                HStack(spacing: 10) {
                    Image(systemName: stateIcon(state))
                    Text(state.title).fontWeight(.bold)
                    Spacer()
                    Text(relativeText(for: occurrence.scheduledAt))
                        .foregroundStyle(METheme.secondary)
                }
                .foregroundStyle(state.color)

                Button {
                    store.markTaken(occurrence)
                } label: {
                    Label("تم أخذ العلاج", systemImage: "checkmark.circle.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(RoundedRectangle(cornerRadius: 18).fill(METheme.gradient))
                        .foregroundStyle(.white)
                }

                Button {
                    store.snooze(occurrence)
                } label: {
                    Label("ذكّريني بعد 10 دقائق", systemImage: "alarm.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(METheme.blue, lineWidth: 1))
                }
            }
        }
    }

    private func voiceCard(_ occurrence: DoseOccurrence) -> some View {
        Button {
            speakReminder(for: occurrence)
        } label: {
            MEPanel {
                HStack(spacing: 15) {
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(METheme.gradient)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("التنبيه الصوتي")
                            .font(.headline)
                            .foregroundStyle(METheme.violet)
                        Text("اضغط لسماع نموذج التذكير العربي")
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Image(systemName: "waveform")
                        .font(.title)
                        .foregroundStyle(METheme.gradient)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var todayCard: some View {
        MEPanel {
            VStack(alignment: .trailing, spacing: 13) {
                HStack {
                    Text("\(store.todayOccurrences.count) جرعة")
                        .font(.caption)
                        .foregroundStyle(METheme.secondary)
                    Spacer()
                    Text("علاجات اليوم").font(.title3.bold())
                }

                if store.todayOccurrences.isEmpty {
                    Text("لا توجد مواعيد علاج اليوم")
                        .foregroundStyle(METheme.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(store.todayOccurrences) { occurrence in
                        doseRow(occurrence)
                    }
                }
            }
        }
    }

    private func doseRow(_ occurrence: DoseOccurrence) -> some View {
        let state = store.status(for: occurrence)
        return HStack(spacing: 9) {
            Text(state.title)
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(state.color.opacity(0.75)))
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(occurrence.medication.displayName).font(.headline)
                Text(occurrence.doseTime.displayText)
                    .font(.caption)
                    .foregroundStyle(METheme.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var emptyState: some View {
        MEPanel {
            VStack(spacing: 14) {
                Image(systemName: "pills.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(METheme.gradient)
                Text("لا يوجد علاج مضاف")
                    .font(.title3.bold())
                Text("أضف العلاج ومواعيده مرة واحدة، وMECare يتولى التذكير والمتابعة.")
                    .foregroundStyle(METheme.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    showingAdd = true
                } label: {
                    Label("إضافة علاج", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(METheme.gradient))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Engineer Mahmoud Ebid").font(.headline)
                Text("MECare v0.5.0 • Integrated Build")
                    .font(.caption)
                    .foregroundStyle(METheme.secondary)
            }
            Spacer()
            MEOrb(size: 46)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22).fill(METheme.panel))
    }

    private func stateIcon(_ state: DoseVisualState) -> String {
        switch state {
        case .taken: return "checkmark.circle.fill"
        case .snoozed: return "alarm.fill"
        case .missed: return "exclamationmark.triangle.fill"
        case .due: return "clock.badge.exclamationmark.fill"
        case .upcoming: return "clock.fill"
        }
    }

    private func relativeText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ar_SA")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func speakReminder(for occurrence: DoseOccurrence) {
        let spoken = occurrence.medication.spokenName.trimmingCharacters(in: .whitespacesAndNewlines)
        let medicine = spoken.isEmpty ? occurrence.medication.displayName : spoken
        let text = "يا \(store.profileName)، حان موعد علاج \(medicine). \(occurrence.medication.foodRelation.rawValue). من فضلك خذي العلاج الآن."
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ar-SA") ?? AVSpeechSynthesisVoice(language: "ar")
        utterance.rate = 0.42
        utterance.volume = 1.0
        speaker.speak(utterance)
    }
}

// MARK: - Medication Management

struct MedicationsView: View {
    @EnvironmentObject private var store: MedicationStore
    @State private var showingAdd = false
    @State private var editingMedication: Medication?

    var body: some View {
        ZStack {
            METheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    if store.medications.isEmpty {
                        MEPanel {
                            VStack(spacing: 12) {
                                Image(systemName: "pills.fill")
                                    .font(.system(size: 48))
                                    .foregroundStyle(METheme.gradient)
                                Text("لم تتم إضافة أدوية بعد")
                                    .font(.title3.bold())
                                Text("اضغط + لإضافة أول علاج ومواعيده.")
                                    .foregroundStyle(METheme.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        ForEach(store.medications) { medication in
                            medicationCard(medication)
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("علاجاتي")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(METheme.cyan)
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            MedicationEditorView(mode: .add)
        }
        .sheet(item: $editingMedication) { medication in
            MedicationEditorView(mode: .edit(medication))
        }
    }

    private func medicationCard(_ medication: Medication) -> some View {
        MEPanel {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(medication.displayName)
                            .font(.title3.bold())
                        Text(medication.foodRelation.rawValue)
                            .foregroundStyle(METheme.secondary)
                        Text(medication.times.map(\.displayText).joined(separator: " • "))
                            .font(.subheadline)
                            .foregroundStyle(METheme.cyan)
                    }
                    Spacer()
                    Image(systemName: medication.notificationsEnabled ? "bell.badge.fill" : "bell.slash.fill")
                        .font(.title2)
                        .foregroundStyle(medication.notificationsEnabled ? METheme.green : METheme.secondary)
                }

                HStack(spacing: 10) {
                    Button(role: .destructive) {
                        store.deleteMedication(id: medication.id)
                    } label: {
                        Label("حذف", systemImage: "trash.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 14).fill(METheme.red.opacity(0.14)))
                    }

                    Button {
                        editingMedication = medication
                    } label: {
                        Label("تعديل", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 14).fill(METheme.blue.opacity(0.18)))
                    }
                }
            }
        }
    }
}

enum MedicationEditorMode {
    case add
    case edit(Medication)
}

struct MedicationEditorView: View {
    @EnvironmentObject private var store: MedicationStore
    @Environment(\.dismiss) private var dismiss

    let mode: MedicationEditorMode

    @State private var id = UUID()
    @State private var name = ""
    @State private var dose = ""
    @State private var spokenName = ""
    @State private var foodRelation: FoodRelation = .none
    @State private var notes = ""
    @State private var times: [DoseTime] = [DoseTime(hour: 8, minute: 0)]
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    @State private var hasEndDate = false
    @State private var endDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var notificationsEnabled = true
    @State private var voiceReminderEnabled = true
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("بيانات العلاج") {
                    TextField("اسم العلاج — مثال: Concor", text: $name)
                    TextField("الجرعة — مثال: 5 mg", text: $dose)
                    TextField("الاسم العربي للنطق — مثال: كونكور خمسة مليجرام", text: $spokenName)
                    Picker("علاقة العلاج بالأكل", selection: $foodRelation) {
                        ForEach(FoodRelation.allCases) { relation in
                            Text(relation.rawValue).tag(relation)
                        }
                    }
                    TextField("ملاحظات", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("المواعيد") {
                    ForEach(Array(times.enumerated()), id: \.element.id) { index, time in
                        HStack {
                            DatePicker(
                                "الموعد \(index + 1)",
                                selection: Binding(
                                    get: { time.dateForPicker },
                                    set: { newDate in times[index] = .from(date: newDate) }
                                ),
                                displayedComponents: .hourAndMinute
                            )
                            if times.count > 1 {
                                Button(role: .destructive) {
                                    times.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                            }
                        }
                    }

                    Button {
                        if times.count < 6 {
                            times.append(DoseTime(hour: 12, minute: 0))
                        }
                    } label: {
                        Label("إضافة موعد آخر", systemImage: "plus.circle.fill")
                    }
                    .disabled(times.count >= 6)
                }

                Section("مدة العلاج") {
                    DatePicker("تاريخ البداية", selection: $startDate, displayedComponents: .date)
                    Toggle("تحديد تاريخ نهاية", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("تاريخ النهاية", selection: $endDate, in: startDate..., displayedComponents: .date)
                    }
                }

                Section("التنبيهات") {
                    Toggle("تشغيل التنبيهات", isOn: $notificationsEnabled)
                    Toggle("تذكير صوتي عربي", isOn: $voiceReminderEnabled)
                        .disabled(!notificationsEnabled)
                    Text("التذكير الصوتي يستخدم الاسم العربي الذي كتبته حتى ينطق اسم الدواء بصورة أوضح.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(METheme.background)
            .navigationTitle(isEditing ? "تعديل العلاج" : "إضافة علاج")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") { saveMedication() }
                        .fontWeight(.bold)
                }
            }
            .onAppear(perform: loadEditingData)
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private func loadEditingData() {
        guard case let .edit(medication) = mode else { return }
        id = medication.id
        name = medication.name
        dose = medication.dose
        spokenName = medication.spokenName
        foodRelation = medication.foodRelation
        notes = medication.notes
        times = medication.times.isEmpty ? [DoseTime(hour: 8, minute: 0)] : medication.times
        startDate = medication.startDate
        if let existingEnd = medication.endDate {
            hasEndDate = true
            endDate = existingEnd
        }
        notificationsEnabled = medication.notificationsEnabled
        voiceReminderEnabled = medication.voiceReminderEnabled
    }

    private func saveMedication() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "اكتب اسم العلاج أولًا."
            return
        }
        guard !times.isEmpty else {
            validationMessage = "أضف موعدًا واحدًا على الأقل."
            return
        }

        let medication = Medication(
            id: id,
            name: trimmedName,
            dose: dose.trimmingCharacters(in: .whitespacesAndNewlines),
            spokenName: spokenName.trimmingCharacters(in: .whitespacesAndNewlines),
            foodRelation: foodRelation,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            times: times.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) },
            startDate: Calendar.current.startOfDay(for: startDate),
            endDate: hasEndDate ? Calendar.current.startOfDay(for: endDate) : nil,
            notificationsEnabled: notificationsEnabled,
            voiceReminderEnabled: notificationsEnabled && voiceReminderEnabled
        )

        if isEditing {
            store.updateMedication(medication)
        } else {
            store.addMedication(medication)
        }
        dismiss()
    }
}

// MARK: - Daily Log

struct DailyLogView: View {
    @EnvironmentObject private var store: MedicationStore

    var body: some View {
        ZStack {
            METheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    summaryCard
                    ForEach(store.todayOccurrences) { occurrence in
                        logCard(occurrence)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("سجل اليوم")
    }

    private var summaryCard: some View {
        let total = store.todayOccurrences.count
        let taken = store.todayOccurrences.filter { store.status(for: $0) == .taken }.count
        let missed = store.todayOccurrences.filter { store.status(for: $0) == .missed }.count

        return MEPanel {
            HStack(spacing: 10) {
                statBox(title: "الفائت", value: missed, color: METheme.red)
                statBox(title: "تم", value: taken, color: METheme.green)
                statBox(title: "اليوم", value: total, color: METheme.blue)
            }
        }
    }

    private func statBox(title: String, value: Int, color: Color) -> some View {
        VStack(spacing: 5) {
            Text("\(value)").font(.title.bold()).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(METheme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(METheme.panel2))
    }

    private func logCard(_ occurrence: DoseOccurrence) -> some View {
        let state = store.status(for: occurrence)
        return MEPanel {
            HStack(spacing: 12) {
                VStack {
                    Image(systemName: icon(for: state))
                        .font(.title2)
                        .foregroundStyle(state.color)
                    Text(state.title)
                        .font(.caption.bold())
                        .foregroundStyle(state.color)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(occurrence.medication.displayName).font(.headline)
                    Text(occurrence.doseTime.displayText).foregroundStyle(METheme.secondary)
                    Text(occurrence.medication.foodRelation.rawValue)
                        .font(.caption)
                        .foregroundStyle(METheme.secondary)
                }
            }
        }
    }

    private func icon(for state: DoseVisualState) -> String {
        switch state {
        case .taken: return "checkmark.circle.fill"
        case .snoozed: return "alarm.fill"
        case .missed: return "xmark.circle.fill"
        case .due: return "clock.badge.exclamationmark.fill"
        case .upcoming: return "clock.fill"
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var store: MedicationStore
    @State private var name = ""
    @State private var saved = false

    var body: some View {
        ZStack {
            METheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    MEPanel {
                        VStack(alignment: .trailing, spacing: 12) {
                            Text("اسم صاحب العلاج")
                                .font(.headline)
                            TextField("الاسم", text: $name)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                store.updateProfileName(name)
                                saved = true
                            } label: {
                                Label(saved ? "تم الحفظ" : "حفظ الاسم", systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(RoundedRectangle(cornerRadius: 16).fill(METheme.gradient))
                                    .foregroundStyle(.white)
                            }
                        }
                    }

                    MEPanel {
                        VStack(alignment: .trailing, spacing: 10) {
                            Text("عن MECare").font(.headline)
                            Label("تذكير محلي بدون حساب سحابي", systemImage: "lock.shield.fill")
                            Label("واجهة عربية مبسطة", systemImage: "character.book.closed.fill")
                            Label("تنبيهات وتأكيد وتأجيل الجرعة", systemImage: "bell.and.waves.left.and.right.fill")
                            Label("تذكير صوتي عربي", systemImage: "speaker.wave.3.fill")
                            Text("MECare يساعد على تنظيم مواعيد العلاج ولا يحدد أو يغيّر الجرعات الطبية.")
                                .font(.caption)
                                .foregroundStyle(METheme.secondary)
                        }
                    }

                    MEPanel {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Engineer Mahmoud Ebid").font(.headline)
                                Text("MECare v0.5.0 Integrated")
                                    .font(.caption)
                                    .foregroundStyle(METheme.secondary)
                            }
                            Spacer()
                            MEOrb(size: 50)
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("الإعدادات")
        .onAppear { name = store.profileName }
        .onChange(of: name) { _ in saved = false }
    }
}

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
                    await NotificationManager.shared.scheduleDailyDemo(userName: store.profileName)
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
}

@MainActor
final class MedicationStore: ObservableObject {
    @Published var profileName = "سارة"
    @Published var taken = false
    @Published var snoozed = false

    let medicineName = "Concor 5 mg"
    let spokenMedicineName = "كونكور خمسة مليجرام"
    let scheduledTime = "1:00 ظهرًا"
    let note = "بعد الغداء"

    func markTaken() {
        taken = true
        snoozed = false
    }

    func snooze() {
        snoozed = true
        Task {
            await NotificationManager.shared.scheduleSnooze(
                userName: profileName,
                medicineName: medicineName,
                minutes: 10
            )
        }
    }
}

final class NotificationManager {
    static let shared = NotificationManager()

    static let categoryID = "MECare.MedicationReminder"
    static let takenAction = "MECare.Taken"
    static let snoozeAction = "MECare.Snooze10"

    private let center = UNUserNotificationCenter.current()

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

    func scheduleDailyDemo(userName: String) async {
        let id = "MECare.Daily.Demo"
        center.removePendingNotificationRequests(withIdentifiers: [id])

        let content = UNMutableNotificationContent()
        content.title = "موعد العلاج"
        content.subtitle = "Concor 5 mg"
        content.body = "يا \(userName)، حان موعد العلاج. بعد الغداء."
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.interruptionLevel = .timeSensitive

        var components = DateComponents()
        components.hour = 13
        components.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        do {
            try await center.add(request)
        } catch {
            print("MECare daily notification error: \(error)")
        }
    }

    func scheduleSnooze(userName: String, medicineName: String, minutes: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "تذكير بالعلاج"
        content.subtitle = medicineName
        content.body = "يا \(userName)، ما زال موعد العلاج بانتظار التأكيد."
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.interruptionLevel = .timeSensitive

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
}

struct RootView: View {
    @State private var showSplash = true

    var body: some View {
        ZStack {
            METheme.background.ignoresSafeArea()
            if showSplash {
                SplashView().transition(.opacity)
            } else {
                HomeView().transition(.opacity)
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

enum METheme {
    static let background = Color(red: 0.01, green: 0.02, blue: 0.04)
    static let panel = Color(red: 0.035, green: 0.055, blue: 0.095)
    static let blue = Color(red: 0.05, green: 0.49, blue: 1.0)
    static let cyan = Color(red: 0.0, green: 0.82, blue: 1.0)
    static let violet = Color(red: 0.48, green: 0.27, blue: 1.0)
    static let red = Color(red: 0.96, green: 0.18, blue: 0.24)
    static let green = Color(red: 0.12, green: 0.82, blue: 0.45)
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
            Circle()
                .fill(METheme.panel)
            Circle()
                .stroke(METheme.gradient, lineWidth: max(2, size * 0.02))
                .shadow(color: METheme.blue.opacity(0.8), radius: size * 0.08)
            Text("ME")
                .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
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
                .padding(.bottom, 38)
        }
        .padding(.horizontal, 24)
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: MedicationStore
    private let speaker = AVSpeechSynthesizer()

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                medicineCard
                voiceCard
                todayCard
                footer
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }
        .background(METheme.background.ignoresSafeArea())
        .environment(\.layoutDirection, .rightToLeft)
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "bell")
                    .foregroundStyle(METheme.violet)
                Spacer()
                HStack(spacing: 10) {
                    Text("MECare").font(.title2.bold())
                    MEOrb(size: 42)
                }
                Spacer()
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(METheme.violet)
            }
            Text("صباح الخير يا \(store.profileName)")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Text("نحن هنا لنهتم بصحتك كل يوم")
                .foregroundStyle(METheme.secondary)
        }
    }

    private var medicineCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 18) {
                VStack(alignment: .trailing, spacing: 7) {
                    Text(store.taken ? "تم أخذ العلاج" : "العلاج القادم")
                        .font(.headline)
                        .foregroundStyle(store.taken ? METheme.green : METheme.blue)
                    Text(store.medicineName)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Label(store.scheduledTime, systemImage: "clock")
                    Label(store.note, systemImage: "fork.knife")
                        .foregroundStyle(METheme.secondary)
                }
                Spacer()
                Image(systemName: "capsule.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(METheme.gradient)
                    .rotationEffect(.degrees(-35))
                    .frame(width: 110, height: 110)
                    .background(Circle().stroke(METheme.gradient, lineWidth: 2))
            }

            Button {
                store.markTaken()
            } label: {
                Label("تم أخذ العلاج", systemImage: "checkmark")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 20).fill(METheme.gradient))
                    .foregroundStyle(.white)
            }

            Button {
                store.snooze()
            } label: {
                Label("ذكّريني بعد 10 دقائق", systemImage: "alarm")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(METheme.blue, lineWidth: 1))
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24).fill(METheme.panel))
    }

    private var voiceCard: some View {
        Button {
            speakReminder()
        } label: {
            HStack(spacing: 15) {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(METheme.gradient)
                VStack(alignment: .trailing, spacing: 5) {
                    Text("التنبيه الصوتي")
                        .font(.headline)
                        .foregroundStyle(METheme.violet)
                    Text("يا \(store.profileName)، الآن الساعة الواحدة. حان موعد علاج \(store.medicineName)")
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: "waveform")
                    .font(.title)
                    .foregroundStyle(METheme.gradient)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 22).fill(METheme.panel))
        }
        .buttonStyle(.plain)
    }

    private var todayCard: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Text("علاجات اليوم")
                .font(.title3.bold())
            doseRow(time: "8:00 صباحًا", state: "تم", color: METheme.green)
            doseRow(time: "1:00 ظهرًا", state: store.taken ? "تم" : "الآن", color: store.taken ? METheme.green : METheme.blue)
            doseRow(time: "8:00 مساءً", state: "قادم", color: METheme.violet)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22).fill(METheme.panel))
    }

    private func doseRow(time: String, state: String, color: Color) -> some View {
        HStack {
            Text(state)
                .font(.caption.bold())
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(color.opacity(0.75)))
            Spacer()
            Text(store.medicineName).font(.headline)
            Text(time).foregroundStyle(METheme.secondary)
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Engineer Mahmoud Ebid").font(.headline)
                Text("MECare • Foundation Build")
                    .font(.caption)
                    .foregroundStyle(METheme.secondary)
            }
            Spacer()
            MEOrb(size: 46)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22).fill(METheme.panel))
    }

    private func speakReminder() {
        let text = "يا \(store.profileName)، الآن الساعة الواحدة. حان موعد علاج \(store.spokenMedicineName). \(store.note). من فضلك خذي العلاج الآن."
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ar-SA") ?? AVSpeechSynthesisVoice(language: "ar")
        utterance.rate = 0.42
        utterance.volume = 1.0
        speaker.speak(utterance)
    }
}

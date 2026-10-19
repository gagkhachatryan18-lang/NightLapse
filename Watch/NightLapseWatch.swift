import SwiftUI
import WatchConnectivity
import WatchKit

// NightLapse на часах - пульт, как «Пульт Камеры»: кадр с iPhone, старт и стоп, тест

@main
struct NightLapseWatchApp: App {
    @StateObject private var link = PhoneLink()

    var body: some Scene {
        WindowGroup {
            RemoteView(link: link)
        }
    }
}

final class PhoneLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published var reachable = false
    @Published var phase = "idle"
    @Published var status = ""
    @Published var frames = 0
    @Published var elapsed: Double = 0
    @Published var battery = -1
    @Published var sub: Double = 0
    @Published var image: UIImage?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func send(_ cmd: String) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["cmd": cmd], replyHandler: nil, errorHandler: nil)
    }

    private func upd(_ s: WCSession) {
        let r = s.isReachable
        DispatchQueue.main.async { self.reachable = r }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) { upd(session) }
    func sessionReachabilityDidChange(_ session: WCSession) { upd(session) }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            self.reachable = true
            self.phase = message["phase"] as? String ?? self.phase
            self.status = message["status"] as? String ?? ""
            self.frames = message["frames"] as? Int ?? 0
            self.elapsed = message["elapsed"] as? Double ?? 0
            self.battery = message["battery"] as? Int ?? -1
            self.sub = message["sub"] as? Double ?? 0
        }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        let img = UIImage(data: messageData)
        DispatchQueue.main.async { if let img { self.image = img } }
    }
}

struct RemoteView: View {
    @ObservedObject var link: PhoneLink
    private let accent = Color(red: 0.93, green: 0.79, blue: 0.42)

    private var shooting: Bool { link.phase == "rec" || link.phase == "paused" }
    private var busy: Bool { link.phase == "test" || link.phase == "waiting" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let img = link.image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            }
            if !link.reachable {
                VStack(spacing: 6) {
                    Image(systemName: "iphone")
                        .font(.title2)
                    Text("Открой NightLapse на iPhone")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding()
            } else {
                VStack {
                    if shooting {
                        HStack {
                            Text(time(link.elapsed)).monospacedDigit()
                            Spacer()
                            Text("\(link.frames) к.").monospacedDigit()
                        }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                    } else if !link.status.isEmpty && link.phase != "idle" {
                        Text(link.status)
                            .font(.caption2)
                            .lineLimit(2)
                            .padding(6)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Spacer()
                    HStack(alignment: .bottom) {
                        Button { link.send("test") } label: {
                            Image(systemName: "camera.aperture")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 40, height: 40)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .opacity(link.phase == "idle" ? 1 : 0)
                        .disabled(link.phase != "idle")
                        Spacer()
                        shutter
                        Spacer()
                        Color.clear.frame(width: 40, height: 40)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    /// Кнопка как на iPhone: круг - старт, квадрат - стоп, во время теста - отмена
    private var shutter: some View {
        Button {
            WKInterfaceDevice.current().play(.click)
            link.send("shutter")
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 3).frame(width: 54, height: 54)
                if shooting {
                    RoundedRectangle(cornerRadius: 5).fill(.red).frame(width: 22, height: 22)
                } else if busy {
                    Circle().trim(from: 0, to: max(0.05, link.sub))
                        .stroke(accent, lineWidth: 4)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 44, height: 44)
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                } else if link.phase == "saving" {
                    ProgressView()
                } else {
                    Circle().fill(.red).frame(width: 44, height: 44)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func time(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

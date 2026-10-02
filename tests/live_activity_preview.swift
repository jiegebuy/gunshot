import Foundation
import SwiftUI
import UIKit
import GoToHPActivity

@MainActor private var measured: [Int: CGFloat] = [:]

func previewState(count: Int) -> GSUploadVisualState {
    let names = ["IMG_0241.HEIC", "夜景_4K_HDR.MOV", "Live_0243.HEIC", "IMG_0244.JPG", "海边慢动作.MOV", "IMG_0246.HEIC", "IMG_0247.PNG", "旅行长视频.MOV", "IMG_0249.HEIC", "IMG_0250.MOV", "IMG_0251.HEIC", "IMG_0252.MOV"]
    let files = (0..<count).compactMap { index in
        GSUploadFileState(["id": "\(index)", "name": names[index], "uploaded": (index + 1) * 8_000_000,
                           "total": 100_000_000, "speed": (index + 1) * 250_000,
                           "state": index == 5 ? "waiting_source" : "uploading", "measurement": "acknowledged", "livePhoto": index == 2])
    }
    return GSUploadVisualState(files: files, speed: 9_500_000, history: [0, 1_000_000, 6_000_000, 4_000_000, 8_000_000, 5_000_000, 9_500_000], waiting: 39)
}

struct PreviewCanvas: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red:0.10,green:0.17,blue:0.28), .indigo, Color(red:0.05,green:0.44,blue:0.47)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            Circle().fill(.cyan.opacity(0.3)).frame(width:230,height:230).blur(radius:40).offset(x:100,y:-200)
            VStack(alignment: .leading, spacing: 22) {
                Text("GoToHP · Live Activity preview").font(.title3.bold()).foregroundStyle(.white)
                Text("Sample data · 8 concurrent files").font(.caption).foregroundStyle(.white.opacity(0.7))
                GSUploadCard(state: previewState(count: 8), language: "zh-hans")
                    .background(GeometryReader { proxy in Color.clear.onAppear { measured[8] = proxy.size.height } })
                Text("Sample data · 12 files including waiting sources").font(.caption).foregroundStyle(.white.opacity(0.7))
                GSUploadCard(state: previewState(count: 12), language: "zh-hans")
                    .background(GeometryReader { proxy in Color.clear.onAppear { measured[12] = proxy.size.height } })
                GSUploadCard(state: previewState(count: 8), language: "zh-hans", stale: true)
                Spacer(minLength: 0)
            }.padding(20).preferredColorScheme(.dark)
        }
    }
}

@objc(GSActivityPreviewDelegate)
final class GSActivityPreviewDelegate: NSObject, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: PreviewCanvas())
        window.makeKeyAndVisible(); self.window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try! image.pngData()!.write(to: documents.appendingPathComponent("live-activity-preview.png"))
            let fits = measured.count == 2 && measured.values.allSatisfy { $0 <= 160 && $0 > 100 }
            let result = "\(fits ? "PASS" : "FAIL") all file tiles fit the 160-point Live Activity limit: \(measured)"
            try! result.write(to: documents.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            print(result); exit(fits ? 0 : 1)
        }
        return true
    }
}

@main
enum PreviewMain {
    @MainActor static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(GSActivityPreviewDelegate.self))
    }
}

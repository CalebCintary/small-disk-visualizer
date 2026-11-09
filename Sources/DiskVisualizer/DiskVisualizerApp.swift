import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ScanStorage.removeStale()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScanStorage.removeCurrent()
    }
}

@main
struct DiskVisualizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Disk Visualizer", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 860, minHeight: 560)
        }
    }
}

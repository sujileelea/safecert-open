import SwiftUI
import SafeCertKit

@main
struct SafeCertApp: App {
    var body: some Scene {
        WindowGroup {
            Text("SafeCert \(SafeCertKit.version)")
        }
    }
}

import SwiftUI
import PDFLabCore

@main
struct PDFLabApp: App {
    var body: some Scene {
        WindowGroup { Text("PDFlab \(PDFLabCoreInfo.version)") }
    }
}

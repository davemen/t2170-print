import SwiftUI

@main
struct T2170PrintApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var session = PrintSession()

    var body: some View {
        PrintPanel(session: session)
    }
}

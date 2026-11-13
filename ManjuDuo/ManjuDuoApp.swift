import SwiftUI

@main struct ManjuDuoApp:App {
    @StateObject private var library=LibraryStore()
    private let provider=ContentProvider()
    var body:some Scene { WindowGroup { HomeView(provider:provider).environmentObject(library) } }
}

import AppKit
import SwiftUI

@MainActor
struct RexExtensionPageUnavailableView: View {
    @EnvironmentObject private var store: BrowserStore

    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "puzzlepiece.extension")
        } description: {
            Text(detail)
        } actions: {
            Button {
                store.isExtensionsPresented = true
            } label: {
                Label("管理扩展程序", systemImage: "puzzlepiece.extension")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

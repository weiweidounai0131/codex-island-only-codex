import SwiftUI

/// Current page content for the expanded panel. The original app mounted all
/// three pages side-by-side and slid the row; the Codex-only narrow panel has
/// no spare horizontal room, so it mounts only the active page.
struct PagedContent: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var screenPref = ScreenPref.shared

    var body: some View {
        GeometryReader { geo in
            let pageWidth = geo.size.width
            Group {
                switch screenPref.screen {
                case .usage:
                    UsageView()
                case .cost:
                    CostView()
                case .overview:
                    OverviewView(model: model)
                }
            }
            .frame(width: pageWidth, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentTransition(.opacity)
            .animation(.pageSwipe, value: screenPref.screen)
            .simultaneousGesture(pageDragGesture)
            .onAppear {
                if !screenPref.hasSwipedScreen {
                    screenPref.hasSwipedScreen = true
                }
            }
        }
    }

    private var pageDragGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) >= 44, abs(dx) > abs(dy) * 1.4 else { return }
                if dx < 0 {
                    model.advanceScreen()
                } else {
                    model.rewindScreen()
                }
            }
    }
}

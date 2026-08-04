//
//  TabSelectionView.swift
//  Knotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Tray", icon: "tray.fill", view: .tray)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = KnotchViewCoordinator.shared
    @ObservedObject var timerManager = TimerManager.shared
    @Default(.showHomeView) var showHomeView
    @Default(.showTrayView) var showTrayView
    @Namespace var animation

    private func isEnabled(_ view: NotchViews) -> Bool {
        view == .home ? showHomeView : showTrayView
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                    let disabled = timerManager.isCreatingTimer || !isEnabled(tab.view)
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .disabled(disabled)
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .opacity(disabled ? 0.4 : 1)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    KnotchHeader().environmentObject(KnotchViewModel())
}

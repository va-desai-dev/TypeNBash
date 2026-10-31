import AppKit
import Defaults
import SwiftUI

/// The app's appearance. `AppTheme` applies it to every window.
enum DisplayMode: Int, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Nil follows the system setting.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct VisualAppearancePicker: View {
    @AppStorage(.displayMode) private var displayMode: DisplayMode

    var body: some View {
        HStack(spacing: 20) {
            Spacer()
            ForEach(DisplayMode.allCases) { mode in
                AppearanceButton(mode: mode, isSelected: displayMode == mode) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        displayMode = mode
                    }
                }
            }
            Spacer()
        }
    }
}

struct AppearanceButton: View {
    let mode: DisplayMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                MockupView(mode: mode)
                    .frame(width: 100, height: 60)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                    )
                Text(mode.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.foreground)
            }
        }
        .buttonStyle(.plain)
    }
}


struct MockupView: View {
    let mode: DisplayMode

    var body: some View {
        GeometryReader { geo in
            ZStack {
                switch mode {
                case .light:
                    LightMockup()
                case .dark:
                    DarkMockup()
                case .system:
                    HStack(spacing: 0) {
                        LightMockup()
                            .frame(width: geo.size.width / 2)
                            .clipped()
                        DarkMockup()
                            .frame(width: geo.size.width / 2)
                            .clipped()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

// Component for Light representation
struct LightMockup: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.7))
                .frame(width: 45, height: 18)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white)
                .frame(width: 60, height: 25)
                .overlay(
                    HStack(spacing: 3) {
                        Circle().fill(Color.red).frame(width: 4, height: 4)
                        Circle().fill(Color.yellow).frame(width: 4, height: 4)
                        Circle().fill(Color.green).frame(width: 4, height: 4)
                        Spacer()
                    }
                        .padding(.leading, 6),
                    alignment: .top
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(red: 0.35, green: 0.6, blue: 0.9),
            in: RoundedRectangle(
                cornerRadius: 10,
                style: .continuous
            )
        )
    }
}

// Component for Dark representation
struct DarkMockup: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 0.1, green: 0.15, blue: 0.4))
                .frame(width: 45, height: 18)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 0.1, green: 0.1, blue: 0.15))
                .frame(width: 60, height: 25)
                .overlay(
                    HStack(spacing: 3) {
                        Circle().fill(Color.red).frame(width: 4, height: 4)
                        Circle().fill(Color.yellow).frame(width: 4, height: 4)
                        Circle().fill(Color.green).frame(width: 4, height: 4)
                        Spacer()
                    }
                        .padding(.leading, 6),
                    alignment: .top
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(red: 0.05, green: 0.1, blue: 0.25),
            in: RoundedRectangle(
                cornerRadius: 10,
                style: .continuous
            )
        )
    }
}

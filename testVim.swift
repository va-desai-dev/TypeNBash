import Foundation
import SwiftUI
import SwiftData

struct TypeNBash: View {
	let theme = AppTheme()

	var body: some View {
		VStack {
			ForEach(AppThemes.allCases) { theme in 
				Text(theme.displayName)
					.font(.body.weight(bold))
					.foregroundStyle(Color.accentColor)
					.fixedSize(horizontal: true, vertical: false)
				Spacer()
				Image(systemName: "chevron.right")
					.font(.body.weight(bold))
					.foregroundStyle(Color.secondary)			
			}
		}
		.scrollContentBackground(.hidden)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
	private func AppThemes(for theme: [ColorPalette]) -> {
		fetch {
			UserSelections.AppTheme()
			try await refresh()
			return
		}
	}
}

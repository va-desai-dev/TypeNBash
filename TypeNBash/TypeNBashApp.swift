//
//  TypeNBashApp.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 9/12/26.
//

import SwiftUI

@main
struct TypeNBashApp: App {
    var body: some Scene {
        WindowGroup {
            // Window chrome lives on CanvasView, alongside the `.toolbar` content
            // it tints — and below this point, so it can read anything injected
            // into the environment inside the window rather than the defaults an
            // App struct would see.
            ContentView()
                .preferredColorScheme(.dark)
                .foregroundStyle(Color.foreground)
        }
    }
}

extension Color {
    static let card = Color(red: 11/255, green: 10/255, blue: 10/255)
    static let accentColor = Color(red: 184/255, green: 151/255, blue: 94/255)
    static let foreground = Color(red: 240/255, green: 234/255, blue: 214/255)
}

//
//  Logger+App.swift
//
//  TypeNBash
//
//  Provides `Logger.app`, which CotEditor defines in its AppDelegate (not ported).
//

import OSLog

extension Logger {

    static let app = Logger(subsystem: "com.TypeNBash.TypeNBash", category: "app")
}

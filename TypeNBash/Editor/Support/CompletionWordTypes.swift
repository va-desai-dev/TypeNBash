//
//  CompletionWordTypes.swift
//
//  Adapted from CotEditor (https://coteditor.com), Apache License 2.0.
//  Extracted from Models/ModeOptions.swift so the editor does not need to
//  vendor the full Mode machinery. Modified for TypeNBash.
//
//  © 2023-2026 1024jp
//

import Foundation

struct CompletionWordTypes: OptionSet, Codable {

    var rawValue: Int

    static let standard = Self(rawValue: 1 << 0)
    static let document = Self(rawValue: 1 << 1)
    static let syntax = Self(rawValue: 1 << 2)
}

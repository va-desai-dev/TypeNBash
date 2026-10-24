//
//  TextSizeChanging.swift
//
//  Adapted from CotEditor (https://coteditor.com), Apache License 2.0.
//  Extracted from AppDelegate.swift for use outside the CotEditor app target.
//  Modified for TypeNBash.
//
//  © 2014-2026 1024jp
//

import Foundation

@MainActor @objc protocol TextSizeChanging: AnyObject {

    func biggerFont(_ sender: Any?)
    func smallerFont(_ sender: Any?)
    func resetFont(_ sender: Any?)
}

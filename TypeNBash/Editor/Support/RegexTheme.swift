//
//  RegexTheme.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by 1024jp on 2024-07-09.
//
//  ---------------------------------------------------------------------------
//
//  © 2024 1024jp
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import AppKit.NSColor
import RegexHighlighting

extension RegexTheme<NSColor> {
    
    // Literal colors in place of CotEditor's asset-catalog `.Regex.*` namespace,
    // so the find field's regex highlighting works without vendoring the asset catalog.
    static let `default` = RegexTheme(
        character: NSColor.systemTeal,
        backReference: NSColor.systemBrown,
        symbol: NSColor.systemPurple,
        quantifier: NSColor.systemRed,
        anchor: NSColor.systemOrange,
        invisible: .tertiaryLabelColor
    )
}

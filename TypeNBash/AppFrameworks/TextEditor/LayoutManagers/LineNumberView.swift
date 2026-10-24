//
//  LineNumberView.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by nakamuxu on 2005-03-30.
//
//  ---------------------------------------------------------------------------
//
//  © 2004-2007 nakamuxu
//  © 2014-2026 1024jp
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

import AppKit
import Combine
import CoreText.CTFont
import LineEnding
import StringUtils

final class LineNumberView: NSRulerView {
    var lineChanges = EditorLineChanges() {
        didSet { if lineChanges != oldValue { needsDisplay = true } }
    }
    var showsChanges = false {
        didSet { if showsChanges != oldValue { updateRuleThickness(); needsDisplay = true } }
    }
    var showsNumbers = true {
        didSet { if showsNumbers != oldValue { updateRuleThickness(); needsDisplay = true } }
    }
    
    private struct DrawingInfo: Equatable {
        
        var fontSize: CGFloat
        var charWidth: CGFloat
        var digitGlyphs: [CGGlyph]
        var tickLength: CGFloat
        
        
        init(font: CGFont, fontSize: CGFloat, scale: CGFloat) {
            
            self.fontSize = scale * fontSize
            
            let ctFont = CTFontCreateWithGraphicsFont(font, self.fontSize, nil, nil)
            self.digitGlyphs = (0...9).map { ctFont.glyph(for: Character(String($0))) }
            self.charWidth = ctFont.advance(for: self.digitGlyphs[8]).width  // use '8' to get width
            
            self.tickLength = self.fontSize / 3
        }
    }
    
    
    private enum ColorStrength: Double {
        
        case normal = 0.6
        case bold = 1.0
        case stroke = 0.4
        
        static let highContrastCoefficient = 0.4
    }
    
    
    // MARK: Private Properties
    
    private let lineNumberFont: CGFont = NSFont.lineNumberFont().cgFont
    private let boldLineNumberFont: CGFont = NSFont.lineNumberFont(weight: .medium).cgFont
    private lazy var highContrastBoldLineNumberFont: CGFont = NSFont.lineNumberFont(weight: .semibold).cgFont
    
    private let minimumNumberOfDigits = 3
    
    private var drawingInfo: DrawingInfo?
    private var needsUpdateDrawingInfo = false
    @Invalidating(.display) private var textColor: NSColor = .textColor
    
    private var textViewObservers: Set<AnyCancellable> = []
    
    private var draggingInfo: DraggingInfo?
    
    
    // MARK: Lifecycle
    
    init(textView: NSTextView, scrollView: NSScrollView, orientation: NSRulerView.Orientation) {
        
        super.init(scrollView: scrollView, orientation: orientation)
        
        self.reservedThicknessForMarkers = 0
        
        self.clientView = textView
        self.updateDrawingInfo()
        self.observeTextView(textView)
    }
    
    
    required init(coder: NSCoder) {
        
        fatalError("init(coder:) has not been implemented")
    }
    
    
    // MARK: View Methods
    
    override func accessibilityLabel() -> String? {
        
        String(localized: "Line Numbers", table: "Document", comment: "accessibility label")
    }
    
    
    override var isFlipped: Bool {
        
        false
    }
    
    
    override func viewWillDraw() {
        
        super.viewWillDraw()
        
        if self.needsUpdateDrawingInfo {
            self.updateDrawingInfo()
            self.needsUpdateDrawingInfo = false
        }
    }
    
    
    override func draw(_ dirtyRect: NSRect) {
        
        self.drawHashMarksAndLabels(in: dirtyRect)
    }
    
    
    override func drawHashMarksAndLabels(in rect: NSRect) {
        
        NSGraphicsContext.saveGraphicsState()
        
        // workaround opaque background (2026-08, macOS 27 SDK)
        if let textView, textView.isOpaque {
            textView.backgroundColor.setFill()
            rect.intersection(self.frame).fill()
        }
        
        if showsNumbers {
            NSGraphicsContext.saveGraphicsState()
            self.drawNumbers(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }
        if showsChanges { self.drawChanges() }
        
        NSGraphicsContext.restoreGraphicsState()
    }
    
    
    // MARK: Private Methods

    /// Use the text layout's actual fragments so markers follow wrapping and zoom.
    private func drawChanges() {
        guard let textView, textView.layoutOrientation == .horizontal,
              let layout = textView.layoutManager as? LayoutManager,
              let range = textView.range(for: textView.visibleRect) else { return }
        let scale = textView.scale
        let origin = convert(.zero, from: textView).y - scale * textView.textContainerOrigin.y
        let barWidth: CGFloat = 4
        let x = bounds.minX + 4
        let length = (textView.string as NSString).length
        let lastLine = textView.lineNumber(at: length)

        func color(_ kind: EditorLineChanges.Kind) -> NSColor {
            kind == .added ? .systemGreen : .systemBlue
        }

        // Contiguous fragments of the same kind merge into one capsule, like Xcode's gutter.
        var run: (kind: EditorLineChanges.Kind, top: CGFloat, bottom: CGFloat)?
        var deletionMarks: [CGFloat] = []
        func flushRun() {
            guard let current = run else { return }
            let rect = NSRect(x: x, y: current.bottom, width: barWidth, height: current.top - current.bottom)
                .insetBy(dx: 0, dy: 1)
            color(current.kind).setFill()
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            run = nil
        }

        func draw(_ rect: NSRect, line: Int, firstFragment: Bool, lastFragment: Bool) {
            let top = origin - scale * rect.minY
            let bottom = origin - scale * rect.maxY
            if let kind = lineChanges.lines[line] {
                if let current = run, current.kind == kind, abs(current.bottom - top) < 0.5 {
                    run?.bottom = bottom
                } else {
                    flushRun()
                    run = (kind, top, bottom)
                }
            } else {
                flushRun()
            }
            if firstFragment && lineChanges.deletions.contains(line) { deletionMarks.append(top) }
            if lastFragment && line == lastLine && lineChanges.deletions.contains(line + 1) { deletionMarks.append(bottom) }
        }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphRange, _ in
            let characters = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let line = layout.lineEndingScanner.lineNumber(at: characters.location)
            let logical = layout.lineEndingScanner.lineRange(at: characters.location)
            draw(rect, line: line, firstFragment: characters.location == logical.location,
                 lastFragment: NSMaxRange(characters) >= NSMaxRange(logical))
        }
        if NSMaxRange(range) == length, !layout.extraLineFragmentRect.isEmpty {
            draw(layout.extraLineFragmentRect, line: lastLine, firstFragment: true, lastFragment: true)
        }
        flushRun()

        // Deletions: a short horizontal pill sitting on the boundary between lines.
        NSColor.systemRed.setFill()
        for y in deletionMarks {
            let rect = NSRect(x: x - 2, y: y - 1.5, width: barWidth + 4, height: 3)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    /// Horizontal space reserved to the left of the numbers for the change capsule.
    private var changeGutterWidth: CGFloat {

        self.showsChanges ? 12 : 0
    }
    
    /// The client text view.
    private var textView: NSTextView? {
        
        self.clientView as? NSTextView
    }
    
    
    /// The total number of lines in the text view.
    private var numberOfLines: Int {
        
        guard let textView else { return 0 }
        
        return textView.lineNumber(at: textView.string.length)
    }
    
    
    /// Returns line number font for selected lines by considering the current accessibility setting.
    private var effectiveBoldLineNumberFont: CGFont {
        
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? self.highContrastBoldLineNumberFont
            : self.boldLineNumberFont
    }
    
    
    /// Draws line numbers.
    ///
    /// - Parameter rect: The drawing rectangle.
    private func drawNumbers(in rect: NSRect) {
        
        guard
            let drawingInfo,
            let textView,
            let layoutManager = textView.layoutManager as? LayoutManager
        else { return }
        
        guard
            let range = textView.range(for: textView.visibleRect),
            let context = NSGraphicsContext.current?.cgContext
        else { return assertionFailure() }
        
        context.setFont(self.lineNumberFont)
        context.setFontSize(drawingInfo.fontSize)
        context.setFillColor(self.foregroundColor().cgColor)
        context.setStrokeColor(self.foregroundColor(.stroke).cgColor)
        
        let isVerticalText = textView.layoutOrientation == .vertical
        let scale = textView.scale
        
        // adjust drawing coordinate
        let relativePoint = self.convert(NSPoint.zero, from: textView)
        let originOffset = scale * textView.textContainerOrigin.y
        let lineOffset = scale * layoutManager.baselineOffset(for: textView.layoutOrientation)
        switch textView.layoutOrientation {
            case .horizontal:
                context.translateBy(x: self.bounds.maxX, y: relativePoint.y - originOffset)
            case .vertical:
                context.translateBy(x: relativePoint.x - originOffset, y: 0)
            @unknown default: fatalError()
        }
        
        // draw labels
        let options: NSTextView.LineEnumerationOptions = isVerticalText ? .onlySelectionBoundary : []
        textView.enumerateLineFragments(in: range, options: options) { lineRect, lineNumber, isSelected in
            let y = (scale * -lineRect.minY) - lineOffset
            
            // draw tick
            if isVerticalText {
                let rect = CGRect(x: y.rounded() + 0.5, y: 1, width: 0, height: drawingInfo.tickLength)
                context.stroke(rect, width: scale)
            }
            
            // skip intermediate lines by vertical orientation
            let drawsNumber = !isVerticalText || lineNumber.isMultiple(of: 5) || lineNumber == 1 || lineNumber == self.numberOfLines
            guard isSelected || drawsNumber else { return }
            
            let digits = lineNumber.digits
            
            // calculate base position
            let basePosition = isVerticalText
                ? CGPoint(x: y + drawingInfo.charWidth * Double(digits.count) / 2, y: drawingInfo.fontSize)
                : CGPoint(x: -drawingInfo.charWidth, y: y)
            
            // get glyphs and positions
            let positions: [CGPoint] = digits.indices
                .map { basePosition.offsetBy(dx: -Double($0 + 1) * drawingInfo.charWidth) }
            let glyphs: [CGGlyph] = digits
                .map { drawingInfo.digitGlyphs[$0] }
            
            // draw number
            if isSelected {
                context.setFillColor(self.foregroundColor(.bold).cgColor)
                context.setFont(self.effectiveBoldLineNumberFont)
            }
            context.showGlyphs(glyphs, at: positions)
            if isSelected {
                context.setFillColor(self.foregroundColor().cgColor)
                context.setFont(self.lineNumberFont)
            }
        }
    }
    
    
    /// Returns foreground color by considering the current accessibility setting.
    ///
    /// - Parameter strength: The color strength.
    /// - Returns: The foreground color adjusted for the current accessibility setting.
    private func foregroundColor(_ strength: ColorStrength = .normal) -> NSColor {
        
        let fraction = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? strength.rawValue + ColorStrength.highContrastCoefficient
            : strength.rawValue
        
        return fraction < 1
            ? self.textColor.withAlphaComponent(1 - fraction)
            : self.textColor
    }
    
    
    /// Updates parameters related to drawing and layout based on textView's status.
    private func updateDrawingInfo() {
        
        guard
            let textView,
            let editorFont = textView.font
        else { return assertionFailure() }
        
        let drawingInfo = DrawingInfo(font: self.lineNumberFont, fontSize: editorFont.pointSize, scale: textView.scale)
        
        guard self.drawingInfo != drawingInfo else { return }
        
        self.drawingInfo = drawingInfo
        self.needsDisplay = true
        
        self.updateRuleThickness()
    }
    
    
    /// Updates receiver's rule thickness based on drawingInfo and textView's status.
    private func updateRuleThickness() {
        
        guard let drawingInfo else { return }
        
        var ruleThickness: CGFloat
        switch self.orientation {
            case .verticalRuler:
                let numberOfDigits = max(self.numberOfLines.digits.count, self.minimumNumberOfDigits)
                ruleThickness = showsNumbers ? max(CGFloat(numberOfDigits + 2) * drawingInfo.charWidth, 32) : 0
                ruleThickness += self.changeGutterWidth
            case .horizontalRuler:
                ruleThickness = max(2 * drawingInfo.fontSize + drawingInfo.tickLength, 20)
            @unknown default:
                fatalError()
        }
        
        ruleThickness.round(.up)
        
        guard ruleThickness != self.ruleThickness else { return }
        
        self.ruleThickness = ruleThickness
    }
    
    
    /// Observes textView's update to update line number drawing.
    ///
    /// - Parameter textView: The text view to observe.
    private func observeTextView(_ textView: NSTextView) {
        
        assert(textView.enclosingScrollView?.contentView != nil)
        
        self.textViewObservers = [
            NotificationCenter.default.publisher(for: NSTextStorage.didProcessEditingNotification, object: textView.textStorage)
                .map { $0.object as! NSTextStorage }
                .filter { $0.editedMask.contains(.editedCharacters) }
                .sink { [weak self] _ in
                    // -> The digit of the line numbers affect the rule thickness.
                    if self?.orientation == .verticalRuler {
                        DispatchQueue.main.async { [weak self] in
                            self?.updateRuleThickness()
                        }
                    }
                    self?.needsDisplay = true
                },
            
            NotificationCenter.default.publisher(for: EditorTextView.DidLiveChangeSelectionMessage.name, object: textView)
                .sink { [weak self] _ in self?.needsDisplay = true },
            
            NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: textView)
                .sink { [weak self] _ in self?.needsDisplay = true },
            
            NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
                .sink { [weak self] _ in self?.needsDisplay = true },
            
            textView.publisher(for: \.defaultParagraphStyle?.lineHeightMultiple)
                .sink { [weak self] _ in self?.needsDisplay = true },
            
            textView.publisher(for: \.textColor, options: [.initial, .new])
                .compactMap(\.self)
                .sink { [weak self] in self?.textColor = $0 },
            
            textView.publisher(for: \.font)
                .sink { [weak self] _ in self?.needsUpdateDrawingInfo = true },
            
            textView.publisher(for: \.scale)
                .sink { [weak self] _ in self?.needsUpdateDrawingInfo = true },
        ]
    }
}


// MARK: - Controlling Text View

extension LineNumberView {
    
    private struct DraggingInfo {
        
        var index: Int
        var selectedRanges: [NSRange]
    }
    
    
    // MARK: View Methods
    
    /// Scrolls parent textView with scroll event.
    override func scrollWheel(with event: NSEvent) {
        
        self.textView?.scrollWheel(with: event)
    }
    
    
    /// Starts selecting correspondent lines in text view with a dragging / clicking event.
    override func mouseDown(with event: NSEvent) {
        
        guard
            let textView,
            let window
        else { return assertionFailure() }
        
        // get start point
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let index = textView.characterIndex(for: point)
        
        let selectedRanges = textView.selectedRanges.map(\.rangeValue)
        
        self.draggingInfo = DraggingInfo(index: index, selectedRanges: selectedRanges)
        
        // for single click event
        self.selectLines(with: event)
    }
    
    
    /// Selects lines while dragging event.
    override func mouseDragged(with event: NSEvent) {
        
        self.selectLines(with: event)
    }
    
    
    /// Ends selecting correspondent lines in text view with drag event.
    override func mouseUp(with event: NSEvent) {
        
        self.draggingInfo = nil
    }
    
    
    // MARK: Private Methods
    
    /// Selects lines while dragging event.
    ///
    /// - Parameter event: The dragging event.
    private func selectLines(with event: NSEvent) {
        
        guard
            let textView,
            let window,
            let draggingInfo
        else { return assertionFailure() }
        
        // scroll text view if needed
        let point = textView.convert(event.locationInWindow, from: nil)  // textView-based
        textView.scrollToVisible(NSRect(origin: point, size: .zero))
        
        // move focus to textView
        window.makeFirstResponderDiscardingMarkedText(textView)
        
        // select lines
        let pointInScreen = window.convertPoint(toScreen: event.locationInWindow)
        let currentIndex = textView.characterIndex(for: pointInScreen)
        let clickedIndex = draggingInfo.index
        let string = textView.string as NSString
        let currentLineRange = string.lineRange(at: currentIndex)
        let clickedLineRange = string.lineRange(at: clickedIndex)
        var range = currentLineRange.union(clickedLineRange)
        
        let affinity: NSSelectionAffinity = (currentIndex < clickedIndex) ? .upstream : .downstream
        
        // with Command key (add selection)
        if event.modifierFlags.contains(.command) {
            var selectedRanges: [NSRange] = []
            var intersects = false
            
            for selectedRange in draggingInfo.selectedRanges {
                if selectedRange.lowerBound <= range.lowerBound, range.upperBound <= selectedRange.upperBound {  // exclude
                    let range1 = NSRange(selectedRange.lowerBound..<range.lowerBound)
                    let range2 = NSRange(range.upperBound..<selectedRange.upperBound)
                    
                    if !range1.isEmpty {
                        selectedRanges.append(range1)
                    }
                    if !range2.isEmpty {
                        selectedRanges.append(range2)
                    }
                    
                    intersects = true
                    continue
                }
                
                // add
                selectedRanges.append(selectedRange)
            }
            
            if !intersects {  // add current dragging selection
                selectedRanges.append(range)
            }
            
            textView.setSelectedRanges(selectedRanges as [NSValue], affinity: affinity, stillSelecting: false)
            
            return
        }
        
        // with Shift key (expand selection)
        if event.modifierFlags.contains(.shift) {
            let selectedRange = textView.selectedRange
            
            if selectedRange.contains(currentIndex) {  // reduce
                let inUpperSelection = (currentIndex - selectedRange.lowerBound) < selectedRange.length / 2
                range = inUpperSelection  // clicked upper half section of selected range
                    ? NSRange(currentIndex..<selectedRange.upperBound)
                    : NSRange(selectedRange.lowerBound..<currentLineRange.upperBound)
                
            } else {  // expand
                range.formUnion(selectedRange)
            }
        }
        
        textView.setSelectedRange(range, affinity: affinity, stillSelecting: false)
    }
}

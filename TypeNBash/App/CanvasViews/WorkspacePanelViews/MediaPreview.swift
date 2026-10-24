//
//  ImagePreviewView.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/24/26.
//
import PDFKit
import SwiftUI
import Foundation

struct ImagePreviewView: View {
    /// Raw image bytes — works for both local and SSH previews.
    let data: Data

    var body: some View {
        if let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .padding()
        } else {
            ContentUnavailableView("Unable to load image",
                                   systemImage: "photo.badge.exclamationmark")
        }
    }
}

struct PDFKitPreviewView: NSViewRepresentable {
    /// Raw PDF bytes — works for both local and SSH previews.
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = PDFDocument(data: data)
        pdfView.autoScales = true
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        // The call site keys this view by file (`.id`), so a new file rebuilds the
        // view instead of mutating an existing document here.
    }
}

struct DocumentPreviewView: View {
    let data: Data
    var body: some View {
        PDFKitPreviewView(data: data)
    }
}

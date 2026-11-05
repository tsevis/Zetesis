import AppKit
import Foundation
import PDFKit
import Vision

/// zetesis-ocr <file.pdf> [--min-chars N]
///
/// Recognises the text of the pages of a PDF that have (almost) none of their own, with macOS Vision,
/// and prints one JSON line per such page: {"page": n, "text": "..."} (pages counted from 1).
/// The engine (Engine/ocr.py) runs it in the background, one book at a time.

let renderScale: CGFloat = 2.5      // 180 dpi: Vision's accurate level reads body text well from here
let maxSide: CGFloat = 4000         // keeps posters and plates from becoming huge images
let minConfidence: Float = 0.3      // below this a "word" is usually a picture read as letters

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func arguments() -> (url: URL, minChars: Int) {
    var args = Array(CommandLine.arguments.dropFirst())
    var minChars = 20
    if let i = args.firstIndex(of: "--min-chars") {
        guard i + 1 < args.count, let n = Int(args[i + 1]) else { fail("--min-chars needs a number") }
        minChars = n
        args.removeSubrange(i...(i + 1))
    }
    guard args.count == 1 else { fail("usage: zetesis-ocr <file.pdf> [--min-chars N]") }
    return (URL(filePath: args[0]), minChars)
}

func image(of page: PDFPage) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    let scale = min(renderScale, maxSide / max(bounds.width, bounds.height, 1))
    let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    // The thumbnail applies the page's rotation, so the text reaches Vision upright.
    let picture = page.thumbnail(of: size, for: .mediaBox)
    return picture.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

func recognise(_ image: CGImage) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    try VNImageRequestHandler(cgImage: image).perform([request])
    // Top to bottom, then left to right (Vision's origin is bottom-left).
    let lines = (request.results ?? [])
        .sorted { a, b in
            abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01
                ? a.boundingBox.midY > b.boundingBox.midY : a.boundingBox.minX < b.boundingBox.minX
        }
        .compactMap { observation -> String? in
            guard let best = observation.topCandidates(1).first, best.confidence >= minConfidence else { return nil }
            return best.string
        }
    return lines.joined(separator: "\n")
}

func emit(page: Int, text: String) {
    guard let data = try? JSONSerialization.data(withJSONObject: ["page": page, "text": text]) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

let (url, minChars) = arguments()
guard let document = PDFDocument(url: url) else { fail("cannot open \(url.path)") }
if document.isLocked { fail("encrypted: \(url.path)") }
for index in 0..<document.pageCount {
    autoreleasepool {
        guard let page = document.page(at: index) else { return }
        let own = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard own.count < minChars, let picture = image(of: page) else { return }
        do {
            emit(page: index + 1, text: try recognise(picture))
        } catch {
            FileHandle.standardError.write(Data("page \(index + 1): \(error.localizedDescription)\n".utf8))
        }
    }
}

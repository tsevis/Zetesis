import AppKit
import Foundation
import PDFKit
import Vision

/// zetesis-ocr <file.pdf> [--min-chars N] [--tesseract PATH [--greek]]
///
/// Recognises the text of the pages of a PDF that have (almost) none of their own, with macOS Vision,
/// and prints one JSON line per such page: {"page": n, "text": "...", "engine": "vision"} (pages
/// counted from 1). The engine (Engine/ocr.py) runs it in the background, one book at a time.
///
/// Vision reads no Greek. With --tesseract, a page Vision is unsure of goes to Tesseract's script
/// detection, and if that says Greek, Tesseract reads it; with --greek, Tesseract reads every page.

let renderScale: CGFloat = 2.5      // 180 dpi: Vision's accurate level reads body text well from here
let maxSide: CGFloat = 4000         // keeps posters and plates from becoming huge images
let minConfidence: Float = 0.3      // below this a "word" is usually a picture read as letters
// Vision's mean line confidence on a synthetic 150 dpi scan: 0.49 and 0.54 on Greek pages, 1.00 on English.
let doubtfulConfidence: Float = 0.8
let tesseractLanguages = "ell+eng"
// Tesseract read a test page in 0.4–1.4 s; a page still running after this is stuck.
let tesseractTimeout: TimeInterval = 120

struct TesseractFailed: LocalizedError {
    let errorDescription: String?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

struct Options {
    var url: URL
    var minChars = 20
    var tesseract: String?
    var greek = false
}

func value(after flag: String, in args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count else { fail("\(flag) needs a value") }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}

func arguments() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    let minChars = value(after: "--min-chars", in: &args)
    let tesseract = value(after: "--tesseract", in: &args)
    let greek = args.contains("--greek")
    args.removeAll { $0 == "--greek" }
    guard args.count == 1 else { fail("usage: zetesis-ocr <file.pdf> [--min-chars N] [--tesseract PATH [--greek]]") }
    var options = Options(url: URL(filePath: args[0]), tesseract: tesseract, greek: greek)
    if let minChars {
        guard let n = Int(minChars) else { fail("--min-chars needs a number") }
        options.minChars = n
    }
    if greek && tesseract == nil { fail("--greek needs --tesseract") }
    return options
}

func image(of page: PDFPage) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    let scale = min(renderScale, maxSide / max(bounds.width, bounds.height, 1))
    let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    // The thumbnail applies the page's rotation, so the text reaches Vision upright.
    let picture = page.thumbnail(of: size, for: .mediaBox)
    return picture.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

/// The page's text and Vision's mean confidence in its lines.
func recognise(_ image: CGImage) throws -> (text: String, confidence: Float) {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    try VNImageRequestHandler(cgImage: image).perform([request])
    // Top to bottom, then left to right (Vision's origin is bottom-left).
    let best = (request.results ?? [])
        .sorted { a, b in
            abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01
                ? a.boundingBox.midY > b.boundingBox.midY : a.boundingBox.minX < b.boundingBox.minX
        }
        .compactMap { $0.topCandidates(1).first }
    let kept = best.filter { $0.confidence >= minConfidence }
    let mean = best.isEmpty ? 1 : best.map(\.confidence).reduce(0, +) / Float(best.count)
    return (kept.map(\.string).joined(separator: "\n"), mean)
}

/// Runs Tesseract on the image (saved as a temporary PNG) and returns what it prints. Its output goes
/// to a file rather than a pipe, so a stuck run can be stopped at the deadline.
func tesseract(_ path: String, _ image: CGImage, _ arguments: [String]) throws -> String {
    let base = FileManager.default.temporaryDirectory.appending(path: "zetesis-ocr-\(UUID().uuidString)")
    let png = base.appendingPathExtension("png")
    let out = base.appendingPathExtension("txt")
    defer {
        try? FileManager.default.removeItem(at: png)
        try? FileManager.default.removeItem(at: out)
    }
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: png)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    let output = try FileHandle(forWritingTo: out)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = URL(filePath: path)
    process.arguments = [png.path, "-"] + arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice  // progress notes ("Estimating resolution as …")
    try process.run()
    let deadline = Date(timeIntervalSinceNow: tesseractTimeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        throw TesseractFailed(errorDescription: "Tesseract took more than \(Int(tesseractTimeout)) s")
    }
    guard process.terminationStatus == 0 else {
        throw TesseractFailed(errorDescription: "Tesseract exited with status \(process.terminationStatus)")
    }
    return String(decoding: try Data(contentsOf: out), as: UTF8.self)
}

func looksGreek(_ path: String, _ image: CGImage) -> Bool {
    let report = (try? tesseract(path, image, ["--psm", "0"])) ?? ""
    return report.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "Script: Greek" }
}

/// The page's text and the engine that read it.
func read(_ picture: CGImage, _ options: Options) throws -> (text: String, engine: String) {
    if let path = options.tesseract, options.greek {
        return (try tesseract(path, picture, ["-l", tesseractLanguages]), "tesseract")
    }
    let vision = try recognise(picture)
    if let path = options.tesseract, vision.confidence < doubtfulConfidence, looksGreek(path, picture) {
        return (try tesseract(path, picture, ["-l", tesseractLanguages]), "tesseract")
    }
    return (vision.text, "vision")
}

func emit(page: Int, text: String, engine: String) {
    let row: [String: Any] = ["page": page, "text": text, "engine": engine]
    guard let data = try? JSONSerialization.data(withJSONObject: row) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

let options = arguments()
guard let document = PDFDocument(url: options.url) else { fail("cannot open \(options.url.path)") }
if document.isLocked { fail("encrypted: \(options.url.path)") }
var (tried, failed) = (0, 0)
for index in 0..<document.pageCount {
    autoreleasepool {
        guard let page = document.page(at: index) else { return }
        let own = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard own.count < options.minChars, let picture = image(of: page) else { return }
        tried += 1
        do {
            let found = try read(picture, options)
            emit(page: index + 1, text: found.text, engine: found.engine)
        } catch {
            failed += 1
            FileHandle.standardError.write(Data("page \(index + 1): \(error.localizedDescription)\n".utf8))
        }
    }
}
// Every page failing means a broken setup, not a book without text: the engine records it as failed.
if tried > 0 && failed == tried { fail("no page could be read") }

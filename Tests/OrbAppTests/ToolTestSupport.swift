import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Orb

/// A throwaway working directory for tool tests, removed when the test ends.
final class ToolWorkspace {
    let directory: URL
    /// Where tool outputs that outgrow the cap are saved, away from the working directory.
    let outputs: URL
    let context: ToolContext

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "OrbToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        outputs = FileManager.default.temporaryDirectory.appending(path: "OrbToolTests-saidas-\(UUID().uuidString)")
        context = ToolContext(workingDirectory: directory, outputsDirectory: outputs)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: outputs)
    }

    func run(_ tool: some AgentTool, _ arguments: [String: JSONValue]) async throws -> String {
        try await tool.run(.object(arguments), context: context)
    }

    func url(_ name: String) -> URL { directory.appending(path: name) }

    @discardableResult
    func write(_ name: String, _ data: Data) throws -> URL {
        let url = url(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    @discardableResult
    func write(_ name: String, _ text: String) throws -> URL { try write(name, Data(text.utf8)) }

    func read(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
    func readText(_ name: String) throws -> String { String(decoding: try read(name), as: UTF8.self) }

    func link(_ name: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url(name).path, withDestinationPath: destination)
    }
}

/// Test fixtures built with Core Graphics, so no binary files live in the repository.
enum Fixtures {
    /// A PDF with one line of text per page.
    static func pdf(pages: [String]) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            draw(text, size: 24, at: CGPoint(x: 72, y: 700), in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A white PNG with large black text, for OCR.
    static func png(text: String, width: Int = 900, height: Int = 240) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(text, size: 96, at: CGPoint(x: 30, y: 80), in: context)
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func draw(_ text: String, size: CGFloat, at point: CGPoint, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
    }
}

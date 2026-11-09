import Foundation
import XCTest
@testable import CmuxClone

@MainActor
final class FileWorkspaceTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CmuxLocalFiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testTreeShowsDotFilesByDefaultAndCanHideThem() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("z-folder"), withIntermediateDirectories: false)
        try Data().write(to: root.appendingPathComponent("a.txt"))
        try Data().write(to: root.appendingPathComponent(".hidden"))

        let model = FileWorkspaceModel(rootURL: root)
        XCTAssertEqual(model.children[root.path]?.map(\.name), ["z-folder", ".hidden", "a.txt"])
        model.showHidden = false
        XCTAssertEqual(model.children[root.path]?.map(\.name), ["z-folder", "a.txt"])
    }

    func testTreeFilenameFilterNarrowsLoadedFilesByRelativePath() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("QuickOpen.swift"))
        try Data().write(to: root.appendingPathComponent("Notes.txt"))

        let model = FileWorkspaceModel(rootURL: root)
        let folder = try XCTUnwrap(model.children[root.path]?.first { $0.url == source })
        model.toggle(folder)
        model.filter = "quickopen"

        XCTAssertEqual(model.rows.map { $0.item.url.lastPathComponent }, ["Sources", "QuickOpen.swift"])
    }

    func testSwiftHighlighterClassifiesKeywordsStringsNumbersAndComments() {
        let source = "let answer = 42\nlet message = \"hello\"\n// note\n"
        let nsSource = source as NSString
        let tokens = CodeHighlighter.tokens(in: source, language: .swift)
        XCTAssertTrue(tokens.contains { $0.kind == .keyword && nsSource.substring(with: $0.range) == "let" })
        XCTAssertTrue(tokens.contains { $0.kind == .number && nsSource.substring(with: $0.range) == "42" })
        XCTAssertTrue(tokens.contains { $0.kind == .string && nsSource.substring(with: $0.range) == "\"hello\"" })
        XCTAssertTrue(tokens.contains { $0.kind == .comment && nsSource.substring(with: $0.range) == "// note" })
        XCTAssertEqual(CodeLanguage.forFile(URL(fileURLWithPath: "/tmp/Sample.swift")), .swift)
    }

    func testOpenEditAndSavePersistsOnlyExplicitlyToDisk() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        let model = FileWorkspaceModel(rootURL: root)

        model.open(file)
        let document = try XCTUnwrap(model.selectedDocument)
        XCTAssertTrue(document.isPreview)
        XCTAssertFalse(document.isDirty)
        model.update(document, text: "let value = 2\n")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let value = 1\n")
        XCTAssertTrue(model.save(document))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let value = 2\n")
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(document.isPreview)
    }

    func testSaveDetectsConcurrentDiskChangeUntilExplicitOverwrite() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.txt")
        try Data("initial".utf8).write(to: file)
        let model = FileWorkspaceModel(rootURL: root)
        model.open(file, preview: false)
        let document = try XCTUnwrap(model.selectedDocument)
        model.update(document, text: "editor")
        try Data("external".utf8).write(to: file)

        XCTAssertFalse(model.save(document))
        XCTAssertTrue(document.externalChange)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external")
        XCTAssertTrue(model.save(document, overwrite: true))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "editor")
    }

    func testRejectsFilesOutsideWorkspaceAndUnsafeNames() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let model = FileWorkspaceModel(rootURL: root)
        model.open(outside.appendingPathComponent("escape.txt"))
        XCTAssertNotNil(model.error)
        XCTAssertThrowsError(try model.create(name: "../escape", directory: false))
    }

    func testCreateRenameAndTrashUseWorkspaceRoot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FileWorkspaceModel(rootURL: root)
        let file = try model.create(name: "first.txt", directory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let item = try XCTUnwrap(model.children[root.path]?.first { $0.url == file })
        try model.rename(item, to: "second.txt")
        let renamed = root.appendingPathComponent("second.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        let renamedItem = try XCTUnwrap(model.children[root.path]?.first { $0.url == renamed })
        try model.trash(renamedItem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
    }
}

import Foundation
import XCTest
@testable import CmuxClone

final class QuickTunnelTests: XCTestCase {
    func testPortValidationAndCloudflaredArguments() {
        XCTAssertEqual(CloudflaredQuickTunnel.port(from: "5173"), 5173)
        XCTAssertEqual(CloudflaredQuickTunnel.port(from: "65535"), 65_535)
        XCTAssertNil(CloudflaredQuickTunnel.port(from: "0"))
        XCTAssertNil(CloudflaredQuickTunnel.port(from: "65536"))
        XCTAssertNil(CloudflaredQuickTunnel.port(from: " 5173"))
        XCTAssertNil(CloudflaredQuickTunnel.port(from: "12x"))
        XCTAssertNil(CloudflaredQuickTunnel.port(from: "５１７３"))
        XCTAssertEqual(
            CloudflaredQuickTunnel.arguments(port: 5173),
            ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:5173"]
        )
    }

    func testPublicURLParserAcceptsOnlyQuickTunnelHostnames() {
        XCTAssertEqual(
            CloudflaredQuickTunnel.publicURL(in: "ready: https://example-random.trycloudflare.com\n"),
            "https://example-random.trycloudflare.com"
        )
        XCTAssertNil(CloudflaredQuickTunnel.publicURL(in: "https://example.com"))
        XCTAssertNil(CloudflaredQuickTunnel.publicURL(in: "https://trycloudflare.com.attacker.test"))
    }

    func testExecutableLookupUsesPathAndHomebrewLocations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = bin.appendingPathComponent("cloudflared")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        XCTAssertEqual(
            CloudflaredQuickTunnel.executableURL(environment: ["PATH": bin.path]),
            executable
        )
        XCTAssertNil(CloudflaredQuickTunnel.executableURL(environment: ["PATH": root.path]))
    }
}

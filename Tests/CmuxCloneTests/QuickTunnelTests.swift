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

    func testExecutableLookupUsesPathAndHomebrewLocations() {
        let files = ExecutableFixtureFileManager()
        files.executablePaths = ["/fixture/bin/cloudflared", "/opt/homebrew/bin/cloudflared"]
        XCTAssertEqual(
            CloudflaredQuickTunnel.executableURL(environment: ["PATH": "/fixture/bin"], fileManager: files),
            URL(fileURLWithPath: "/fixture/bin/cloudflared")
        )
        XCTAssertEqual(
            CloudflaredQuickTunnel.executableURL(environment: ["PATH": "/fixture/missing"], fileManager: files),
            URL(fileURLWithPath: "/opt/homebrew/bin/cloudflared")
        )
        files.executablePaths = []
        XCTAssertNil(CloudflaredQuickTunnel.executableURL(environment: ["PATH": "/fixture/bin"], fileManager: files))
    }
}

private final class ExecutableFixtureFileManager: FileManager, @unchecked Sendable {
    var executablePaths: Set<String> = []

    override func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

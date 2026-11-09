import Foundation
import XCTest
@testable import CmuxClone

final class ShellEnvironmentTests: XCTestCase {
    func testLoginInteractiveEnvironmentPreservesValuesAndCachesOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rc = root.appendingPathComponent(".zshrc")
        try Data("""
        print 'a startup banner with = signs'
        export CMUX_ENV_TEST_VALUE='value with spaces=and
        a second line'
        export PNPM_HOME='/tmp/a toolchain with spaces'
        export PATH="$PNPM_HOME:$PATH"
        """.utf8).write(to: rc)
        let base = ["HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "CMUX_INHERITED": "keep"]
        let resolver = ShellEnvironment(base: base, shell: URL(fileURLWithPath: "/bin/zsh"))
        let environment = resolver.resolve()
        XCTAssertEqual(environment["CMUX_ENV_TEST_VALUE"], "value with spaces=and\na second line")
        XCTAssertEqual(environment["CMUX_INHERITED"], "keep")
        XCTAssertEqual(environment["TERM"], "xterm-256color")
        XCTAssertTrue(environment["PATH"]?.hasPrefix("/tmp/a toolchain with spaces:") == true)
        try Data("export CMUX_ENV_TEST_VALUE=changed\n".utf8).write(to: rc)
        XCTAssertEqual(resolver.resolve(), environment, "Do not rerun shell initialization for each Git command")
    }

    func testTimeoutAndLaunchFailureFallBackToOriginalEnvironment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("exec /bin/sleep 10\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
        let base = ["HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin"]
        let start = Date()
        let timedOut = ShellEnvironment(base: base, shell: URL(fileURLWithPath: "/bin/zsh"), timeout: 0.2)
        XCTAssertEqual(timedOut.resolve(), base)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(ShellEnvironment(base: base, shell: root.appendingPathComponent("missing-shell")).resolve(), base)
    }
}

import XCTest
@testable import CmuxClone

final class GitBranchPickerTests: XCTestCase {
    func testSearchAcrossManyBranchesAndCommitDetails() {
        let refs = (0..<250).map { index in
            GitCheckoutReference(id: "refs/heads/feature/\(index)", name: "feature/\(index)", kind: .local,
                shortHash: "abc\(index)", author: "Author \(index)", subject: "修复问题 \(index)",
                timestamp: Date(timeIntervalSince1970: Double(index)))
        }
        let purpose = GitBranchPickerPurpose.merge
        XCTAssertEqual(purpose.references(refs, currentBranch: "feature/249", query: "").count, 249)
        XCTAssertEqual(purpose.references(refs, currentBranch: "feature/249", query: "").first?.name, "feature/248")
        for query in [" feature/127 ", "修复问题 127", "AUTHOR 127", "abc127"] {
            XCTAssertEqual(purpose.references(refs, currentBranch: "feature/249", query: query).map(\.name), ["feature/127"])
        }
        XCTAssertTrue(purpose.references(refs, currentBranch: nil, query: "no such branch").isEmpty)
        XCTAssertEqual(GitBranchPickerPurpose.checkout.references(refs, currentBranch: "feature/10", query: "").first?.name, "feature/10")
    }

    func testMergeAndRebaseOnlyOfferOtherLocalAndRemoteBranchesAndKeepFullRefs() throws {
        let refs = [
            reference("refs/heads/main", "main", .local),
            reference("refs/heads/feature", "feature", .local),
            reference("refs/remotes/origin/feature", "origin/feature", .remote),
            reference("refs/tags/feature", "feature", .tag)
        ]
        for purpose in [GitBranchPickerPurpose.merge, .rebase] {
            let candidates = purpose.references(refs, currentBranch: "main", query: "")
            XCTAssertEqual(candidates.map(\.id), ["refs/heads/feature", "refs/remotes/origin/feature"])
            for ref in candidates {
                let operation = try XCTUnwrap(purpose.operation(for: ref))
                switch operation {
                case .mergeBranch(let target), .rebaseBranch(let target): XCTAssertEqual(target, ref.id)
                default: XCTFail("Wrong operation")
                }
            }
            XCTAssertTrue(purpose.references([refs[0], refs[3]], currentBranch: "main", query: "").isEmpty)
        }
        XCTAssertEqual(GitBranchPickerPurpose.checkout.references(refs, currentBranch: "main", query: "").count, 4)
    }

    private func reference(_ id: String, _ name: String, _ kind: GitCheckoutReference.Kind) -> GitCheckoutReference {
        GitCheckoutReference(id: id, name: name, kind: kind, shortHash: "abc123", author: "Test", subject: "Commit", timestamp: nil)
    }
}

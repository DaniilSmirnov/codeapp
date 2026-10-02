import Clibgit2
import Foundation
import SwiftGit2
import XCTest

@testable import CodeUI

/// All fixtures are built through SwiftGit2/libgit2; no Git executable or network is used.
final class RepositorySafetyTests: XCTestCase {
    private var root: URL!
    private var repository: Repository!
    private let signature = Signature(
        name: "Git Safety Tests", email: "tests@example.invalid")

    override class func setUp() {
        super.setUp()
        Repository.initialize_libgit2()
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repository = try Repository.create(at: root).get()
        try write("shared.txt", "base\n")
        try write("unchanged.txt", "keep me\n")
        _ = try commit("base")
    }

    override func tearDownWithError() throws {
        repository = nil
        if let root = root {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func write(_ path: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func commit(_ message: String) throws -> Commit {
        try repository.add(path: "*").get()
        return try repository.commit(message: message, signature: signature).get()
    }

    private func head() throws -> Branch {
        try XCTUnwrap(repository.HEAD().get() as? Branch)
    }

    private func indexData() throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(".git/index"))
    }

    /// A target that changes a tracked file and introduces a potentially colliding file.
    private func target() throws -> (Branch, Branch) {
        let original = try head()
        let target = try repository.createBranch(
            at: repository.commit(original.oid).get(), branchName: "target"
        ).get()
        try repository.checkout(target, strategy: .Safe).get()
        try write("shared.txt", "target\n")
        try write("new.txt", "target new\n")
        _ = try commit("target")
        let updated = try head()
        try repository.checkout(original, strategy: .Safe).get()
        return (original, updated)
    }

    func testSafeCheckoutRejectsDirtyFilesWithoutChangingHeadOrIndex() throws {
        for staged in [false, true] {
            let (original, target) = try target()
            try write("shared.txt", "my unsaved work\n")
            if staged {
                try repository.add(path: "shared.txt").get()
            }
            let index = try indexData()
            XCTAssertThrowsError(try repository.checkout(target, strategy: .Safe).get())
            XCTAssertEqual(try head().longName, original.longName)
            XCTAssertEqual(try head().oid, original.oid)
            XCTAssertEqual(try indexData(), index)
            XCTAssertEqual(try read("shared.txt"), "my unsaved work\n")
            // Reset only the test fixture before exercising the next variant.
            try repository.checkout(original, strategy: .Force).get()
            try repository.deleteBranch(branch: target)
        }
    }

    func testSafeCheckoutRejectsUntrackedCollisionAndKeepsHead() throws {
        let (original, target) = try target()
        try write("new.txt", "my untracked work\n")
        let index = try indexData()
        XCTAssertThrowsError(try repository.checkout(target, strategy: .Safe).get())
        XCTAssertEqual(try head().oid, original.oid)
        XCTAssertEqual(try head().longName, original.longName)
        XCTAssertEqual(try indexData(), index)
        XCTAssertEqual(try read("new.txt"), "my untracked work\n")
    }

    func testSafeCheckoutRejectsIgnoredCollisionAndKeepsData() throws {
        let (original, target) = try target()
        try write(".git/info/exclude", "new.txt\n")
        try write("new.txt", "my ignored work\n")
        let index = try indexData()
        XCTAssertThrowsError(try repository.checkout(target, strategy: .Safe).get())
        XCTAssertEqual(try head().oid, original.oid)
        XCTAssertEqual(try head().longName, original.longName)
        XCTAssertEqual(try indexData(), index)
        XCTAssertEqual(try read("new.txt"), "my ignored work\n")
    }

    func testCleanFastForwardUpdatesBranchIndexAndWorktree() throws {
        let (original, target) = try target()
        try repository.mergeBranchIntoCurrentBranch(branch: target, signature: signature)
        XCTAssertEqual(try head().longName, original.longName)
        XCTAssertEqual(try head().oid, target.oid)
        XCTAssertEqual(try read("shared.txt"), "target\n")
        XCTAssertEqual(try read("new.txt"), "target new\n")
        XCTAssertNoThrow(try repository.requireCleanWorktree())
    }

    func testDirtyFastForwardDoesNotAdvanceBranchOrOverwriteData() throws {
        let (original, target) = try target()
        try write("shared.txt", "staged\n")
        try repository.add(path: "shared.txt").get()
        try write("shared.txt", "unstaged\n")
        try write("new.txt", "untracked\n")
        let index = try indexData()
        XCTAssertThrowsError(
            try repository.mergeBranchIntoCurrentBranch(branch: target, signature: signature))
        XCTAssertEqual(try head().oid, original.oid)
        XCTAssertEqual(try indexData(), index)
        XCTAssertEqual(try read("shared.txt"), "unstaged\n")
        XCTAssertEqual(try read("new.txt"), "untracked\n")
    }

    func testFastForwardRejectsIgnoredCollisionBeforeUpdatingReference() throws {
        let (original, target) = try target()
        try write(".git/info/exclude", "new.txt\n")
        try write("new.txt", "ignored contents\n")
        let index = try indexData()
        XCTAssertThrowsError(
            try repository.mergeBranchIntoCurrentBranch(branch: target, signature: signature))
        XCTAssertEqual(try head().oid, original.oid)
        XCTAssertEqual(try indexData(), index)
        XCTAssertEqual(try read("new.txt"), "ignored contents\n")
    }

    func testDivergedMergeUsesCommonAncestorAndPreservesBothChanges() throws {
        let (original, target) = try target()
        try write("local.txt", "local change\n")
        let local = try commit("local")
        try repository.mergeBranchIntoCurrentBranch(branch: target, signature: signature)
        let merged = try repository.commit(head().oid).get()
        XCTAssertEqual(try head().longName, original.longName)
        XCTAssertEqual(merged.parents.map { $0.oid }, [local.oid, target.oid])
        XCTAssertEqual(try read("shared.txt"), "target\n")
        XCTAssertEqual(try read("local.txt"), "local change\n")
        XCTAssertEqual(try read("unchanged.txt"), "keep me\n")
        XCTAssertNoThrow(try repository.requireCleanWorktree())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".git/MERGE_HEAD").path))
    }

    func testConflictingMergeLeavesHeadAndPersistsMergeState() throws {
        let (_, target) = try target()
        try write("shared.txt", "conflicting local change\n")
        let local = try commit("local conflict")
        XCTAssertThrowsError(
            try repository.mergeBranchIntoCurrentBranch(branch: target, signature: signature))
        XCTAssertEqual(try head().oid, local.oid)
        XCTAssertEqual(
            git_repository_state(repository.pointer), Int32(GIT_REPOSITORY_STATE_MERGE.rawValue))
        var index: OpaquePointer?
        XCTAssertEqual(git_repository_index(&index, repository.pointer), 0)
        let opened = try XCTUnwrap(index)
        defer { git_index_free(opened) }
        XCTAssertNotEqual(git_index_has_conflicts(opened), 0)
        let mergeHead = try read(".git/MERGE_HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(mergeHead, target.oid.description)
        XCTAssertThrowsError(
            try repository.mergeBranchIntoCurrentBranch(branch: target, signature: signature))
    }

    func testProviderCommitFinishesResolvedMergeAndAllowsCheckout() async throws {
        let (original, target) = try target()
        try write("shared.txt", "local conflict\n")
        let local = try commit("local")
        XCTAssertThrowsError(
            try repository.mergeBranchIntoCurrentBranch(branch: target, signature: signature))
        try write("shared.txt", "resolved\n")
        let provider = LocalGitServiceProvider(root: root)
        provider.sign(name: signature.name, email: signature.email)
        try await provider.stage(paths: [root.appendingPathComponent("shared.txt").absoluteString])
        try await provider.commit(message: "Resolve merge")
        let merged = try repository.commit(head().oid).get()
        XCTAssertEqual(merged.parents.map { $0.oid }, [local.oid, target.oid])
        XCTAssertEqual(repository.repositoryState(), .none)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".git/MERGE_HEAD").path))
        XCTAssertNoThrow(try repository.requireCleanWorktree())
        XCTAssertNoThrow(try repository.checkout(original, strategy: .Safe).get())
        XCTAssertNoThrow(try repository.requireCleanWorktree())
        XCTAssertEqual(try read("shared.txt"), "resolved\n")
    }

    func testDetachedHeadCannotBeMerged() throws {
        let (original, target) = try target()
        try repository.checkout(original.oid, strategy: .Safe).get()
        let index = try indexData()
        XCTAssertThrowsError(
            try repository.mergeBranchIntoCurrentBranch(branch: target, signature: signature))
        XCTAssertEqual(try repository.HEAD().get().oid, original.oid)
        XCTAssertEqual(try indexData(), index)
    }

    func testUpstreamUsesConfiguredRemoteAndDifferentBranchName() throws {
        let (_, target) = try target()
        let local = try head()
        var remote: OpaquePointer?
        XCTAssertEqual(
            git_remote_create(&remote, repository.pointer, "upstream", root.absoluteString), 0)
        defer { git_remote_free(remote) }
        var reference: OpaquePointer?
        var oid = target.oid.oid
        XCTAssertEqual(
            git_reference_create(
                &reference, repository.pointer, "refs/remotes/upstream/main", &oid, 0, nil), 0)
        defer { git_reference_free(reference) }
        var localReference: OpaquePointer?
        XCTAssertEqual(git_reference_lookup(&localReference, repository.pointer, local.longName), 0)
        defer { git_reference_free(localReference) }
        XCTAssertEqual(git_branch_set_upstream(localReference, "upstream/main"), 0)
        let upstream = try repository.upstream(of: local)
        XCTAssertEqual(upstream.longName, "refs/remotes/upstream/main")
        XCTAssertEqual(upstream.oid, target.oid)
        let counts = try repository.aheadBehind(local: local.oid, upstream: upstream.oid).get()
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 1)
    }

    func testMissingUpstreamFailsExplicitly() throws {
        XCTAssertThrowsError(try repository.upstream(of: head()))
    }
}

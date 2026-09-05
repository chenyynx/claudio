// [Fix 2026-09-06] Pin the attachment cache directory contract.
//
// Background: 8200afd added a file_not_found_re_add fallback in
// RemoteFileUpload that catches the case where iOS silently reaps the
// destURL between addFileAttachment and the upload call. The root cause
// was that the previous attachmentCacheDir pointed at .cachesDirectory,
// which iOS treats as purgeable. The fix moves the directory to
// .applicationSupportDirectory, which iOS never auto-clears.
//
// These tests pin the new contract so a future refactor that swaps the
// path back to a purgeable directory (or breaks the auto-create) fails
// the suite before it ships.

import XCTest
@testable import Minis

@MainActor
final class AttachmentCacheDirTests: XCTestCase {

    /// addFileAttachment should land the file in Application Support
    /// (not Caches), and the directory should be auto-created.
    func test_addFileAttachment_storesInApplicationSupport() throws {
        // Source: a tmp file with a recognisable PDF name so the kind
        // classifier doesn't get confused (detectImageType would return
        // nil on a fake byte stream anyway, but a real ext keeps the
        // path clean).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentCacheDirTests-\(UUID().uuidString).pdf")
        try Data("test content".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vm = AIChatViewModel()
        vm.addFileAttachment(from: tmp)

        XCTAssertFalse(vm.attachments.isEmpty, "addFileAttachment should append")
        let cacheURL = try XCTUnwrap(vm.attachments.last?.cacheURL)
        XCTAssertTrue(
            cacheURL.path.contains("Application Support"),
            "Expected Application Support, got: \(cacheURL.path)"
        )
        XCTAssertTrue(
            cacheURL.path.hasSuffix("InputAttachments"),
            "Expected InputAttachments subdir, got: \(cacheURL.path)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cacheURL.path),
            "Cache file should exist on disk after add"
        )
    }

    /// Init should clean the old Caches/InputAttachments directory so
    /// legacy chips don't reference dead paths after the migration.
    func test_init_cleansOldCachesDirectory() throws {
        let oldDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InputAttachments")
        // Wipe any previous state from other tests, then plant a file.
        try? FileManager.default.removeItem(at: oldDir)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        let dummy = oldDir.appendingPathComponent("stale-chip-data.txt")
        try Data("stale".utf8).write(to: dummy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dummy.path))

        // Triggering AIChatViewModel() init should remove the old dir.
        _ = AIChatViewModel()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dummy.path),
            "Init should have removed the old Caches/InputAttachments directory"
        )
    }
}

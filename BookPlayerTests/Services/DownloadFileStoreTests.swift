//
//  DownloadFileStoreTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
import XCTest

final class DownloadTaskInfoTests: XCTestCase {
  func testTopLevelFileKeepsTheLegacyDescription() {
    let info = DownloadTaskInfo(url: "https://example.com/a.mp3", folderName: nil, allOrNothing: false)

    XCTAssertEqual(info.taskDescription, "SingleFileDownload-https://example.com/a.mp3")
  }

  func testFolderInfoRoundTripsThroughTheDescription() {
    let info = DownloadTaskInfo(url: "https://example.com/a.mp3", folderName: "Foundation", allOrNothing: true)

    XCTAssertEqual(DownloadTaskInfo(taskDescription: info.taskDescription), info)
  }

  func testSameRequestGivesTheSameDescription() {
    let first = DownloadTaskInfo(url: "https://example.com/a.mp3", folderName: "Book", allOrNothing: true)
    let second = DownloadTaskInfo(url: "https://example.com/a.mp3", folderName: "Book", allOrNothing: true)

    XCTAssertEqual(first.taskDescription, second.taskDescription)
  }

  func testLegacyDescriptionDecodesToATopLevelFile() {
    let info = DownloadTaskInfo(taskDescription: "SingleFileDownload-https://example.com/a.mp3")

    XCTAssertEqual(info, DownloadTaskInfo(url: "https://example.com/a.mp3", folderName: nil, allOrNothing: false))
  }

  func testForeignDescriptionsAreIgnored() {
    XCTAssertNil(DownloadTaskInfo(taskDescription: nil))
    XCTAssertNil(DownloadTaskInfo(taskDescription: "Books/Foundation.m4b"))
  }

  func testFolderNamesBecomeOnePathComponent() {
    XCTAssertEqual(DownloadTaskInfo.sanitizedFolderName("AC/DC: Live"), "AC-DC- Live")
    XCTAssertEqual(DownloadTaskInfo.sanitizedFolderName("  The Hobbit  "), "The Hobbit")
    XCTAssertEqual(DownloadTaskInfo.sanitizedFolderName(".."), "Download")
    XCTAssertEqual(DownloadTaskInfo.sanitizedFolderName(""), "Download")
  }

  func testFolderNameIsSanitizedOnInit() {
    let info = DownloadTaskInfo(url: "https://example.com/a.mp3", folderName: "Part 1/2", allOrNothing: false)

    XCTAssertEqual(info.folderName, "Part 1-2")
  }
}

final class DownloadFileStoreTests: XCTestCase {
  private var rootURL: URL!
  private var documentsURL: URL!
  private var stagingURL: URL!
  private var store: DownloadFileStore!
  private let fileManager = FileManager.default

  override func setUpWithError() throws {
    rootURL = fileManager.temporaryDirectory.appendingPathComponent("DownloadFileStoreTests-\(UUID().uuidString)")
    documentsURL = rootURL.appendingPathComponent("Documents")
    stagingURL = rootURL.appendingPathComponent("PendingDownloads")
    try fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
    store = DownloadFileStore(documentsURL: documentsURL, stagingURL: stagingURL)
  }

  override func tearDownWithError() throws {
    try? fileManager.removeItem(at: rootURL)
  }

  private func makeDownloadedFile(_ contents: String = "audio") throws -> URL {
    let url = rootURL.appendingPathComponent(UUID().uuidString + ".tmp")
    try Data(contents.utf8).write(to: url)
    return url
  }

  private func folderInfo(_ folderName: String, allOrNothing: Bool) -> DownloadTaskInfo {
    DownloadTaskInfo(url: "https://example.com/\(UUID().uuidString)", folderName: folderName, allOrNothing: allOrNothing)
  }

  private func contents(of url: URL) throws -> [String] {
    try fileManager.contentsOfDirectory(atPath: url.path).sorted()
  }

  func testTopLevelFileGoesStraightToDocuments() throws {
    let info = DownloadTaskInfo(url: "https://example.com/a.m4b", folderName: nil, allOrNothing: false)

    let placed = try store.place(try makeDownloadedFile(), filename: "Foundation.m4b", info: info)

    XCTAssertEqual(placed, documentsURL.appendingPathComponent("Foundation.m4b"))
    XCTAssertTrue(fileManager.fileExists(atPath: placed.path))
  }

  func testFolderFilesWaitInStagingUntilFinalized() throws {
    let info = folderInfo("Foundation", allOrNothing: true)

    try store.place(try makeDownloadedFile(), filename: "01.mp3", info: info)

    XCTAssertEqual(try contents(of: documentsURL), [], "The importer must not see a partial book")
    XCTAssertEqual(try contents(of: stagingURL.appendingPathComponent("Foundation")), ["01.mp3"])
  }

  func testFinalizeMovesTheWholeFolderIntoDocuments() throws {
    let info = folderInfo("Foundation", allOrNothing: true)
    try store.place(try makeDownloadedFile(), filename: "01.mp3", info: info)
    try store.place(try makeDownloadedFile(), filename: "02.mp3", info: info)

    try store.finalizeFolder("Foundation", allOrNothing: true)

    XCTAssertEqual(try contents(of: documentsURL.appendingPathComponent("Foundation")), ["01.mp3", "02.mp3"])
    XCTAssertFalse(fileManager.fileExists(atPath: stagingURL.appendingPathComponent("Foundation").path))
  }

  func testAllOrNothingFolderWithAFailureIsDiscarded() throws {
    let info = folderInfo("Foundation", allOrNothing: true)
    try store.place(try makeDownloadedFile(), filename: "01.mp3", info: info)
    store.markFailed(folderName: "Foundation")

    try store.finalizeFolder("Foundation", allOrNothing: true)

    XCTAssertEqual(try contents(of: documentsURL), [])
    XCTAssertFalse(fileManager.fileExists(atPath: stagingURL.appendingPathComponent("Foundation").path))
  }

  func testOtherFoldersKeepTheirFinishedFilesAfterAFailure() throws {
    let info = folderInfo("Jellyfin picks", allOrNothing: false)
    try store.place(try makeDownloadedFile(), filename: "a.m4b", info: info)
    store.markFailed(folderName: "Jellyfin picks")

    try store.finalizeFolder("Jellyfin picks", allOrNothing: false)

    XCTAssertEqual(try contents(of: documentsURL.appendingPathComponent("Jellyfin picks")), ["a.m4b"])
  }

  func testFolderWithOnlyAFailureLeavesNothingBehind() throws {
    store.markFailed(folderName: "Jellyfin picks")

    try store.finalizeFolder("Jellyfin picks", allOrNothing: false)

    XCTAssertEqual(try contents(of: documentsURL), [])
    XCTAssertFalse(fileManager.fileExists(atPath: stagingURL.appendingPathComponent("Jellyfin picks").path))
  }

  func testFinalizeMergesIntoAnExistingFolder() throws {
    let existing = documentsURL.appendingPathComponent("Foundation")
    try fileManager.createDirectory(at: existing, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: existing.appendingPathComponent("01.mp3"))
    let info = folderInfo("Foundation", allOrNothing: false)
    try store.place(try makeDownloadedFile("new"), filename: "01.mp3", info: info)
    try store.place(try makeDownloadedFile(), filename: "02.mp3", info: info)

    try store.finalizeFolder("Foundation", allOrNothing: false)

    XCTAssertEqual(try contents(of: existing), ["01.mp3", "02.mp3"])
    XCTAssertEqual(try String(contentsOf: existing.appendingPathComponent("01.mp3"), encoding: .utf8), "new")
  }

  func testFinalizeTwiceIsHarmless() throws {
    let info = folderInfo("Foundation", allOrNothing: true)
    try store.place(try makeDownloadedFile(), filename: "01.mp3", info: info)

    try store.finalizeFolder("Foundation", allOrNothing: true)
    XCTAssertNoThrow(try store.finalizeFolder("Foundation", allOrNothing: true))

    XCTAssertEqual(try contents(of: documentsURL.appendingPathComponent("Foundation")), ["01.mp3"])
  }

  func testPlacingOverAnExistingTopLevelFileFails() throws {
    let info = DownloadTaskInfo(url: "https://example.com/a.m4b", folderName: nil, allOrNothing: false)
    try store.place(try makeDownloadedFile(), filename: "Foundation.m4b", info: info)

    XCTAssertThrowsError(try store.place(try makeDownloadedFile(), filename: "Foundation.m4b", info: info))
  }
}

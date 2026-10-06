//
//  AudiobookShelfDownloadPlanTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
import XCTest

/// AudiobookShelf books are downloaded file by file, because the whole-item zip can't resume
/// once the app leaves the foreground. See `AudiobookShelfDownloadPlan`.
final class AudiobookShelfDownloadPlanTests: XCTestCase {
  private let connection = AudiobookShelfConnectionData(
    url: URL(string: "https://mini.example.ts.net/audiobookshelf")!,
    serverName: "mini",
    userID: "u1",
    userName: "nathaniel",
    apiToken: "abs-token",
    customHeaders: ["CF-Access-Client-Id": "client", "Authorization": "Basic should-not-win"]
  )

  private typealias AudioFile = AudiobookShelfAudiobookDetailsData.AudioFileReference

  private func plan(_ audioFiles: [AudioFile], title: String = "Foundation") -> AudiobookShelfDownloadPlan {
    AudiobookShelfConnectionService.downloadPlan(
      itemID: "item-1",
      title: title,
      audioFiles: audioFiles,
      connection: connection
    )
  }

  func testMultiFileBookDownloadsEachFileIntoOneFolder() {
    let plan = plan([AudioFile(ino: "10", filename: "01.mp3"), AudioFile(ino: "11", filename: "02.mp3")])

    XCTAssertEqual(
      plan.requests.map { $0.url?.absoluteString },
      [
        "https://mini.example.ts.net/audiobookshelf/api/items/item-1/file/10/download",
        "https://mini.example.ts.net/audiobookshelf/api/items/item-1/file/11/download",
      ]
    )
    XCTAssertEqual(plan.folderName, "Foundation")
  }

  func testSingleFileBookIsNotWrappedInAFolder() {
    let plan = plan([AudioFile(ino: "10", filename: "Foundation.m4b")])

    XCTAssertEqual(
      plan.requests.map { $0.url?.absoluteString },
      ["https://mini.example.ts.net/audiobookshelf/api/items/item-1/file/10/download"]
    )
    XCTAssertNil(plan.folderName)
  }

  func testWithoutAFileListItFallsBackToTheZip() {
    let plan = plan([])

    XCTAssertEqual(
      plan.requests.map { $0.url?.absoluteString },
      ["https://mini.example.ts.net/audiobookshelf/api/items/item-1/download"]
    )
    XCTAssertNil(plan.folderName)
  }

  func testEveryRequestCarriesTheBearerAndTheCustomHeaders() {
    let plan = plan([AudioFile(ino: "10", filename: "01.mp3"), AudioFile(ino: "11", filename: "02.mp3")])

    for request in plan.requests {
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abs-token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "client")
    }
  }

  func testTheTokenStaysOutOfTheURL() {
    let plan = plan([AudioFile(ino: "10", filename: "01.mp3")])

    XCTAssertFalse(plan.requests[0].url!.absoluteString.contains("abs-token"))
  }

  func testDetailsListAudioFilesInPlaybackOrder() throws {
    let json = """
      {
        "id": "item-1",
        "libraryId": "lib-1",
        "size": 300,
        "libraryFiles": [],
        "media": {
          "metadata": { "title": "Foundation" },
          "audioFiles": [
            { "index": 2, "ino": "11", "duration": 10,
              "metadata": { "filename": "02.mp3", "ext": ".mp3", "path": "/b/02.mp3", "size": 100 } },
            { "index": 1, "ino": "10", "duration": 10,
              "metadata": { "filename": "01.mp3", "ext": ".mp3", "path": "/b/01.mp3", "size": 200 } }
          ]
        }
      }
      """
    let response = try JSONDecoder().decode(AudiobookShelfItemDetailsResponse.self, from: Data(json.utf8))

    let details = AudiobookShelfAudiobookDetailsData(apiResponse: response)

    XCTAssertEqual(details.audioFiles.map(\.ino), ["10", "11"])
  }

  func testPodcastDetailsHaveNoAudioFiles() throws {
    let json = """
      { "id": "pod-1", "libraryId": "lib-2", "libraryFiles": [],
        "media": { "metadata": { "title": "A Podcast" } } }
      """
    let response = try JSONDecoder().decode(AudiobookShelfItemDetailsResponse.self, from: Data(json.utf8))

    XCTAssertEqual(AudiobookShelfAudiobookDetailsData(apiResponse: response).audioFiles, [])
  }
}

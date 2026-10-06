//
//  BPTaskDownloadDelegateTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayerKit
import XCTest

final class BPTaskDownloadDelegateTests: XCTestCase {
  private let url = URL(string: "https://abs.example.com/api/items/1/file/10/download")!

  private func response(status: Int, headers: [String: String]) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
  }

  func testFullResponseUsesContentLength() {
    let response = response(status: 200, headers: ["Content-Length": "1293549848"])

    XCTAssertEqual(BPTaskDownloadDelegate.expectedFileSize(for: response), 1_293_549_848)
  }

  func testResumedResponseUsesTheTotalFromContentRange() {
    /// After a resume, Content-Length covers only the remaining bytes
    let response = response(
      status: 206,
      headers: ["Content-Length": "1145000000", "Content-Range": "bytes 148549848-1293549847/1293549848"]
    )

    XCTAssertEqual(BPTaskDownloadDelegate.expectedFileSize(for: response), 1_293_549_848)
  }

  func testResumedResponseWithUnknownTotalCantBeChecked() {
    let response = response(status: 206, headers: ["Content-Range": "bytes 100-199/*"])

    XCTAssertNil(BPTaskDownloadDelegate.expectedFileSize(for: response))
  }

  func testStreamedResponseWithoutLengthCantBeChecked() {
    /// AudiobookShelf's on-the-fly zip is chunked
    let response = response(status: 200, headers: ["Transfer-Encoding": "chunked"])

    XCTAssertNil(BPTaskDownloadDelegate.expectedFileSize(for: response))
  }

  func testMissingResponseCantBeChecked() {
    XCTAssertNil(BPTaskDownloadDelegate.expectedFileSize(for: nil))
  }
}

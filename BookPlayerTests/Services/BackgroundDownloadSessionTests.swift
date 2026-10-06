//
//  BackgroundDownloadSessionTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import XCTest

/// Drives `BackgroundDownloadSession` through a real `URLSession` and real files on disk. Only
/// the server is stubbed: background sessions don't run `URLProtocol`s, so these use an
/// ephemeral configuration with the same delegate code path.
final class BackgroundDownloadSessionTests: XCTestCase {
  private var rootURL: URL!
  private var documentsURL: URL!
  private var stagingURL: URL!
  private var downloadSession: BackgroundDownloadSession!
  private var events = [BackgroundDownloadSession.Event]()
  private let eventsLock = NSLock()
  private var disposeBag = Set<AnyCancellable>()
  private let fileManager = FileManager.default

  override func setUpWithError() throws {
    rootURL = fileManager.temporaryDirectory.appendingPathComponent("BackgroundDownloadSessionTests-\(UUID().uuidString)")
    documentsURL = rootURL.appendingPathComponent("Documents")
    stagingURL = rootURL.appendingPathComponent("PendingDownloads")
    try fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)

    StubServer.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubServer.self]
    downloadSession = BackgroundDownloadSession(
      configuration: configuration,
      fileStore: DownloadFileStore(documentsURL: documentsURL, stagingURL: stagingURL)
    )
    downloadSession.eventsPublisher
      .sink { [weak self] event in
        guard let self else { return }
        self.eventsLock.lock()
        self.events.append(event)
        self.eventsLock.unlock()
      }
      .store(in: &disposeBag)
  }

  override func tearDownWithError() throws {
    downloadSession.session.invalidateAndCancel()
    disposeBag.removeAll()
    try? fileManager.removeItem(at: rootURL)
  }

  // MARK: - Helpers

  private func start(_ path: String, folderName: String?, allOrNothing: Bool) {
    let url = URL(string: "https://abs.example.com\(path)")!
    let info = DownloadTaskInfo(url: url.absoluteString, folderName: folderName, allOrNothing: allOrNothing)
    let task = downloadSession.session.downloadTask(with: URLRequest(url: url))
    task.taskDescription = info.taskDescription
    task.resume()
  }

  private var recordedEvents: [BackgroundDownloadSession.Event] {
    eventsLock.lock()
    defer { eventsLock.unlock() }
    return events
  }

  private var completedCount: Int {
    recordedEvents.filter { if case .completed = $0 { return true } else { return false } }.count
  }

  private var failedCount: Int {
    recordedEvents.filter { if case .failed = $0 { return true } else { return false } }.count
  }

  private var endedCount: Int {
    recordedEvents.filter {
      switch $0 {
      case .completed, .failed, .cancelled: return true
      case .progress, .resumed: return false
      }
    }.count
  }

  /// Polls, because folders are finalized after `getAllTasks` answers, off the event stream
  private func waitUntil(
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertTrue(condition(), "Timed out", file: file, line: line)
  }

  private func contents(of url: URL) -> [String] {
    ((try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
  }

  // MARK: - Tests

  func testTopLevelFileLandsInDocumentsUnderTheServerFilename() {
    StubServer.respond(to: "/api/items/1/file/10/download", body: "m4b", filename: "Foundation.m4b")

    start("/api/items/1/file/10/download", folderName: nil, allOrNothing: false)

    waitUntil { self.contents(of: self.documentsURL) == ["Foundation.m4b"] }
    XCTAssertEqual(completedCount, 1)
  }

  func testFolderReachesDocumentsOnlyOnceEveryFileIsDone() {
    StubServer.respond(to: "/api/items/1/file/10/download", body: "one", filename: "01.mp3")
    StubServer.respond(to: "/api/items/1/file/11/download", body: "two", filename: "02.mp3")

    start("/api/items/1/file/10/download", folderName: "Foundation", allOrNothing: true)
    start("/api/items/1/file/11/download", folderName: "Foundation", allOrNothing: true)

    let folderURL = documentsURL.appendingPathComponent("Foundation")
    waitUntil { self.contents(of: folderURL) == ["01.mp3", "02.mp3"] }
    XCTAssertEqual(completedCount, 2)
    XCTAssertEqual(contents(of: stagingURL), [])
  }

  func testOneFailedFileDiscardsAnAllOrNothingBook() {
    StubServer.respond(to: "/api/items/1/file/10/download", body: "one", filename: "01.mp3")
    StubServer.respond(to: "/api/items/1/file/11/download", status: 404)

    start("/api/items/1/file/10/download", folderName: "Foundation", allOrNothing: true)
    start("/api/items/1/file/11/download", folderName: "Foundation", allOrNothing: true)

    waitUntil { self.endedCount == 2 && self.contents(of: self.stagingURL).isEmpty }
    XCTAssertEqual(failedCount, 1, "One error for the book, not one per file")
    XCTAssertEqual(contents(of: documentsURL), [], "A book with missing files must not be imported")
  }

  func testOneFailedFileKeepsTheRestOfAnOrdinaryFolder() {
    StubServer.respond(to: "/a.m4b", body: "a", filename: "a.m4b")
    StubServer.respond(to: "/b.m4b", status: 500)

    start("/a.m4b", folderName: "Picks", allOrNothing: false)
    start("/b.m4b", folderName: "Picks", allOrNothing: false)

    waitUntil { self.contents(of: self.documentsURL.appendingPathComponent("Picks")) == ["a.m4b"] }
    XCTAssertEqual(failedCount, 1)
  }

  func testTruncatedFileIsReportedAsAnError() {
    StubServer.respond(
      to: "/api/items/1/file/10/download",
      body: "short",
      filename: "01.mp3",
      headers: ["Content-Length": "500"]
    )

    start("/api/items/1/file/10/download", folderName: nil, allOrNothing: false)

    waitUntil { self.endedCount == 1 }
    XCTAssertEqual(contents(of: documentsURL), [])
    guard case .failed(_, let error) = recordedEvents.last(where: { if case .failed = $0 { true } else { false } }) else {
      return XCTFail("Expected a failure")
    }
    XCTAssertTrue(error is DownloadError || (error as NSError).domain == NSURLErrorDomain)
  }

  // MARK: - Resume decision

  func testResumeDataIsUsedForAnInterruptedTransfer() {
    let error = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorNetworkConnectionLost,
      userInfo: [NSURLSessionDownloadTaskResumeData: Data("resume".utf8)]
    )

    XCTAssertEqual(BackgroundDownloadSession.resumeData(from: error), Data("resume".utf8))
  }

  func testCancelledTransferIsNotResumed() {
    let error = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCancelled,
      userInfo: [NSURLSessionDownloadTaskResumeData: Data("resume".utf8)]
    )

    XCTAssertNil(BackgroundDownloadSession.resumeData(from: error))
  }

  func testTransferWithoutResumeDataIsNotResumed() {
    let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)

    XCTAssertNil(BackgroundDownloadSession.resumeData(from: error))
  }
}

/// Answers requests by path with canned responses
private final class StubServer: URLProtocol {
  struct Response {
    let status: Int
    let headers: [String: String]
    let body: Data
  }

  private static let lock = NSLock()
  private static var responses = [String: Response]()

  static func reset() {
    lock.lock()
    responses = [:]
    lock.unlock()
  }

  static func respond(
    to path: String,
    status: Int = 200,
    body: String = "",
    filename: String? = nil,
    headers: [String: String] = [:]
  ) {
    var allHeaders = ["Content-Length": "\(body.utf8.count)"]
    if let filename {
      allHeaders["Content-Disposition"] = "attachment; filename=\"\(filename)\""
    }
    allHeaders.merge(headers) { _, new in new }

    lock.lock()
    responses[path] = Response(status: status, headers: allHeaders, body: Data(body.utf8))
    lock.unlock()
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    let response = request.url.flatMap { Self.responses[$0.path] }
    Self.lock.unlock()

    guard let response, let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }

    let httpResponse = HTTPURLResponse(
      url: url,
      statusCode: response.status,
      httpVersion: "HTTP/1.1",
      headerFields: response.headers
    )!
    client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: response.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

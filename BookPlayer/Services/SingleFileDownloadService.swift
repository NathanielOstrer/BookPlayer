//
//  DownloadService.swift
//  BookPlayer
//
//  Created by Lysann Tranvouez on 2024-10-29.
//  Copyright © 2024 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine

/// Downloads remote files (URL imports, Jellyfin, AudiobookShelf) into the library.
///
/// Every requested file becomes a task on `BackgroundDownloadSession` right away, instead of
/// waiting in an in-memory queue. The system keeps those tasks going while the app is
/// suspended or killed; a task started while the app is in the background would instead be
/// discretionary, and an in-memory queue would be lost with the process.
final class SingleFileDownloadService: ObservableObject {
  public enum ErrorKind: Error {
    case general
    case network
  }
  public enum Events {
    case starting(url: URL)
    /// Combined progress of every active download (0..1)
    case progress(task: URLSessionTask, progress: Double)
    /// Combined bytes of every active download, sent while any of them has an unknown size
    case bytesWritten(task: URLSessionTask, bytesWritten: Int64)
    case finished(task: URLSessionTask)
    case error(ErrorKind, task: URLSessionTask, underlyingError: Error?)

    /// Frequent updates that are safe to throttle
    var isProgressUpdate: Bool {
      switch self {
      case .progress, .bytesWritten: return true
      case .starting, .finished, .error: return false
      }
    }
  }

  public var eventsPublisher = PassthroughSubject<Events, Never>()

  private let networkClient: NetworkClientProtocol
  private let backgroundSession: BackgroundDownloadSession
  private var disposeBag = Set<AnyCancellable>()

  /// Progress of each active task, keyed by task id. Only touched on the main thread.
  private var activeDownloads = [Int: (written: Int64, expected: Int64)]()

  /// Downloads handed to the session that haven't reported back yet
  public private(set) var activeDownloadCount = 0
  public var isDownloading: Bool { activeDownloadCount > 0 }

  public init(
    networkClient: NetworkClientProtocol,
    backgroundSession: BackgroundDownloadSession = .shared
  ) {
    self.networkClient = networkClient
    self.backgroundSession = backgroundSession

    bindObservers()
    adoptRunningTasks()
  }

  private func sendEvent(_ event: Events) {
    eventsPublisher.send(event)
  }

  public func handleDownload(_ url: URL) {
    handleDownload(URLRequest(url: url))
  }

  public func handleDownload(_ urls: [URL]) {
    handleDownload(urls.map { URLRequest(url: $0) })
  }

  public func handleDownload(_ url: URL, folderName: String) {
    handleDownload(URLRequest(url: url), folderName: folderName)
  }

  public func handleDownload(_ urls: [URL], folderName: String) {
    handleDownload(urls.map { URLRequest(url: $0) }, folderName: folderName)
  }

  public func handleDownload(_ request: URLRequest) {
    handleDownload([request], folderName: nil, allOrNothing: false)
  }

  public func handleDownload(_ requests: [URLRequest]) {
    handleDownload(requests, folderName: nil, allOrNothing: false)
  }

  public func handleDownload(_ request: URLRequest, folderName: String) {
    handleDownload([request], folderName: folderName, allOrNothing: false)
  }

  public func handleDownload(_ requests: [URLRequest], folderName: String) {
    handleDownload(requests, folderName: folderName, allOrNothing: false)
  }

  /// - Parameters:
  ///   - folderName: Folder the files go into inside Documents. With a folder, the files reach
  ///     the library together, once every one of them is done.
  ///   - allOrNothing: Discard the whole folder if one file fails, for the files of one book
  public func handleDownload(_ requests: [URLRequest], folderName: String?, allOrNothing: Bool) {
    Task { @MainActor in
      for request in requests {
        /// Every `handleDownload` overload wraps a known URL, so `request.url` is non-nil.
        /// A nil here would break dedupe (task description collides) — crash early instead.
        let url = request.url!
        let info = DownloadTaskInfo(
          url: url.absoluteString,
          folderName: folderName,
          allOrNothing: allOrNothing && folderName != nil
        )
        sendEvent(.starting(url: url))

        let task = await networkClient.download(
          request: request,
          taskDescription: info.taskDescription,
          session: backgroundSession.session
        )
        track(task)
      }
    }
  }

  /// Picks up tasks started before the app was last killed, so the progress overlay and
  /// `isDownloading` include them
  private func adoptRunningTasks() {
    backgroundSession.session.getAllTasks { [weak self] tasks in
      let running = tasks.filter {
        ($0.state == .running || $0.state == .suspended)
          && DownloadTaskInfo(taskDescription: $0.taskDescription) != nil
      }
      guard !running.isEmpty else { return }

      Task { @MainActor in
        running.forEach { self?.track($0) }
      }
    }
  }

  @MainActor
  private func track(_ task: URLSessionTask) {
    /// A task that already completed has reported back, or will untrack itself shortly
    guard activeDownloads[task.taskIdentifier] == nil, task.state != .completed else { return }

    activeDownloads[task.taskIdentifier] = (written: 0, expected: NSURLSessionTransferSizeUnknown)
    activeDownloadCount = activeDownloads.count
  }

  @MainActor
  private func untrack(_ task: URLSessionTask) {
    activeDownloads[task.taskIdentifier] = nil
    activeDownloadCount = activeDownloads.count
  }

  private func bindObservers() {
    backgroundSession.eventsPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] event in
        MainActor.assumeIsolated {
          self?.handle(event)
        }
      }
      .store(in: &disposeBag)
  }

  @MainActor
  private func handle(_ event: BackgroundDownloadSession.Event) {
    switch event {
    case .progress(let task, let bytesWritten, let bytesExpected):
      /// A resumed download is a new task, so this also starts tracking it
      activeDownloads[task.taskIdentifier] = (written: bytesWritten, expected: bytesExpected)
      activeDownloadCount = activeDownloads.count
      sendCombinedProgress(for: task)
    case .completed(let task):
      untrack(task)
      sendEvent(.finished(task: task))
    case .failed(let task, let error):
      untrack(task)
      sendEvent(.finished(task: task))
      let kind: ErrorKind = (error as NSError).domain == NSCocoaErrorDomain ? .general : .network
      sendEvent(.error(kind, task: task, underlyingError: error))
    case .cancelled(let task):
      untrack(task)
      sendEvent(.finished(task: task))
    case .resumed(let task, let newTask):
      untrack(task)
      track(newTask)
    }
  }

  @MainActor
  private func sendCombinedProgress(for task: URLSessionTask) {
    /// Tasks the system hasn't started yet have no size, and don't count until they start
    let started = activeDownloads.values.filter {
      $0.written > 0 || $0.expected != NSURLSessionTransferSizeUnknown
    }
    let written = started.reduce(Int64(0)) { $0 + $1.written }

    if started.contains(where: { $0.expected == NSURLSessionTransferSizeUnknown }) {
      sendEvent(.bytesWritten(task: task, bytesWritten: written))
    } else {
      let expected = started.reduce(Int64(0)) { $0 + $1.expected }
      guard expected > 0 else { return }
      sendEvent(.progress(task: task, progress: Double(written) / Double(expected)))
    }
  }
}

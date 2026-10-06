//
//  BackgroundDownloadSession.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import Foundation

/// Owns the background `URLSession` used by `SingleFileDownloadService`, and finishes its
/// downloads even when no UI exists.
///
/// The system runs background downloads outside the app. When one finishes while the app is
/// suspended or was killed, iOS launches or wakes the app and calls
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. The events only
/// arrive once a session with the same identifier exists again, and the downloaded file is
/// deleted as soon as the delegate callback returns. So this object is created at launch (or
/// by that app delegate call), and it moves files into place itself instead of waiting for
/// the library screen.
///
/// A process may create only one session per identifier, which is why this is a singleton.
final class BackgroundDownloadSession: BPLogger {
  /// Unchanged from earlier builds, so tasks they started still reconnect after an update
  static let identifier = "SingleFileDownloadService"
  /// How many times one file resumes from resume data before its error is reported
  static let maxResumeAttempts = 3

  static let shared = BackgroundDownloadSession(
    configuration: .background(withIdentifier: identifier)
  )

  enum Event {
    case progress(task: URLSessionDownloadTask, bytesWritten: Int64, bytesExpected: Int64)
    /// The task produced its file. It is in Documents, or staged until its folder is done.
    case completed(task: URLSessionTask)
    case failed(task: URLSessionTask, error: Error)
    /// Stopped because another file of the same all-or-nothing folder failed
    case cancelled(task: URLSessionTask)
    /// An interrupted task continues as `newTask`, from where it stopped
    case resumed(task: URLSessionTask, newTask: URLSessionTask)
  }

  /// Delivered on the delegate queue, not the main thread
  let eventsPublisher = PassthroughSubject<Event, Never>()

  let session: URLSession
  let fileStore: DownloadFileStore

  /// Handed over by the app delegate. Call it once every queued event is handled, so iOS can
  /// take a fresh app snapshot and suspend the app again.
  var backgroundEventsCompletionHandler: (() -> Void)? {
    get { stateQueue.sync { _backgroundEventsCompletionHandler } }
    set { stateQueue.sync { _backgroundEventsCompletionHandler = newValue } }
  }

  private let delegate = BPTaskDownloadDelegate()
  private let delegateQueue: OperationQueue = {
    let queue = OperationQueue()
    /// Serial, so the completion of two files of one folder can't interleave
    queue.maxConcurrentOperationCount = 1
    queue.name = "BackgroundDownloadSession.delegate"
    return queue
  }()
  private let stateQueue = DispatchQueue(label: "BackgroundDownloadSession.state")
  /// Folder checks that are still waiting on `getAllTasks`
  private let pendingWork = DispatchGroup()

  private var _backgroundEventsCompletionHandler: (() -> Void)?
  /// Errors found when the file arrived, reported once the task completes. Keyed by task id.
  private var pendingFailures = [Int: Error]()
  /// Resume attempts per task description, for this process
  private var resumeAttempts = [String: Int]()
  /// Tasks cancelled because a sibling in their all-or-nothing folder failed
  private var cancelledSiblingIDs = Set<Int>()

  init(configuration: URLSessionConfiguration, fileStore: DownloadFileStore = DownloadFileStore()) {
    self.fileStore = fileStore
    self.session = URLSession(
      configuration: configuration,
      delegate: delegate,
      delegateQueue: delegateQueue
    )
    bindDelegate()
  }

  private func bindDelegate() {
    delegate.downloadBytesUpdated = { [weak self] task, bytesWritten, bytesExpected in
      self?.eventsPublisher.send(
        .progress(task: task, bytesWritten: bytesWritten, bytesExpected: bytesExpected)
      )
    }

    delegate.didFinishDownloadingTask = { [weak self] task, fileURL, error in
      guard let self else { return }

      if let fileURL {
        self.handleFileArrived(task, fileURL: fileURL, error: error)
      } else {
        self.handleTaskCompleted(task, error: error)
      }
    }

    delegate.didFinishEventsForBackgroundSession = { [weak self] in
      guard let self else { return }

      self.pendingWork.notify(queue: .main) {
        let handler = self.backgroundEventsCompletionHandler
        self.backgroundEventsCompletionHandler = nil
        handler?()
      }
    }
  }

  /// Runs inside `urlSession(_:downloadTask:didFinishDownloadingTo:)`. The file must be moved
  /// before this returns.
  private func handleFileArrived(_ task: URLSessionTask, fileURL: URL, error: Error?) {
    if let error {
      setPendingFailure(error, for: task)
      return
    }

    guard let info = DownloadTaskInfo(taskDescription: task.taskDescription) else {
      Self.logger.warning("Download finished without task info, dropping it")
      return
    }

    let filename =
      task.response?.suggestedFilename
      ?? task.originalRequest?.url?.lastPathComponent
      ?? fileURL.lastPathComponent

    do {
      try fileStore.place(fileURL, filename: filename, info: info)
    } catch {
      setPendingFailure(error, for: task)
    }
  }

  /// Runs inside `urlSession(_:task:didCompleteWithError:)`, which fires for every task,
  /// whether it succeeded or not
  private func handleTaskCompleted(_ task: URLSessionTask, error: Error?) {
    let pendingFailure = stateQueue.sync { pendingFailures.removeValue(forKey: task.taskIdentifier) }
    let info = DownloadTaskInfo(taskDescription: task.taskDescription)

    if stateQueue.sync(execute: { cancelledSiblingIDs.remove(task.taskIdentifier) }) != nil {
      eventsPublisher.send(.cancelled(task: task))
      finalizeFolderIfDone(info, completedTask: task)
      return
    }

    guard let error = error ?? pendingFailure else {
      eventsPublisher.send(.completed(task: task))
      finalizeFolderIfDone(info, completedTask: task)
      return
    }

    if resumeIfPossible(task, error: error) {
      return
    }

    Self.logger.warning("Download failed: \(error.localizedDescription)")
    if let folderName = info?.folderName {
      fileStore.markFailed(folderName: folderName)
    }
    eventsPublisher.send(.failed(task: task, error: error))

    if let info, info.allOrNothing {
      cancelSiblings(of: task, info: info)
    } else {
      finalizeFolderIfDone(info, completedTask: task)
    }
  }

  /// The folder will be discarded anyway, so stop downloading the rest of it. The last
  /// sibling to report its cancellation finalizes (discards) the folder.
  private func cancelSiblings(of failedTask: URLSessionTask, info: DownloadTaskInfo) {
    pendingWork.enter()
    session.getAllTasks { [weak self, pendingWork] tasks in
      defer { pendingWork.leave() }
      guard let self else { return }

      let siblings = tasks.filter { task in
        task.taskIdentifier != failedTask.taskIdentifier
          && (task.state == .running || task.state == .suspended)
          && DownloadTaskInfo(taskDescription: task.taskDescription)?.folderName == info.folderName
      }

      guard !siblings.isEmpty else {
        self.finalizeFolderIfDone(info, completedTask: failedTask)
        return
      }

      self.stateQueue.sync {
        siblings.forEach { self.cancelledSiblingIDs.insert($0.taskIdentifier) }
      }
      siblings.forEach { $0.cancel() }
    }
  }

  /// Continues an interrupted download from where it stopped, when the server allows it
  /// (it answered with an `ETag` or `Last-Modified` and accepts `Range`)
  private func resumeIfPossible(_ task: URLSessionTask, error: Error) -> Bool {
    guard
      let taskDescription = task.taskDescription,
      let resumeData = Self.resumeData(from: error)
    else { return false }

    let attempts = stateQueue.sync { () -> Int in
      let attempts = (resumeAttempts[taskDescription] ?? 0) + 1
      resumeAttempts[taskDescription] = attempts
      return attempts
    }

    guard attempts <= Self.maxResumeAttempts else {
      stateQueue.sync { resumeAttempts[taskDescription] = nil }
      return false
    }

    Self.logger.info("Resuming interrupted download, attempt \(attempts)")
    let resumedTask = session.downloadTask(withResumeData: resumeData)
    resumedTask.taskDescription = taskDescription
    resumedTask.resume()
    eventsPublisher.send(.resumed(task: task, newTask: resumedTask))
    return true
  }

  /// Resume data from a failed task. A cancelled task also carries it, but the user asked
  /// for that, so it doesn't count.
  static func resumeData(from error: Error) -> Data? {
    let nsError = error as NSError
    guard
      nsError.domain == NSURLErrorDomain,
      nsError.code != NSURLErrorCancelled
    else { return nil }

    return nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
  }

  /// Moves a staged folder into Documents once its last task is done. Every task of a folder
  /// calls this as it completes; only the last one finds nothing else running.
  private func finalizeFolderIfDone(_ info: DownloadTaskInfo?, completedTask: URLSessionTask) {
    guard let info, let folderName = info.folderName else { return }

    pendingWork.enter()
    session.getAllTasks { [weak self, pendingWork] tasks in
      defer { pendingWork.leave() }
      guard let self else { return }

      let othersRunning = tasks.contains { task in
        task.taskIdentifier != completedTask.taskIdentifier
          && (task.state == .running || task.state == .suspended)
          && DownloadTaskInfo(taskDescription: task.taskDescription)?.folderName == folderName
      }
      guard !othersRunning else { return }

      self.stateQueue.sync {
        do {
          try self.fileStore.finalizeFolder(folderName, allOrNothing: info.allOrNothing)
        } catch {
          Self.logger.error("Couldn't move downloaded folder into the library: \(error.localizedDescription)")
        }
      }
    }
  }

  private func setPendingFailure(_ error: Error, for task: URLSessionTask) {
    stateQueue.sync { pendingFailures[task.taskIdentifier] = error }
  }
}

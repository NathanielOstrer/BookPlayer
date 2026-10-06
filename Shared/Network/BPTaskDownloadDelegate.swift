//
//  BPTaskDownloadDelegate.swift
//  BookPlayer
//
//  Created by gianni.carlo on 18/2/23.
//  Copyright © 2023 BookPlayer LLC. All rights reserved.
//

import Foundation

/// Errors raised when a download finishes but the resulting file can't be trusted.
/// The associated values carry diagnostic detail (logged at `.warning`); the
/// user-facing `errorDescription` is a single localized, non-technical message.
public enum DownloadError: LocalizedError {
  /// The transfer finished without a network error, but fewer bytes were written
  /// than the server's `Content-Length`, i.e. a truncated/botched file.
  case incompleteDownload(received: Int64, expected: Int64)
  /// The downloaded file's real audio duration is meaningfully shorter than the
  /// duration we expected from the sync metadata.
  case durationMismatch(expected: Double, actual: Double)
  /// The duration couldn't be read from the downloaded file at all, despite a
  /// known-good synced duration — a strong truncation/corruption signal.
  case durationUnreadable

  public var errorDescription: String? {
    return "download_incomplete_error".localized
  }
}

public class BPTaskDownloadDelegate: NSObject, URLSessionDownloadDelegate {
  /// Callback triggered when the download task is finished
  public var didFinishDownloadingTask: ((URLSessionTask, URL?, Error?) -> Void)?
  /// Callback triggered when there's an update on the download progress
  public var downloadProgressUpdated: ((URLSessionDownloadTask, Double) -> Void)?
  /// Callback triggered when the total size of the download is unknown,
  /// and we can't compute a progress percentage
  public var downloadBytesWrittenUpdated: ((URLSessionDownloadTask, Int64) -> Void)?
  /// Callback triggered on every progress update with the raw totals: bytes written so far
  /// and bytes expected (`NSURLSessionTransferSizeUnknown` when the size is unknown). For a
  /// resumed download both include the bytes written before the resume.
  public var downloadBytesUpdated: ((URLSessionDownloadTask, Int64, Int64) -> Void)?
  /// Callback triggered when a background session has delivered every event it queued
  /// while the app was suspended or not running
  public var didFinishEventsForBackgroundSession: (() -> Void)?
  /// Delegate callback when download finishes
  public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    didFinishDownloadingTask?(
      downloadTask,
      location,
      parseErrorFromTask(downloadTask) ?? verifyDownloadIsComplete(downloadTask, fileURL: location)
    )
  }

  public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    didFinishEventsForBackgroundSession?()
  }

  /// Note: this gets called even if there's no error
  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    let error = error ?? parseErrorFromTask(task)
    didFinishDownloadingTask?(task, nil, error)
  }

  /// Delegate callback when there's a progress update for the ongoing download
  public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    downloadBytesUpdated?(downloadTask, totalBytesWritten, totalBytesExpectedToWrite)

    let calculatedProgress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)

    if totalBytesExpectedToWrite == -1 {
      downloadBytesWrittenUpdated?(downloadTask, totalBytesWritten)
    } else {
      downloadProgressUpdated?(downloadTask, Double(calculatedProgress))
    }
  }

  /// Verifies the bytes written to disk match the size the server reported. Background
  /// downloads can finish "successfully" with a truncated body (interrupted transfer, early
  /// connection close) and `URLSession` won't flag it, so we treat a short file as an error
  /// instead of accepting it.
  ///
  /// The file on disk is checked rather than the task's byte counters, because a task
  /// resumed from resume data only counts the bytes of its own `206` response.
  private func verifyDownloadIsComplete(_ task: URLSessionTask, fileURL: URL) -> Error? {
    /// No usable size from the server (no `Content-Length`, e.g. a streamed zip):
    /// we can't validate it, so don't block the download.
    guard let expectedBytes = Self.expectedFileSize(for: task.response) else { return nil }

    let receivedBytes =
      (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
      ?? task.countOfBytesReceived
    guard receivedBytes >= expectedBytes else {
      return DownloadError.incompleteDownload(received: receivedBytes, expected: expectedBytes)
    }

    return nil
  }

  /// The full size of the file a response describes. For a `206 Partial Content` (a resumed
  /// download) that's the total after the slash in `Content-Range: bytes 100-199/1000`,
  /// because `Content-Length` only covers the remaining part.
  static func expectedFileSize(for response: URLResponse?) -> Int64? {
    guard let response else { return nil }

    if let http = response as? HTTPURLResponse,
       http.statusCode == 206 {
      guard
        let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
        let total = contentRange.split(separator: "/").last.flatMap({ Int64($0) })
      else {
        return nil
      }
      return total
    }

    let expected = response.expectedContentLength
    return expected == NSURLSessionTransferSizeUnknown ? nil : expected
  }

  private func parseErrorFromTask(_ task: URLSessionTask) -> Error? {
    guard
      let response = task.response as? HTTPURLResponse,
      response.statusCode >= 400
    else {
      return nil
    }

    let errorCode = URLError.Code(rawValue: response.statusCode)
    return URLError(errorCode)
  }
}

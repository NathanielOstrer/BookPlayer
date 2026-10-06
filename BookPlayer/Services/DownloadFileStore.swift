//
//  DownloadFileStore.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation

/// What a single-file download task needs to finish its job, stored in the task's
/// `taskDescription`. The background session persists that string with the task, so this
/// survives the app being suspended, killed and relaunched by the system.
struct DownloadTaskInfo: Codable, Equatable {
  static let descriptionPrefix = "SingleFileDownload-"

  /// The remote URL, so two requests for the same file share a description (dedupe)
  let url: String
  /// Folder the file goes into inside Documents. `nil` puts it at the top level.
  let folderName: String?
  /// When `true`, one failed file discards the whole folder instead of importing a book
  /// with missing parts
  let allOrNothing: Bool

  init(url: String, folderName: String?, allOrNothing: Bool) {
    self.url = url
    self.folderName = folderName.map(Self.sanitizedFolderName)
    self.allOrNothing = allOrNothing
  }

  var taskDescription: String {
    /// A file that goes to the top level keeps the original description format, so tasks
    /// started by older builds still dedupe against new requests
    guard folderName != nil || allOrNothing else {
      return Self.descriptionPrefix + url
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    // swiftlint:disable:next force_try
    let data = try! encoder.encode(self)
    return Self.descriptionPrefix + String(decoding: data, as: UTF8.self)
  }

  /// Reads a description written by `taskDescription`, or by builds that stored only the URL
  init?(taskDescription: String?) {
    guard
      let taskDescription,
      taskDescription.hasPrefix(Self.descriptionPrefix)
    else { return nil }

    let payload = String(taskDescription.dropFirst(Self.descriptionPrefix.count))

    if let data = payload.data(using: .utf8),
       let info = try? JSONDecoder().decode(DownloadTaskInfo.self, from: data) {
      self = info
    } else {
      self = DownloadTaskInfo(url: payload, folderName: nil, allOrNothing: false)
    }
  }

  /// A folder name that is one valid path component
  static func sanitizedFolderName(_ name: String) -> String {
    let cleaned = name
      .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
      .joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))

    return cleaned.isEmpty ? "Download" : cleaned
  }
}

/// Puts finished downloads where the importer will find them.
///
/// Files that belong to a folder wait in a staging folder outside Documents until every file
/// of that folder is done. Documents is watched by the importer, so moving a folder there file
/// by file would let an import start on a half-downloaded book.
final class DownloadFileStore {
  /// Marker left in a staging folder when one of its files failed
  static let failureMarkerName = ".download-failed"

  let documentsURL: URL
  let stagingURL: URL
  private let fileManager: FileManager

  init(
    documentsURL: URL = DataManager.getDocumentsFolderURL(),
    stagingURL: URL = DownloadFileStore.defaultStagingURL,
    fileManager: FileManager = .default
  ) {
    self.documentsURL = documentsURL
    self.stagingURL = stagingURL
    self.fileManager = fileManager
  }

  static var defaultStagingURL: URL {
    DataManager.getApplicationSupportFolderURL()
      .appendingPathComponent("PendingDownloads", isDirectory: true)
  }

  /// Moves a downloaded file out of the session's temporary location. Must be called before
  /// the delegate callback that handed over `fileURL` returns, because the system deletes it then.
  /// - Returns: the file's new location
  @discardableResult
  func place(_ fileURL: URL, filename: String, info: DownloadTaskInfo) throws -> URL {
    let folderURL: URL
    if let folderName = info.folderName {
      folderURL = stagingURL.appendingPathComponent(folderName, isDirectory: true)
      try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
    } else {
      folderURL = documentsURL
    }

    let destinationURL = folderURL.appendingPathComponent(filename)
    try fileManager.moveItem(at: fileURL, to: destinationURL)
    return destinationURL
  }

  /// Records that a file of `folderName` failed, so `finalizeFolder` knows the folder is incomplete
  func markFailed(folderName: String) {
    let folderURL = stagingURL.appendingPathComponent(folderName, isDirectory: true)
    try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
    fileManager.createFile(
      atPath: folderURL.appendingPathComponent(Self.failureMarkerName).path,
      contents: nil
    )
  }

  /// Call once no task for `folderName` is left running. Moves the staged files into
  /// Documents, or deletes them when the folder is all-or-nothing and a file failed.
  /// Safe to call more than once.
  func finalizeFolder(_ folderName: String, allOrNothing: Bool) throws {
    let stagedFolderURL = stagingURL.appendingPathComponent(folderName, isDirectory: true)
    guard fileManager.fileExists(atPath: stagedFolderURL.path) else { return }

    let markerURL = stagedFolderURL.appendingPathComponent(Self.failureMarkerName)
    let hasFailure = fileManager.fileExists(atPath: markerURL.path)

    if hasFailure && allOrNothing {
      try fileManager.removeItem(at: stagedFolderURL)
      return
    }

    if hasFailure {
      try fileManager.removeItem(at: markerURL)
    }

    let files = try fileManager.contentsOfDirectory(
      at: stagedFolderURL,
      includingPropertiesForKeys: nil
    )

    guard !files.isEmpty else {
      try fileManager.removeItem(at: stagedFolderURL)
      return
    }

    let destinationURL = documentsURL.appendingPathComponent(folderName, isDirectory: true)

    if !fileManager.fileExists(atPath: destinationURL.path) {
      /// One move, so the importer sees the folder appear complete
      try fileManager.moveItem(at: stagedFolderURL, to: destinationURL)
      return
    }

    for file in files {
      let target = destinationURL.appendingPathComponent(file.lastPathComponent)
      if fileManager.fileExists(atPath: target.path) {
        try fileManager.removeItem(at: target)
      }
      try fileManager.moveItem(at: file, to: target)
    }
    try fileManager.removeItem(at: stagedFolderURL)
  }
}

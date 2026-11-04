import Foundation

/// Writes playback health to a file the host can pull.
///
/// The device offers no usable console relay over SSH, and `idevicesyslog` needs
/// its own device channel. The app data container, however, can be copied with
/// `xcrun devicectl device copy from`, so measurement data goes there.
///
/// Bounded on every axis: only in a diagnostics build, at most one sample per
/// second, at most a few hundred lines, no URLs, no headers, no tokens. When the
/// session stops, writing stops.
final class PlaybackDiagnostics {
  #if PILIPLUS_DIAGNOSTICS
  static let shared = PlaybackDiagnostics()
  #else
  static let shared = PlaybackDiagnostics()
  #endif

  private let queue = DispatchQueue(label: "pilipilus.diagnostics")
  private var handle: FileHandle?
  private var lines = 0
  private var lastWrite: CFTimeInterval = 0
  private let limit = 400

  static var fileURL: URL {
    // A separate file from the Dart-side log: the native side opens lazily (the
    // first stage may precede readyToPlay), and sharing one file would let a
    // later begin() truncate the lines that explain why it never got there.
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return dir.appendingPathComponent("playback_native_diag.log")
  }

  /// Whether anything will be written. False in a shipping build.
  static var isEnabled: Bool {
    #if PILIPLUS_DIAGNOSTICS
    return true
    #else
    return false
    #endif
  }

  /// Starts (or restarts) the log for a session. Truncates, so each run is
  /// self-contained and the host never has to diff two sessions.
  func begin(sessionId: String) {
    guard PlaybackDiagnostics.isEnabled else { return }
    queue.async {
      // Truncate once per session, then keep the handle: a stage recorded before
      // readyToPlay must land in the same file, and re-opening would erase it.
      let url = PlaybackDiagnostics.fileURL
      FileManager.default.createFile(atPath: url.path, contents: nil)
      try? self.handle?.close()
      self.handle = try? FileHandle(forWritingTo: url)
      self.lines = 0
      self.lastWrite = 0
      self.writeLocked("# session \(sessionId.prefix(24))")
    }
  }

  /// Opens the log if it is not open yet.
  ///
  /// Stage records arrive before the item is ready, so they cannot wait for
  /// begin(); without this they were all discarded and a session that never
  /// became ready produced no evidence at all.
  private func ensureOpenLocked() {
    guard handle == nil, lines < limit else { return }
    let url = PlaybackDiagnostics.fileURL
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    handle = try? FileHandle(forWritingTo: url)
    if let end = try? handle?.seekToEnd() { _ = end }
  }

  /// Records one sample, rate limited. Non-blocking: the caller is on the main
  /// thread and must not be held up by disk IO.
  func sample(_ fields: [String: Any]) {
    guard PlaybackDiagnostics.isEnabled else { return }
    let now = CACurrentMediaTime()
    queue.async {
      guard self.lines < self.limit else { return }
      // Milestones (any record carrying `stage` or `reason`) bypass the rate
      // limit: they are the lines that explain a failure, and dropping them is
      // how "still loading" stayed undiagnosable.
      let isMilestone = fields["stage"] != nil || fields["reason"] != nil
      if !isMilestone {
        guard now - self.lastWrite >= 1.0 || self.lines == 0 else { return }
      }
      self.lastWrite = now
      let body = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }
      self.writeLocked(body.joined(separator: " "))
    }
  }

  /// Stops writing. Called from stop() so a dead session leaves no busy writer.
  func end() {
    queue.async {
      try? self.handle?.close()
      self.handle = nil
    }
  }

  private func writeLocked(_ line: String) {
    ensureOpenLocked()
    guard let handle, lines < limit else { return }
    lines += 1
    let stamped = String(format: "%.2f ", CACurrentMediaTime()) + line + "\n"
    if let data = stamped.data(using: .utf8) {
      try? handle.write(contentsOf: data)
    }
  }
}

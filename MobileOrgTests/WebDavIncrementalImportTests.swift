//
//  WebDavIncrementalImportTests.swift
//  MobileOrg
//
//  Proof-run tests for incremental import of changed Org files
//  (GPL-2.0, like the rest of the project).
//
//  Two classes live here:
//
//  - SyncTimingCaptureTests: the proof run's timing capture. Syncs against
//    the 36-node peter profile and the 136-node encrypted legacy profile,
//    printing wall-clock sync time and the import-step share (SyncManager's
//    import-seconds accumulator) as greppable TIMING lines. No performance
//    thresholds — the proof run records numbers, it does not invent targets.
//    Runs in the test-webdav CI lane (fixture required); skipped in the unit
//    lane, which does not start the fixture.
//
//  - WebDavIncrementalImportTests: the incremental-import behavior pins
//    (node identity, rename cascade, reorder-as-move, subtree removal,
//    corrupt-download safety). These belong to the incremental-import change.
//

import XCTest
import CoreData

@testable import MobileOrg

// MARK: - Timing capture (proof-run record)

final class SyncTimingCaptureTests: WebDavSyncTestCase {

  /// Print one greppable TIMING line. ci.yml extracts these from the raw
  /// xcodebuild log into the job summary, so both green and red runs carry
  /// the numbers the follow-on priority call needs.
  private func reportTiming(profile: String, phase: String, run: Int,
                            syncSeconds: TimeInterval, importSeconds: Double) {
    let sync = String(format: "%.3f", syncSeconds)
    let imp = String(format: "%.3f", importSeconds)
    print("TIMING profile=\(profile) phase=\(phase) run=\(run) syncSeconds=\(sync) importSeconds=\(imp)")
  }

  /// The capture plan: reset the profile, time the cold whole-tree import,
  /// then stage a single-file change three times (the way Emacs would push
  /// small deltas) and time each changed-file sync.
  private func captureTimings(profile: String, password: String, target: String,
                              encrypted: Bool) throws {
    let manifest = try goldenManifest(profile: profile)
    _ = try resetFixture(profile: profile)

    // Cold sync: empty store, every staged file imports.
    SyncManager.resetImportSeconds()
    let coldStart = Date()
    syncAndWait()
    let coldSync = -coldStart.timeIntervalSinceNow
    let coldImport = SyncManager.totalImportSeconds()
    reportTiming(profile: profile, phase: "cold", run: 0,
                 syncSeconds: coldSync, importSeconds: coldImport)
    assertNodeCounts(match: manifest)

    // Changed-file syncs: one staged file grows by one heading per sync.
    for i in 1...3 {
      var contents = try fetchFixtureFile(target)
      if encrypted {
        // The legacy profile serves ciphertext; stage the mutation the way
        // the app's own encryption path would produce it.
        guard let plain = contents.aes256Decrypt(withKey: password), plain.count > 0 else {
          XCTFail("could not decrypt \(target) with the profile password")
          return
        }
        var text = String(decoding: plain, as: UTF8.self)
        text += "* Timing probe \(i)\n"
        contents = Data(text.utf8).aes256Encrypt(withKey: password)
      } else {
        contents.append(Data("* Timing probe \(i)\n".utf8))
      }
      try updateFixtureFile(target, contents: contents)

      SyncManager.resetImportSeconds()
      let start = Date()
      syncAndWait()
      let sync = -start.timeIntervalSinceNow
      let importSeconds = SyncManager.totalImportSeconds()
      reportTiming(profile: profile, phase: "changed", run: i,
                   syncSeconds: sync, importSeconds: importSeconds)

      // Sanity only: the import must actually have happened (one new node),
      // or the numbers describe a no-op rather than an import.
      let expected = manifest.files[target]!.count + i
      XCTAssertEqual(try nodeCount(inFile: target), expected,
                     "\(target) node count after changed-file sync \(i)")
    }
  }

  func testCapturePeterProfileTimings() throws {
    try captureTimings(profile: "peter", password: "", target: "scratchpad.org.txt",
                       encrypted: false)
  }

  func testCaptureLegacyProfileTimings() throws {
    try captureTimings(profile: "legacy", password: "SchnuddelHuddel", target: "sample.org",
                       encrypted: true)
  }
}

// MARK: - Incremental import behavior pins

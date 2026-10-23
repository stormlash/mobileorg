//
//  WebDavTests.swift
//  MobileOrgTests
//
//  Legacy-profile sync tests, retained for whole-import and encryption-path
//  coverage (GPL-2.0, like the rest of the project).
//
//  Deflaked for the regression harness:
//  * Each test resets the tinydav fixture to its pristine legacy profile and
//    starts from a fresh in-memory store (WebDavSyncTestCase), so tests are
//    order-independent — the old suite relied on testSyncChangesOnMobile
//    running before testSyncChangesOnMobileReverse and sharing its mutated
//    server state.
//  * Fixed dispatch-after sleeps are gone; every sync waits on the real
//    SyncComplete notification.
//  * The magic 136-node total is asserted per file from the committed
//    golden manifest instead of one coupled total.
//
//  The legacy fixture is encrypted (password "SchnuddelHuddel"; the app
//  decrypts every org file when a password is configured), which is why this
//  profile survives: it exercises the app's edits-file encryption path end
//  to end.

import XCTest
import CoreData

@testable import MobileOrg

final class WebDavTests: WebDavSyncTestCase {

  override func setUp() {
    super.setUp()
    configureSyncTest(encryptionPassword: "SchnuddelHuddel")
  }

  func testWebDAVSync() throws {
    // Golden import of the frozen legacy fixture: per-file counts from the
    // committed manifest (the old single 136 total is derivable from them,
    // without coupling every future fixture edit to one magic number).
    let manifest = try goldenManifest(profile: "legacy")
    _ = try resetFixture(profile: "legacy")

    syncAndWait()

    assertNodeCounts(match: manifest)

    // The frozen legacy edits file is encrypted but empty — decrypting it
    // must succeed and import zero notes (the decryption path runs, there
    // is simply nothing in it).
    let notes = try XCTUnwrap(try moc?.fetch(NSFetchRequest<Note>(entityName: "Note")))
    XCTAssertEqual(notes.count, 0)
  }

  func testSyncChangesOnMobile() throws {
    // Tag a parsed node, sync, and verify the round trip: exactly one
    // edits-file upload, and the tag still applied after re-import.
    let manifest = try goldenManifest(profile: "legacy")
    _ = try resetFixture(profile: "legacy")

    syncAndWait()
    assertNodeCounts(match: manifest)

    let node = try fetchSingleNode(heading: "Seamless integration of Cloud services")
    let tagEditor = TagEditController(node: node)
    tagEditor?.recentTagString = "Test456"
    tagEditor?.commitNewTag()
    Save()
    XCTAssertEqual(node.tags, ":Test456:")

    let cutoff = try latestSequence(after: 0)
    syncAndWait()

    // The sync may have re-downloaded and re-imported staged files, which
    // deletes and recreates nodes; assert on a fresh fetch, never on the
    // pre-sync reference (a deleted object reads back as nil properties).
    let syncedNode = try fetchSingleNode(heading: "Seamless integration of Cloud services")

    let window = try fixtureRequests(since: cutoff)
    XCTAssertEqual(window.filter { $0.method == "PUT" && $0.path == "/mobileorg.org" }.count, 1,
                   "the tag edit must upload exactly one edits-file PUT (saw \(window))")
    XCTAssertEqual(syncedNode.tags, ":Test456:")
  }

  func testSyncChangesOnMobileReverse() throws {
    // Applying then clearing a tag, each with its own sync, starting from
    // pristine fixture state — no dependence on another test's leftovers.
    let manifest = try goldenManifest(profile: "legacy")
    _ = try resetFixture(profile: "legacy")

    syncAndWait()
    assertNodeCounts(match: manifest)

    let node = try fetchSingleNode(heading: "Seamless integration of Cloud services")
    let tagEditor = TagEditController(node: node)
    tagEditor?.recentTagString = "Test456"
    tagEditor?.commitNewTag()
    Save()
    syncAndWait()
    XCTAssertEqual(node.tags, ":Test456:")

    let removeEditor = TagEditController(node: node)
    removeEditor?.recentTagString = ""
    removeEditor?.commitNewTag()
    Save()
    XCTAssertEqual(node.tags, "::")

    let cutoff = try latestSequence(after: 0)
    syncAndWait()

    // Fresh fetch: the removal sync may re-import the file holding the node.
    let syncedNode = try fetchSingleNode(heading: "Seamless integration of Cloud services")

    let window = try fixtureRequests(since: cutoff)
    XCTAssertEqual(window.filter { $0.method == "PUT" && $0.path == "/mobileorg.org" }.count, 1,
                   "the tag removal must upload exactly one edits-file PUT (saw \(window))")
    XCTAssertEqual(syncedNode.tags, "::")
  }
}

//
//  WebDavIncrementalImportTests.swift
//  MobileOrg
//
//  Proof-run tests for incremental import of changed Org files
//  (GPL-2.0, like the rest of the project).
//
//  Three classes live here:
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
//    corrupt-download safety). Fixture-based; same lane restriction.
//
//  - OrgShadowParityTests: pins parseToShadow to the untouched parse: on the
//    bundled Org resources. Fixture-free; runs in the unit lane.
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
        // the app's own encryption path would produce it. Swift does not
        // bridge Data implicitly for arbitrary NSData category members, so
        // cast through NSData explicitly.
        guard let plainNS = (contents as NSData).aes256Decrypt(withKey: password),
              plainNS.count > 0 else {
          XCTFail("could not decrypt \(target) with the profile password")
          return
        }
        var text = String(decoding: plainNS as Data, as: UTF8.self)
        text += "* Timing probe \(i)\n"
        guard let cipherNS = (Data(text.utf8) as NSData).aes256Encrypt(withKey: password) else {
          XCTFail("could not re-encrypt \(target) with the profile password")
          return
        }
        contents = cipherNS as Data
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
    configureSyncTest(encryptionPassword: "")
    try captureTimings(profile: "peter", password: "", target: "scratchpad.org.txt",
                       encrypted: false)
  }

  func testCaptureLegacyProfileTimings() throws {
    configureSyncTest(encryptionPassword: "SchnuddelHuddel")
    try captureTimings(profile: "legacy", password: "SchnuddelHuddel", target: "sample.org",
                       encrypted: true)
  }
}

// MARK: - Incremental import behavior pins

final class WebDavIncrementalImportTests: WebDavSyncTestCase {

  override func setUp() {
    super.setUp()
    configureSyncTest(encryptionPassword: "")

    // Same steady-state keyword registration as the contract suite: the
    // fixture's index.org registers these too, but checksums.dat order can
    // parse home.org.txt before index.org.
    Settings.instance().resetPrimaryTagsAndTodoStates()
    let todoStates = NSMutableArray(array: ["NEXT", "TODO", "WAITING", "SOMEDAY"])
    let doneStates = NSMutableArray(array: ["DONE", "CANCELLED"])
    Settings.instance().addTodoStateGroup(NSMutableArray(array: [todoStates, doneStates]))
  }

  private struct IdentitySnapshot {
    let objectURI: String
    let nodeId: String
    let outlinePath: String
  }

  /// What a node's identity means here: the Core Data object ID (stable
  /// within a store across saves), the stored :ID:, and the outline path the
  /// fetch index holds.
  private func snapshotIdentity(_ headings: [String]) throws -> [String: IdentitySnapshot] {
    var snapshot: [String: IdentitySnapshot] = [:]
    for heading in headings {
      let node = try fetchSingleNode(heading: heading)
      snapshot[heading] = IdentitySnapshot(
        objectURI: node.objectID.uriRepresentation().absoluteString,
        nodeId: node.nodeId ?? "",
        outlinePath: node.outlinePath ?? "")
    }
    return snapshot
  }

  private func assertIdentityUnchanged(_ headings: [String],
                                       before: [String: IdentitySnapshot],
                                       after: [String: IdentitySnapshot],
                                       file: StaticString = #filePath, line: UInt = #line) {
    for heading in headings {
      XCTAssertEqual(after[heading]?.objectURI, before[heading]?.objectURI,
                     "\(heading) kept its Core Data identity", file: file, line: line)
      XCTAssertEqual(after[heading]?.nodeId, before[heading]?.nodeId,
                     "\(heading) kept its :ID:", file: file, line: line)
      XCTAssertEqual(after[heading]?.outlinePath, before[heading]?.outlinePath,
                     "\(heading) kept its outline path", file: file, line: line)
    }
  }

  // The headline pin: a one-file, one-heading change must not rebuild the
  // tree. Nodes in the changed file (ID-less, matched by fallback) and in
  // untouched files keep their identity across the import.
  func testChangedFileImportPreservesUntouchedNodes() throws {
    let manifest = try goldenManifest(profile: "peter")
    try resetFixture(profile: "peter")
    syncAndWait()
    assertNodeCounts(match: manifest)

    let survivors = ["Call three contractors for quotes",   // home.org.txt, holds an :ID:
                     "Season ticket logistics",             // home.org.txt, ID-less
                     "Get the gutters cleaned before November"] // scratchpad.org.txt, the file that changes
    let before = try snapshotIdentity(survivors)

    var contents = try fetchFixtureFile("scratchpad.org.txt")
    contents.append(Data("* Ship the harness notes\n".utf8))
    try updateFixtureFile("scratchpad.org.txt", contents: contents)

    syncAndWait()

    let after = try snapshotIdentity(survivors)
    assertIdentityUnchanged(survivors, before: before, after: after)

    // Exactly one new node, everything else where it was.
    XCTAssertEqual(try nodeCount(inFile: "scratchpad.org.txt"),
                   manifest.files["scratchpad.org.txt"]!.count + 1)
    XCTAssertEqual(try fetchNodes().count, manifest.totalNodes + 1)
  }

  // Renaming an ID-less parent heading inserts a new node for it; its
  // ID-holding child must be re-parented by identity, and the outline paths
  // under the new name must cascade in the same save.
  func testRenameCascadesOutlinePathsUnderTheRenamedHeading() throws {
    let manifest = try goldenManifest(profile: "peter")
    try resetFixture(profile: "peter")
    syncAndWait()

    let childBefore = try fetchSingleNode(heading: "Call three contractors for quotes")
    let childURIBefore = childBefore.objectID.uriRepresentation().absoluteString

    var contents = String(decoding: try fetchFixtureFile("home.org.txt"), as: UTF8.self)
    XCTAssertTrue(contents.contains("** NEXT Renovate the kitchen\n"))
    contents = contents.replacingOccurrences(of: "Renovate the kitchen", with: "Remodel the kitchen")
    try updateFixtureFile("home.org.txt", contents: Data(contents.utf8))

    syncAndWait()

    // The renamed heading itself is a new node (an ID-less fallback cannot
    // match a changed heading — the spec's accepted hard edge), but the
    // child kept its identity and now hangs under the new name.
    let child = try fetchSingleNode(heading: "Call three contractors for quotes")
    XCTAssertEqual(child.objectID.uriRepresentation().absoluteString, childURIBefore)
    XCTAssertEqual(child.parent?.heading, "Remodel the kitchen")
    XCTAssertEqual(child.outlinePath,
                   "olp:home.org.txt:Home & Household/Remodel the kitchen/Call three contractors for quotes")

    // A rename is insert+delete, not growth.
    XCTAssertEqual(try nodeCount(inFile: "home.org.txt"), manifest.files["home.org.txt"]!.count)
  }

  // Reordering headings is a sequence-index update on the same nodes —
  // never a delete-and-reinsert.
  func testReorderAppliesAsSequenceUpdateWithoutNewNodes() throws {
    try goldenManifest(profile: "peter")
    try resetFixture(profile: "peter")
    syncAndWait()

    let fileNode = NodeWithFilename("scratchpad.org.txt")
    XCTAssertNotNil(fileNode)
    let first = try fetchSingleNode(heading: "Get the gutters cleaned before November")
    let second = try fetchSingleNode(heading: "Email Dana about the ladder rental")
    XCTAssertEqual(first.parent, fileNode)

    var contents = String(decoding: try fetchFixtureFile("scratchpad.org.txt"), as: UTF8.self)
    let a = "* Get the gutters cleaned before November"
    let b = "* Email Dana about the ladder rental"
    XCTAssertTrue(contents.contains("\(a)\n\(b)\n"))
    contents = contents.replacingOccurrences(of: "\(a)\n\(b)\n", with: "\(b)\n\(a)\n")
    try updateFixtureFile("scratchpad.org.txt", contents: Data(contents.utf8))

    syncAndWait()

    let firstAfter = try fetchSingleNode(heading: "Get the gutters cleaned before November")
    let secondAfter = try fetchSingleNode(heading: "Email Dana about the ladder rental")
    XCTAssertEqual(firstAfter.objectID, first.objectID, "reorder kept the first node")
    XCTAssertEqual(secondAfter.objectID, second.objectID, "reorder kept the second node")

    let order = (fileNode?.sortedChildren() ?? []).compactMap { $0 as? Node }.map { $0.heading ?? "" }
    XCTAssertEqual(order.first, "Email Dana about the ladder rental")
    XCTAssertEqual(order.count > 1 ? order[1] : "", "Get the gutters cleaned before November")
  }

  // Removing a heading and its child deletes exactly that subtree; sibling
  // branches and their identity are untouched.
  func testSubtreeRemovalDeletesExactlyThatSubtree() throws {
    let manifest = try goldenManifest(profile: "peter")
    try resetFixture(profile: "peter")
    syncAndWait()

    let sibling = try fetchSingleNode(heading: "Season ticket logistics")
    let siblingURI = sibling.objectID.uriRepresentation().absoluteString

    var contents = String(decoding: try fetchFixtureFile("home.org.txt"), as: UTF8.self)
    let block = "** WAITING Home insurance claim\n" +
                "*** WAITING Send the adjuster the roof photos\n" +
                "    :ID: 11111111-1111-4111-8111-111111111116\n"
    XCTAssertTrue(contents.contains(block), "the fixture block to remove must exist")
    contents = contents.replacingOccurrences(of: block, with: "")
    try updateFixtureFile("home.org.txt", contents: Data(contents.utf8))

    syncAndWait()

    XCTAssertEqual(try nodeCount(inFile: "home.org.txt"),
                   manifest.files["home.org.txt"]!.count - 2)
    let removed = try fetchNodes(matching: NSPredicate(format: "heading == %@",
                                                       "Send the adjuster the roof photos"))
    XCTAssertEqual(removed.count, 0)

    let siblingAfter = try fetchSingleNode(heading: "Season ticket logistics")
    XCTAssertEqual(siblingAfter.objectID.uriRepresentation().absoluteString, siblingURI)
  }

  // A downloaded file that cannot be decoded must not touch the stored
  // outline (the old path wiped it and left a single error node).
  func testCorruptDownloadLeavesStoredOutlineIntact() throws {
    let manifest = try goldenManifest(profile: "peter")
    try resetFixture(profile: "peter")
    syncAndWait()

    let survivors = ["Call three contractors for quotes",
                     "Get the gutters cleaned before November"]
    let before = try snapshotIdentity(survivors)

    // 64x (0xFF 0x81): invalid UTF-8, no BOM, and not "Salted__" ciphertext.
    var garbage = Data()
    for _ in 0..<64 {
      garbage.append(0xFF)
      garbage.append(0x81)
    }
    try updateFixtureFile("home.org.txt", contents: garbage)

    syncAndWait()

    XCTAssertEqual(try nodeCount(inFile: "home.org.txt"), manifest.files["home.org.txt"]!.count,
                   "the failed download must not touch the stored outline")
    XCTAssertEqual(try fetchNodes().count, manifest.totalNodes)

    let errorNodes = try fetchNodes(matching: NSPredicate(format: "heading BEGINSWITH %@", "Error:"))
    XCTAssertEqual(errorNodes.count, 0, "no error node may replace the outline")

    let after = try snapshotIdentity(survivors)
    assertIdentityUnchanged(survivors, before: before, after: after)
  }
}

// MARK: - Parity: parseToShadow must produce the same tree as parse:

final class OrgShadowParityTests: XCTestCase {

  var moc: NSManagedObjectContext!

  override func setUp() {
    super.setUp()
    let path = Bundle.main.path(forResource: "MobileOrg2", ofType: "momd")!
    let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: path))!
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil,
                                        at: nil, options: nil)
    moc = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    moc.persistentStoreCoordinator = coordinator
  }

  private func fetchFileNode(_ name: String) throws -> Node? {
    let request = NSFetchRequest<Node>(entityName: "Node")
    request.predicate = NSPredicate(format: "indentLevel == 0 AND heading == %@", name)
    return try moc.fetch(request).first
  }

  private func parseBoth(resource: String, orgName: String) throws -> (Node, OrgShadowNode) {
    let bundle = Bundle(for: type(of: self))
    let url = try XCTUnwrap(bundle.url(forResource: resource, withExtension: "org"),
                            "bundled resource \(resource).org missing")

    // Direct parse into the store (the legacy path, pinned by OrgfileParserTests).
    let direct = OrgFileParser()
    direct.localFilename = url.relativePath
    direct.orgFilename = orgName
    direct.parse(moc)
    let fileNode = try XCTUnwrap(fetchFileNode(orgName))

    // Shadow parse of the same file through a fresh parser instance.
    let shadowParser = OrgFileParser()
    shadowParser.localFilename = url.relativePath
    shadowParser.orgFilename = orgName
    let shadowRoot = try XCTUnwrap(shadowParser.parseToShadow())

    return (fileNode, shadowRoot)
  }

  private func assertParity(_ node: Node, _ shadow: OrgShadowNode, path: String) {
    XCTAssertEqual(node.heading ?? "", shadow.heading, "heading @ \(path)")
    XCTAssertEqual(Int32(node.indentLevel?.intValue ?? 0), Int32(shadow.level), "indentLevel @ \(path)")
    XCTAssertEqual(Int32(node.sequenceIndex?.intValue ?? 0), Int32(shadow.sequence), "sequenceIndex @ \(path)")
    XCTAssertEqual(node.todoState ?? "", shadow.todoState, "todoState @ \(path)")
    XCTAssertEqual(node.priority ?? "", shadow.priority, "priority @ \(path)")
    XCTAssertEqual(node.tags ?? "", shadow.tags, "tags @ \(path)")
    XCTAssertEqual(node.inheritedTags ?? "", shadow.inheritedTags, "inheritedTags @ \(path)")
    XCTAssertEqual(node.body ?? "", shadow.body ?? "", "body @ \(path)")
    XCTAssertEqual(node.nodeId ?? "", shadow.nodeId, "nodeId @ \(path)")
    XCTAssertEqual(node.referencedNodeId ?? "", shadow.referencedNodeId, "referencedNodeId @ \(path)")
    XCTAssertEqual(node.readOnly?.boolValue ?? false, shadow.readOnly, "readOnly @ \(path)")
    XCTAssertEqual(node.outlinePath ?? "", shadow.outlinePath ?? "", "outlinePath @ \(path)")

    let kids = (node.sortedChildren() ?? []).compactMap { $0 as? Node }
    XCTAssertEqual(kids.count, shadow.children.count, "child count @ \(path)")
    for (index, kid) in kids.enumerated() {
      assertParity(kid, shadow.children[index], path: "\(path)/\(shadow.heading)")
    }
  }

  func testShadowParseMatchesDirectParse() throws {
    // Every bundled Org resource, including the index file (whose parse
    // carries Settings side effects), the heading-skip torture file, and
    // the alternate-todo-keywords file.
    let cases: [(resource: String, orgName: String)] = [
      ("index", "index.org"),
      ("TodoList", "TodoList.org"),
      ("headingskip", "headingskip.org"),
      ("defaultTodoWords", "defaultTodoWords.org"),
      ("MobileOrgTestingSample", "MobileOrgTestingSample.org"),
    ]
    for entry in cases {
      let (node, shadow) = try parseBoth(resource: entry.resource, orgName: entry.orgName)
      assertParity(node, shadow, path: entry.orgName)
    }
  }
}

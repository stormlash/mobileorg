//
//  WebDavTests.swift
//  MobileOrg
//
//  Created by Mario Martelli on 27.04.17.
//  Copyright © 2017 Sean Escriva. All rights reserved.
//

import XCTest
import CoreData

@testable import MobileOrg

class WebDavTests: XCTestCase {
  var moc:NSManagedObjectContext?

  override func setUp() {
    super.setUp()

    let context = setUpInMemoryManagedObjectContext()
    moc = context


    PersistenceStack.shared.moc = moc!

    Settings.instance().serverMode = ServerModeWebDav
    Settings.instance().username = "schnuddelhuddel"
    Settings.instance().password = "schnuddelhuddel"
    // Loopback IP literal, not the fixture hostname: the iOS 26 simulator's
    // resolver does not consult the host's /etc/hosts, and the fixture name
    // is a wildcard record pointing at GitHub Pages, so a hostname URL
    // resolves to a server that is not the fixture and sync silently
    // downloads nothing (CI run 39841570360).
    Settings.instance().indexUrl = URL(string: "https://127.0.0.1:32773/index.org")
    Settings.instance().encryptionPassword = "SchnuddelHuddel"

  }

  override func tearDown() {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    super.tearDown()
  }

  func testWebDAVSync() {

    let syncExpectation = expectation(description: "Sync")
    SyncManager.instance().sync()

    let dispatchTime = DispatchTime.now() + Double(10000000000) / Double(NSEC_PER_SEC)
    DispatchQueue.main.asyncAfter (deadline: dispatchTime,
                                   execute: {
                                    () -> (Void) in

                                    do {
                                      let fetchRequest = NSFetchRequest<Node>(entityName: "Node")
                                      // fetchRequest.predicate = NSPredicate (format: "heading == %@", "on Level 1.1.1.5")

                                      let nodes = try self.moc!.fetch(fetchRequest)
                                      syncExpectation.fulfill()
                                      XCTAssertEqual(nodes.count, 136)

                                    } catch _ { XCTFail() }
    })

    // Minimal CI stabilization for the audit's documented fixed-sleep
    // pattern: the node-count assertion fires from a fixed asyncAfter, and
    // the deadline must exceed it. CI evidence (runs 39844646908 and
    // 39846649161): at a 4s tick the runner's full-file download has
    // finished but the import is still mid-flight (42 of 136 nodes), so the
    // tick needs to clear the whole serial-download-then-import cycle.
    // Proper polled expectations are deferred to the regression-harness task.
    waitForExpectations(timeout: 12, handler: nil)

  }

  func testSyncChangesOnMobile() {

    let syncExpectation = expectation(description: "Sync")
    SyncManager.instance().sync()

    let dispatchTime = DispatchTime.now() + Double(4000000000) / Double(NSEC_PER_SEC)
    DispatchQueue.main.asyncAfter (deadline: dispatchTime,
                                   execute: {
                                    () -> (Void) in

                                    do {

                                      let fetchRequest = NSFetchRequest<Node>(entityName: "Node")
                                      fetchRequest.predicate = NSPredicate (format: "heading == %@", "Seamless integration of Cloud services")

                                      let nodes = try self.moc!.fetch(fetchRequest)
                                      print(nodes.count)
                                      if nodes.count == 0 {
                                        XCTFail()
                                        return
                                      }

                                      // Make local changes and sync again
                                      let tagEditController = TagEditController(node: nodes.first!)

                                      tagEditController?.recentTagString = "Test456"
                                      tagEditController?.commitNewTag()

                                      Save()

                                      SyncManager.instance().sync()
                                      syncExpectation.fulfill()
                                      XCTAssertEqual(nodes.first?.tags, ":Test456:")

                                    } catch _ { XCTFail() }
    })

    waitForExpectations(timeout: 5, handler: nil)
  }

  func testSyncChangesOnMobileReverse() {

    let syncExpectation = expectation(description: "Sync")
    SyncManager.instance().sync()

    let dispatchTime = DispatchTime.now() + Double(4000000000) / Double(NSEC_PER_SEC)
    DispatchQueue.main.asyncAfter (deadline: dispatchTime,
                                   execute: {
                                    () -> (Void) in

                                    do {

                                      let fetchRequest = NSFetchRequest<Node>(entityName: "Node")
                                      fetchRequest.predicate = NSPredicate (format: "heading == %@", "Seamless integration of Cloud services")

                                      let nodes = try self.moc!.fetch(fetchRequest)

                                      if nodes.count == 0 {
                                        XCTFail()
                                        return
                                      }

                                      // Make local changes and sync again
                                      let tagEditController = TagEditController(node: nodes.first!)

                                      tagEditController?.recentTagString = ""
                                      tagEditController?.commitNewTag()
                                      
                                      Save()
                                      
                                      SyncManager.instance().sync()
                                      syncExpectation.fulfill()
                                      XCTAssertEqual(nodes.first?.tags, "::")
                                      
                                    } catch _ { XCTFail() }
    })
    
    waitForExpectations(timeout: 5, handler: nil)
  }
  
  func setUpInMemoryManagedObjectContext() -> NSManagedObjectContext {
    let path = Bundle.main.path(forResource: "MobileOrg2", ofType: "momd")
    let momURL = URL.init(fileURLWithPath: path!)
    let managedObjectModel = NSManagedObjectModel.init(contentsOf: momURL)

    let persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: managedObjectModel!)
    try! persistentStoreCoordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)
    
    let managedObjectContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    managedObjectContext.persistentStoreCoordinator = persistentStoreCoordinator
    
    return managedObjectContext
  }
}

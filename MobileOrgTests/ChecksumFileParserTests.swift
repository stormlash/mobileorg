//
//  ChecksumFileParserTests.swift
//  MobileOrg
//
//  Pins the checksums.dat pair extraction. The parser once used
//  componentsSeparatedByRegex: (a RegexKitLite category no SDK provides);
//  when its semantics vanished, the table silently stayed empty and every
//  sync re-downloaded all staged files. These tests keep that regression
//  visible in the fast unit lane.
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 2
//  of the License, or (at your option) any later version.
//

import XCTest

class ChecksumFileParserTests: XCTestCase {

  private func writeFile(_ contents: String) -> String {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("checksums-\(UUID().uuidString).dat")
    try? contents.write(to: url, atomically: true, encoding: .utf8)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url.path
  }

  func testParsesLinuxMd5sumFormat() throws {
    let parser = ChecksumFileParser()
    let path = writeFile("90bc512f84e7da94a1da89daea0c01d8  home.org.txt\n")
    parser.parse(path)
    XCTAssertEqual(parser.checksumPairs["home.org.txt"] as? String,
                   "90bc512f84e7da94a1da89daea0c01d8")
    XCTAssertEqual(parser.checksumPairs.count, 1)
  }

  func testParsesShasumFormat() throws {
    let parser = ChecksumFileParser()
    let path = writeFile(
      "4c05152c39bcc402ea99851c01e3849060a9d3a1  MainWindow.xib\n")
    parser.parse(path)
    XCTAssertEqual(parser.checksumPairs["MainWindow.xib"] as? String,
                   "4c05152c39bcc402ea99851c01e3849060a9d3a1")
  }

  func testParsesOsxMd5FormatWithSwappedGroups() throws {
    let parser = ChecksumFileParser()
    let path = writeFile("MD5 (Icon.png) = 476d45ce45fc0658bbda13137bc60205\n")
    parser.parse(path)
    XCTAssertEqual(parser.checksumPairs["Icon.png"] as? String,
                   "476d45ce45fc0658bbda13137bc60205")
  }

  func testParsesMixedFormatsAndSkipsJunkLines() throws {
    let parser = ChecksumFileParser()
    let path = writeFile([
      "90bc512f84e7da94a1da89daea0c01d8  home.org.txt",
      "4c05152c39bcc402ea99851c01e3849060a9d3a1  MainWindow.xib",
      "MD5 (Icon.png) = 476d45ce45fc0658bbda13137bc60205",
      "",
      "# a comment line",
      "not a checksum line at all",
    ].joined(separator: "\n") + "\n")
    parser.parse(path)
    XCTAssertEqual(parser.checksumPairs.count, 3)
    XCTAssertEqual(parser.checksumPairs["home.org.txt"] as? String,
                   "90bc512f84e7da94a1da89daea0c01d8")
    XCTAssertEqual(parser.checksumPairs["MainWindow.xib"] as? String,
                   "4c05152c39bcc402ea99851c01e3849060a9d3a1")
    XCTAssertEqual(parser.checksumPairs["Icon.png"] as? String,
                   "476d45ce45fc0658bbda13137bc60205")
  }

  func testReparsingClearsPreviousPairs() throws {
    let parser = ChecksumFileParser()
    parser.parse(writeFile("90bc512f84e7da94a1da89daea0c01d8  home.org.txt\n"))
    parser.parse(writeFile("9304a8c4468ca686dbd106ed83b8079d  work.org.txt\n"))
    XCTAssertEqual(parser.checksumPairs.count, 1)
    XCTAssertNil(parser.checksumPairs["home.org.txt"])
    XCTAssertEqual(parser.checksumPairs["work.org.txt"] as? String,
                   "9304a8c4468ca686dbd106ed83b8079d")
  }

  func testMissingFileLeavesPairsEmpty() throws {
    let parser = ChecksumFileParser()
    parser.parse("/nonexistent/path/checksums.dat")
    XCTAssertEqual(parser.checksumPairs.count, 0)
  }
}

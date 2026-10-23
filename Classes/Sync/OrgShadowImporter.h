//
//  OrgShadowImporter.h
//  MobileOrg
//
//  Incremental import: applies a parsed shadow tree to the stored outline of
//  one Org file, preserving Core Data identity for nodes that did not change.
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 2
//  of the License, or (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program; if not, write to the Free Software
//  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class OrgShadowNode;

@interface OrgShadowImporter : NSObject

// Diff-applies the parsed shadow of the Org file named orgFilename against
// that file's stored subtree in the main-queue Core Data context.
//
// Matching is nodeId-first (:ID: values), with a (parent, indent level,
// heading) fallback for headings without an ID. Matched nodes are updated in
// place, new shadow entries are inserted, and unmatched stored nodes are
// deleted; outline paths are recomputed over the file's whole subtree
// afterwards to absorb renames and moves. Commits nothing: the caller saves
// the context once per imported file.
//
// When no stored file node exists for the name, one is inserted; extra
// duplicate file nodes (should they exist) are removed instead of being
// rebuilt, so their children's identity survives.
+ (void)applyShadow:(OrgShadowNode *)shadowRoot forFilename:(NSString *)orgFilename;

@end

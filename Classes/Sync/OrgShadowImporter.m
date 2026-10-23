//
//  OrgShadowImporter.m
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

#import "OrgShadowImporter.h"
#import "OrgFileParser.h"
#import "Node.h"
#import "DataUtils.h"
#import "MobileOrg-Swift.h"

// nil and @"" are equivalent stored states for every text field the old
// rebuild path ever wrote, so treat them as equal when deciding whether a
// node actually changed.
static bool SameText(NSString *a, NSString *b) {
    if (a == b) {
        return true;
    }
    if ([a length] == 0 && [b length] == 0) {
        return true;
    }
    if (!a || !b) {
        return false;
    }
    return [a isEqualToString:b];
}

// Index the stored subtree by :ID: value so a nodeId match can reach across
// the whole file (moved headings), not just the same parent position.
static void IndexStoredIds(Node *node, NSMutableDictionary *idIndex) {
    if ([node.nodeId length] > 0 && idIndex[node.nodeId] == nil) {
        idIndex[node.nodeId] = node;
    }
    for (Node *child in [node sortedChildren]) {
        IndexStoredIds(child, idIndex);
    }
}

@implementation OrgShadowImporter

+ (void)updateNode:(Node *)node fromShadow:(OrgShadowNode *)shadow {
    if (!SameText(node.heading, shadow.heading)) {
        node.heading = shadow.heading;
    }
    if ([node.indentLevel intValue] != shadow.level) {
        node.indentLevel = [NSNumber numberWithInt:shadow.level];
    }
    if ([node.sequenceIndex intValue] != shadow.sequence) {
        node.sequenceIndex = [NSNumber numberWithInt:shadow.sequence];
    }
    if (!SameText(node.todoState, shadow.todoState)) {
        node.todoState = shadow.todoState;
    }
    if (!SameText(node.priority, shadow.priority)) {
        node.priority = shadow.priority;
    }
    if (!SameText(node.tags, shadow.tags)) {
        node.tags = shadow.tags;
    }
    if (!SameText(node.inheritedTags, shadow.inheritedTags)) {
        node.inheritedTags = shadow.inheritedTags;
    }
    if (!SameText(node.body, shadow.body)) {
        node.body = shadow.body;
    }
    if (!SameText(node.nodeId, shadow.nodeId)) {
        node.nodeId = shadow.nodeId;
    }
    if (!SameText(node.referencedNodeId, shadow.referencedNodeId)) {
        node.referencedNodeId = shadow.referencedNodeId;
    }
    if ([node.readOnly boolValue] != shadow.readOnly) {
        node.readOnly = [NSNumber numberWithBool:shadow.readOnly];
    }
    // outlinePath is deliberately not set here: a single cascade walk over
    // the file's whole subtree recomputes it after matching, so renames and
    // moves are absorbed in one pass.
}

+ (Node *)insertNodeFromShadow:(OrgShadowNode *)shadow
                    withParent:(Node *)parent
                     inContext:(NSManagedObjectContext *)managedObjectContext {
    Node *node = (Node*)[NSEntityDescription insertNewObjectForEntityForName:@"Node"
                                                      inManagedObjectContext:managedObjectContext];
    node.heading = shadow.heading;
    node.indentLevel = [NSNumber numberWithInt:shadow.level];
    node.sequenceIndex = [NSNumber numberWithInt:shadow.sequence];
    node.outlinePath = shadow.outlinePath;
    node.todoState = shadow.todoState;
    node.inheritedTags = shadow.inheritedTags;
    node.tags = shadow.tags;
    node.priority = shadow.priority;
    node.readOnly = [NSNumber numberWithBool:shadow.readOnly];
    node.nodeId = shadow.nodeId;
    node.referencedNodeId = shadow.referencedNodeId;
    node.body = shadow.body;
    node.parent = parent;
    return node;
}

+ (void)applyShadowChildren:(OrgShadowNode *)shadowParent
                     toNode:(Node *)nodeParent
                    idIndex:(NSDictionary *)idIndex
                    matched:(NSMutableSet *)matched
                   toDelete:(NSMutableArray *)toDelete {
    NSManagedObjectContext *managedObjectContext = PersistenceStack.shared.moc;
    NSArray *existing = [nodeParent sortedChildren];

    // Pass 1: nodeId matches. These may reach anywhere in the file's stored
    // subtree, which is what makes moves and reparented subtrees work.
    for (OrgShadowNode *shadow in [shadowParent children]) {
        if ([shadow.nodeId length] == 0) {
            continue;
        }
        Node *match = idIndex[shadow.nodeId];
        if (match && ![matched containsObject:match.objectID]) {
            [matched addObject:match.objectID];
            if (match.parent != nodeParent) {
                match.parent = nodeParent;
            }
            [self updateNode:match fromShadow:shadow];
            [self applyShadowChildren:shadow toNode:match idIndex:idIndex matched:matched toDelete:toDelete];
        } else {
            // No unused stored node carries this :ID: — either a genuinely new
            // node or a duplicate id in the file. Insert it, which is what the
            // legacy wipe-and-rebuild import did with every parsed node.
            // Skipping here dropped every ID-bearing node on cold imports.
            Node *inserted = [self insertNodeFromShadow:shadow withParent:nodeParent inContext:managedObjectContext];
            [self applyShadowChildren:shadow toNode:inserted idIndex:idIndex matched:matched toDelete:toDelete];
        }
    }

    // Pass 2: (parent, indent level, heading) fallback for ID-less entries.
    // The first unmatched candidate in sequence order wins, which keeps
    // duplicated headings matched 1:1 instead of collapsing them.
    for (OrgShadowNode *shadow in [shadowParent children]) {
        if ([shadow.nodeId length] > 0) {
            continue;
        }
        Node *match = nil;
        for (Node *candidate in existing) {
            if ([matched containsObject:candidate.objectID]) {
                continue;
            }
            if ([candidate.indentLevel intValue] == shadow.level &&
                [candidate.heading isEqualToString:shadow.heading]) {
                match = candidate;
                break;
            }
        }
        if (match) {
            [matched addObject:match.objectID];
            if (match.parent != nodeParent) {
                match.parent = nodeParent;
            }
            [self updateNode:match fromShadow:shadow];
            [self applyShadowChildren:shadow toNode:match idIndex:idIndex matched:matched toDelete:toDelete];
        } else {
            Node *inserted = [self insertNodeFromShadow:shadow withParent:nodeParent inContext:managedObjectContext];
            [self applyShadowChildren:shadow toNode:inserted idIndex:idIndex matched:matched toDelete:toDelete];
        }
    }

    // Whatever this file's stored subtree still holds that the new parse does
    // not is deleted. Cascade rules take the (still-attached) subtree with it;
    // nodes re-parented during matching are no longer attached and survive.
    for (Node *child in existing) {
        if (![matched containsObject:child.objectID]) {
            [toDelete addObject:child];
        }
    }
}

+ (void)recomputeOutlinePaths:(Node *)node prefix:(NSString *)prefix {
    for (Node *child in [node sortedChildren]) {
        if ([child.indentLevel intValue] == 0) {
            // A nested file node would be a data bug; leave its path alone.
            continue;
        }
        NSString *path = prefix;
        if ([path characterAtIndex:[path length]-1] != ':') {
            path = [path stringByAppendingString:@"/"];
        }
        path = [path stringByAppendingString:EscapeStringForOutlinePath(child.heading)];
        if (!SameText(child.outlinePath, path)) {
            child.outlinePath = path;
        }
        [self recomputeOutlinePaths:child prefix:path];
    }
}

+ (void)applyShadow:(OrgShadowNode *)shadowRoot forFilename:(NSString *)orgFilename {
    NSManagedObjectContext *managedObjectContext = PersistenceStack.shared.moc;
    NSMutableArray *toDelete = [NSMutableArray new];
    NSMutableSet *matched = [NSMutableSet new];

    // Find the file node for this filename (level-0 node named after the
    // decoded Org filename — the same identification the old delete-then-
    // reparse used).
    NSFetchRequest *request = [NSFetchRequest new];
    NSEntityDescription *entity = [NSEntityDescription entityForName:@"Node"
                                          inManagedObjectContext:managedObjectContext];
    [request setEntity:entity];
    [request setPredicate:[NSPredicate predicateWithFormat:@"(indentLevel == %@) AND (heading == %@)",
                           [NSNumber numberWithInt:0], orgFilename]];
    NSArray *fileNodes = [managedObjectContext executeFetchRequest:request error:NULL];

    Node *fileNode = nil;
    if ([fileNodes count] > 0) {
        fileNode = [fileNodes objectAtIndex:0];
        // Defensive: collapse duplicate file nodes rather than rebuilding
        // them all (the old wipe loop deleted every duplicate, along with
        // their subtrees).
        for (NSUInteger i = 1; i < [fileNodes count]; i++) {
            [toDelete addObject:[fileNodes objectAtIndex:i]];
        }
    } else {
        fileNode = (Node*)[NSEntityDescription insertNewObjectForEntityForName:@"Node"
                                                        inManagedObjectContext:managedObjectContext];
        fileNode.heading = orgFilename;
        fileNode.indentLevel = [NSNumber numberWithInt:0];
        fileNode.sequenceIndex = [NSNumber numberWithInt:0];
        fileNode.readOnly = [NSNumber numberWithBool:true];
    }

    // The file node's tags come from #+FILETAGS in the shadow root.
    if (!SameText(fileNode.tags, shadowRoot.tags)) {
        fileNode.tags = shadowRoot.tags;
    }

    // Index the stored subtree's IDs before any mutation.
    NSMutableDictionary *idIndex = [NSMutableDictionary new];
    IndexStoredIds(fileNode, idIndex);

    [self applyShadowChildren:shadowRoot toNode:fileNode idIndex:idIndex matched:matched toDelete:toDelete];

    for (Node *node in toDelete) {
        [managedObjectContext deleteObject:node];
    }

    // Recompute outline paths over the file's whole subtree so renames and
    // moves land in the same save.
    NSString *filePrefix = [NSString stringWithFormat:@"olp:%@:", EscapeStringForOutlinePath(orgFilename)];
    [self recomputeOutlinePaths:fileNode prefix:filePrefix];
}

@end

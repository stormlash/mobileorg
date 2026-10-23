//
//  OrgFileParser.h
//  MobileOrg
//
//  Created by Richard Moreland on 9/30/09.
//  Copyright 2009 Richard Moreland.
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

// Transient, context-free stand-in for a Node, produced by parseToShadow and
// consumed by OrgShadowImporter. Holds exactly the fields the old
// delete-then-reparse path used to set, so the diff-apply can update nodes in
// place instead of rebuilding them.
@interface OrgShadowNode : NSObject

@property (nonatomic, copy) NSString *heading;
@property (nonatomic, assign) int level;
@property (nonatomic, assign) int sequence;
@property (nonatomic, copy) NSString *todoState;
@property (nonatomic, copy) NSString *priority;
@property (nonatomic, copy) NSString *tags;
@property (nonatomic, copy) NSString *inheritedTags;
@property (nonatomic, copy) NSString *body;
@property (nonatomic, copy) NSString *nodeId;
@property (nonatomic, copy) NSString *referencedNodeId;
@property (nonatomic, assign) bool readOnly;
@property (nonatomic, copy) NSString *outlinePath;

// Complete tags = own tags plus those inherited from ancestors (same rule as
// -[Node completeTags]).
- (NSString *)completeTags;

@property (nonatomic, readonly) OrgShadowNode *parent;
@property (nonatomic, readonly) NSArray<OrgShadowNode *> *children;

@end

@interface OrgFileParser : NSObject {
    __unsafe_unretained id delegate;
    SEL completionSelector;
    NSString *orgFilename;
    NSString *localFilename;
    NSString *errorStr;
}

@property (nonatomic, assign) id delegate;
@property (nonatomic) SEL completionSelector;
@property (nonatomic, copy) NSString *orgFilename;
@property (nonatomic, copy) NSString *localFilename;
@property (nonatomic, copy) NSString *errorStr;

- (void)parse:(NSManagedObjectContext *)moc;

// Parses the staged local file into a transient shadow tree without touching
// Core Data. On success returns the file-level shadow root (heading is the
// decoded org filename, indentLevel 0). On a read or decode failure returns
// nil and sets errorStr — the caller must then leave the stored outline for
// this file untouched.
- (OrgShadowNode *)parseToShadow;

@end

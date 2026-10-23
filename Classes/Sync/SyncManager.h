//
//  SyncManager.h
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
#import "TransferManagerDelegate.h"

@class ChecksumFileParser;
@class OrgFileParser;
@class EditsFileParser;

typedef enum {
    SyncManagerTransferStateIdle,
    SyncManagerTransferStateDownloadingEditsFile,
    SyncManagerTransferStateUploadingEmptyEditsFile,
    SyncManagerTransferStateUploadingLocalChanges,
    SyncManagerTransferStateDownloadingChecksums,
    SyncManagerTransferStateDownloadingOrgFiles,
} SyncManagerTransferState;

@interface SyncManager : NSObject <TransferManagerDelegate> {
    SyncManagerTransferState currentState;

    ChecksumFileParser *checksumParser;
    OrgFileParser *orgFileParser;
    EditsFileParser *editsFileParser;

    NSMutableArray *downloadedFiles;

    NSString *downloadedEditsFilename;

    NSString *transferState;
    NSString *transferFilename;
    int progressTotal;
    int progressCurrent;

    bool changedEditsFile;

    // Guards against overlapping sync entrypoints (e.g. a user-driven sync
    // while a background one is mid-transfer): the transfer pipeline is a
    // single shared state machine, so concurrent syncs would interleave
    // transfer contexts from two separate runs.
    bool syncInFlight;
}

@property (nonatomic, copy) NSString *transferState;
@property (nonatomic, copy) NSString *transferFilename;
@property (nonatomic) int progressTotal;
@property (nonatomic) int progressCurrent;

// Proof-run instrumentation for the sync timing capture: accumulated wall
// seconds spent importing changed Org files (the import step inside
// transferComplete) since the last reset. Read by SyncTimingCaptureTests.
+ (void)resetImportSeconds;
+ (double)totalImportSeconds;

+ (SyncManager*)instance;
- (void)sync;
- (void)abort;

- (void)updateStatus;

@end

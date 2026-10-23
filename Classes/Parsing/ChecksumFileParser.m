//
//  ChecksumFileParser.m
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

#import "ChecksumFileParser.h"
#import "MobileOrg-Swift.h"

@implementation ChecksumFileParser

@synthesize checksumPairs;

- (id)init {
    if (self = [super init]) {
        self.checksumPairs = [NSMutableDictionary new];
    }
    return self;
}

- (void)reset {
    [self.checksumPairs removeAllObjects];
}

- (void)parse:(NSString*)file {
    [checksumPairs removeAllObjects];

    NSError *error = nil;
    NSStringEncoding encoding;
    NSString *entireFile = [NSString stringWithContentsOfFile:file usedEncoding:&encoding error:&error];
    if (error) {
        //NSLog(@"Failed to read contents of file because: %@ (%@)", [error description], [error userInfo]);
        entireFile = @"";
    }

    // Supported line formats: linux md5sum ("32hex  filename"), shasum
    // ("40hex  filename"), and macOS md5 ("MD5 (filename) = 32hex").
    // NSRegularExpression is used because the previous implementation relied
    // on componentsSeparatedByRegex:, a RegexKitLite category that no SDK
    // provides: on the modern SDK it matched nothing, the checksum table
    // stayed empty, and every sync re-downloaded all files. Capture groups
    // are read explicitly, so the semantics are documented behavior.
    NSError *regexError = nil;
    NSRegularExpression *shasum = [NSRegularExpression regularExpressionWithPattern:@"^([a-f0-9]{40})  (.+)$" options:0 error:&regexError];
    NSRegularExpression *md5sum = [NSRegularExpression regularExpressionWithPattern:@"^([a-f0-9]{32})  (.+)$" options:0 error:&regexError];
    NSRegularExpression *osxmd5 = [NSRegularExpression regularExpressionWithPattern:@"^MD5 \\((.+)\\) = ([a-f0-9]{32})$" options:0 error:&regexError];
    if (!shasum || !md5sum || !osxmd5 || regexError) {
        return;
    }

    for (NSString *line in [entireFile componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if ([line length] == 0) {
            continue;
        }

        NSString *checksum = nil, *filename = nil;
        NSRange range = NSMakeRange(0, [line length]);
        NSTextCheckingResult *match = [shasum firstMatchInString:line options:0 range:range];
        if (match) {
            checksum = [line substringWithRange:[match rangeAtIndex:1]];
            filename = [line substringWithRange:[match rangeAtIndex:2]];
        } else if ((match = [md5sum firstMatchInString:line options:0 range:range])) {
            checksum = [line substringWithRange:[match rangeAtIndex:1]];
            filename = [line substringWithRange:[match rangeAtIndex:2]];
        } else if ((match = [osxmd5 firstMatchInString:line options:0 range:range])) {
            // NOTE: Filename and checksum are swapped in the osx md5 format
            filename = [line substringWithRange:[match rangeAtIndex:1]];
            checksum = [line substringWithRange:[match rangeAtIndex:2]];
        }

        // Be careful not to die if there's a bad line (like if you md5sum'd * with dirs in it
        if (checksum && filename) {
            [checksumPairs setObject:checksum forKey:filename];
        }
    }
}

@end

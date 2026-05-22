#import <Foundation/Foundation.h>
#import <QuickLook/QuickLook.h>

static NSString *EscapeHTML(NSString *value) {
    NSMutableString *escaped = [value mutableCopy] ?: [NSMutableString string];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

static NSArray<NSArray<NSString *> *> *ParseDelimited(NSString *text, unichar delimiter, NSUInteger limit) {
    NSMutableArray<NSArray<NSString *> *> *records = [NSMutableArray array];
    NSMutableArray<NSString *> *record = [NSMutableArray array];
    NSMutableString *field = [NSMutableString string];
    BOOL inQuotes = NO;
    NSUInteger length = text.length;

    for (NSUInteger index = 0; index < length; index++) {
        unichar character = [text characterAtIndex:index];
        if (inQuotes) {
            if (character == '"') {
                if (index + 1 < length && [text characterAtIndex:index + 1] == '"') {
                    [field appendString:@"\""];
                    index++;
                } else {
                    inQuotes = NO;
                }
            } else {
                [field appendFormat:@"%C", character];
            }
        } else {
            if (character == '"' && field.length == 0) {
                inQuotes = YES;
            } else if (character == delimiter) {
                [record addObject:[field copy]];
                [field setString:@""];
            } else if (character == '\n' || character == '\r') {
                [record addObject:[field copy]];
                [field setString:@""];
                [records addObject:[record copy]];
                [record removeAllObjects];
                if (records.count >= limit) {
                    return records;
                }
                if (character == '\r' && index + 1 < length && [text characterAtIndex:index + 1] == '\n') {
                    index++;
                }
            } else {
                [field appendFormat:@"%C", character];
            }
        }
    }

    if (field.length > 0 || record.count > 0) {
        [record addObject:[field copy]];
        [records addObject:[record copy]];
    }
    return records;
}

static unichar DetectDelimiter(NSString *text) {
    NSArray<NSNumber *> *candidates = @[@',', @'\t', @';', @'|'];
    unichar best = ',';
    NSInteger bestScore = -1;
    NSString *sample = text.length > 16384 ? [text substringToIndex:16384] : text;

    for (NSNumber *candidate in candidates) {
        unichar delimiter = (unichar)candidate.unsignedShortValue;
        NSArray<NSArray<NSString *> *> *rows = ParseDelimited(sample, delimiter, 20);
        NSMutableDictionary<NSNumber *, NSNumber *> *counts = [NSMutableDictionary dictionary];
        NSInteger maxColumns = 0;
        for (NSArray<NSString *> *row in rows) {
            if (row.count <= 1) {
                continue;
            }
            NSNumber *key = @(row.count);
            counts[key] = @([counts[key] integerValue] + 1);
            maxColumns = MAX(maxColumns, (NSInteger)row.count);
        }

        NSInteger stableRows = 0;
        for (NSNumber *count in counts.allValues) {
            stableRows = MAX(stableRows, count.integerValue);
        }
        NSInteger score = stableRows * 100 + maxColumns;
        if (score > bestScore) {
            bestScore = score;
            best = delimiter;
        }
    }
    return best;
}

static NSArray<NSArray<NSString *> *> *RowsForJSON(NSString *text, NSUInteger limit) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![value isKindOfClass:NSArray.class]) {
        return @[];
    }

    NSArray *array = (NSArray *)value;
    NSMutableArray<NSString *> *headers = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableArray<NSDictionary *> *objects = [NSMutableArray array];

    for (id item in array) {
        if (![item isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSDictionary *object = (NSDictionary *)item;
        [objects addObject:object];
        for (id key in [[object allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *name = [key description];
            if (![seen containsObject:name]) {
                [seen addObject:name];
                [headers addObject:name];
            }
        }
        if (objects.count >= limit) {
            break;
        }
    }

    if (headers.count == 0) {
        return @[];
    }

    NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray arrayWithObject:headers];
    for (NSDictionary *object in objects) {
        NSMutableArray<NSString *> *row = [NSMutableArray array];
        for (NSString *header in headers) {
            id cell = object[header];
            [row addObject:cell ? [cell description] : @""];
        }
        [rows addObject:row];
    }
    return rows;
}

static NSArray<NSArray<NSString *> *> *RowsForJSONLines(NSString *text, NSUInteger limit) {
    NSMutableArray *array = [NSMutableArray array];
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length == 0) {
            return;
        }
        NSData *data = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
        id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (value) {
            [array addObject:value];
        }
        if (array.count >= limit) {
            *stop = YES;
        }
    }];

    NSData *data = [NSJSONSerialization dataWithJSONObject:array options:0 error:nil];
    NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
    return RowsForJSON(json ?: @"[]", limit);
}

static NSString *HTMLForRows(NSURL *url, NSArray<NSArray<NSString *> *> *rows) {
    NSString *title = EscapeHTML(url.lastPathComponent ?: @"LightData Preview");
    NSMutableString *html = [NSMutableString string];
    [html appendString:@"<!doctype html><html><head><meta charset=\"utf-8\"><style>"];
    [html appendString:@"body{margin:0;font:13px -apple-system,BlinkMacSystemFont,sans-serif;color:#1d1d1f;background:#fff}"];
    [html appendString:@".bar{position:sticky;top:0;background:#f5f5f7;border-bottom:1px solid #d2d2d7;padding:10px 14px;font-weight:600}"];
    [html appendString:@"table{border-collapse:collapse;width:100%;table-layout:auto}th,td{border:1px solid #e5e5ea;padding:6px 8px;white-space:nowrap;max-width:360px;overflow:hidden;text-overflow:ellipsis}th{background:#fbfbfd;position:sticky;top:39px;text-align:left}tr:nth-child(even) td{background:#fafafa}.empty{padding:24px;color:#6e6e73}"];
    [html appendString:@"</style></head><body>"];
    [html appendFormat:@"<div class=\"bar\">%@</div>", title];

    if (rows.count == 0) {
        [html appendString:@"<div class=\"empty\">No tabular preview available.</div></body></html>"];
        return html;
    }

    [html appendString:@"<table>"];
    NSArray<NSString *> *headers = rows.firstObject;
    [html appendString:@"<thead><tr><th>#</th>"];
    for (NSString *header in headers) {
        [html appendFormat:@"<th>%@</th>", EscapeHTML(header)];
    }
    [html appendString:@"</tr></thead><tbody>"];

    for (NSUInteger rowIndex = 1; rowIndex < rows.count; rowIndex++) {
        NSArray<NSString *> *row = rows[rowIndex];
        [html appendFormat:@"<tr><td>%lu</td>", (unsigned long)rowIndex];
        for (NSUInteger column = 0; column < headers.count; column++) {
            NSString *cell = column < row.count ? row[column] : @"";
            [html appendFormat:@"<td>%@</td>", EscapeHTML(cell)];
        }
        [html appendString:@"</tr>"];
    }

    [html appendString:@"</tbody></table></body></html>"];
    return html;
}

OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef urlRef, CFStringRef contentTypeUTI, CFDictionaryRef options) {
    @autoreleasepool {
        if (QLPreviewRequestIsCancelled(preview)) {
            return noErr;
        }

        NSURL *url = (__bridge NSURL *)urlRef;
        NSString *extension = url.pathExtension.lowercaseString;
        NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
        if (!text) {
            text = [NSString stringWithContentsOfURL:url encoding:NSISOLatin1StringEncoding error:nil];
        }

        NSArray<NSArray<NSString *> *> *rows = @[];
        if ([extension isEqualToString:@"json"]) {
            rows = RowsForJSON(text ?: @"", 200);
        } else if ([extension isEqualToString:@"jsonl"] || [extension isEqualToString:@"ndjson"]) {
            rows = RowsForJSONLines(text ?: @"", 200);
        } else if ([extension isEqualToString:@"tsv"] || [extension isEqualToString:@"tab"]) {
            rows = ParseDelimited(text ?: @"", '\t', 200);
        } else {
            rows = ParseDelimited(text ?: @"", DetectDelimiter(text ?: @""), 200);
        }

        NSString *html = HTMLForRows(url, rows);
        NSData *data = [html dataUsingEncoding:NSUTF8StringEncoding];
        QLPreviewRequestSetDataRepresentation(preview, (__bridge CFDataRef)data, CFSTR("public.html"), NULL);
    }
    return noErr;
}

void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview) {
}

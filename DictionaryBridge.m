#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>
#import <dlfcn.h>

// One word/phrase at a time. A listed MobileAsset is NOT necessarily installed:
// macOS can reclaim it and the discovery call starts an asynchronous download.
// Always report each preferred source, including readiness, even for no records.
typedef CFTypeRef (*CopyDictionaries)(void);
typedef CFStringRef (*GetName)(CFTypeRef);
typedef CFURLRef (*GetURL)(CFTypeRef);
typedef CFArrayRef (*CopyRecords)(CFTypeRef, CFStringRef, CFIndex, CFIndex);
typedef CFTypeRef (*CopyData)(CFTypeRef);
typedef CFStringRef (*GetRecordHead)(CFTypeRef);

static NSString *stringValue(CFStringRef value) {
    return value ? (__bridge NSString *)value : @"";
}

static NSString *plainDefinition(CFTypeRef dictionary, NSString *term) {
    return CFBridgingRelease(DCSCopyTextDefinition((DCSDictionaryRef)dictionary,
        (__bridge CFStringRef)term, CFRangeMake(0, term.length))) ?: @"";
}

static NSArray *localAssetGeneration(NSURL *url) {
    if (!url.isFileURL) return nil;
    NSURL *resources = [url URLByAppendingPathComponent:@"Contents/Resources"];
    NSMutableArray *generation = [NSMutableArray array];
    for (NSString *file in @[@"Body.data", @"KeyText.data"]) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:
            [resources URLByAppendingPathComponent:file].path error:nil];
        if (attrs.fileSize == 0) return nil;
        [generation addObject:@[attrs[NSFileSystemFileNumber] ?: @0,
            attrs[NSFileSize] ?: @0,attrs[NSFileModificationDate] ?: [NSNull null]]];
    }
    return generation;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSString *term = [NSString stringWithUTF8String:argv[1]];
        if (!term || term.length == 0 || term.length > 180) return 2;
        void *lib = dlopen("/System/Library/Frameworks/CoreServices.framework/Frameworks/DictionaryServices.framework/DictionaryServices", RTLD_LAZY|RTLD_LOCAL);
        if (!lib) lib = dlopen("/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/DictionaryServices.framework/Versions/A/DictionaryServices", RTLD_LAZY|RTLD_LOCAL);
        if (!lib) return 3;
        CopyDictionaries list = (CopyDictionaries)dlsym(lib, "DCSCopyAvailableDictionaries");
        GetName name = (GetName)dlsym(lib, "DCSDictionaryGetName");
        GetURL url = (GetURL)dlsym(lib, "DCSDictionaryGetURL");
        CopyRecords records = (CopyRecords)dlsym(lib, "DCSCopyRecordsForSearchString");
        CopyData data = (CopyData)dlsym(lib, "DCSRecordCopyData");
        GetRecordHead head = (GetRecordHead)dlsym(lib, "DCSRecordGetHeadword");
        GetRecordHead rawHead = (GetRecordHead)dlsym(lib, "DCSRecordGetRawHeadword");
        if (!list || !name || !records || !data || !head) return 4;
        CFTypeRef listed = list();
        id available = CFBridgingRelease(listed);
        // A nil catalog during resource restoration has the same semantics
        // as an empty catalog. Unexpected non-array values remain failures.
        NSArray *dictionaries = [available isKindOfClass:[NSSet class]] ? [available allObjects] : available ?: @[];
        if (![dictionaries isKindOfClass:[NSArray class]]) return 5;

        NSDictionary *target = @{@"com.apple.dictionary.ODE":@"Oxford Dictionary of English",
                                 @"com.apple.dictionary.OAWT":@"Oxford American Writer’s Thesaurus",
                                 @"com.apple.dictionary.zh_CN-en.OCD":@"Oxford Chinese Dictionary"};
        // Missing from the list is a resource failure, not a negative lookup.
        NSMutableDictionary *bySource = [NSMutableDictionary dictionary];
        for (NSString *identifier in target) {
            bySource[identifier] = @{@"identifier":identifier,@"source":target[identifier],
                @"state":@"unavailable",@"assetPresent":@NO,@"recordCount":@0,
                @"readFailures":@0,@"plain":@"",@"entries":@[]};
        }
        for (id dictionary in dictionaries) {
            CFTypeRef d = (__bridge CFTypeRef)dictionary;
            NSString *display = stringValue(name(d));
            NSURL *dictURL = url ? (__bridge NSURL *)url(d) : nil;
            NSString *identifier = dictURL ? [[NSBundle bundleWithURL:dictURL] bundleIdentifier] : nil;
            if (!identifier || !target[identifier]) {
                if ([display isEqualToString:@"Oxford Dictionary of English"]) identifier=@"com.apple.dictionary.ODE";
                else if ([display containsString:@"Oxford American Writer"] && [display containsString:@"Thesaurus"]) identifier=@"com.apple.dictionary.OAWT";
                else if ([display isEqualToString:@"Oxford Chinese Dictionary"]) identifier=@"com.apple.dictionary.zh_CN-en.OCD";
            }
            if (!identifier || !target[identifier]) continue;
            NSArray *generation = localAssetGeneration(dictURL);
            BOOL assetPresent = generation != nil;
            CFArrayRef found = records(d, (__bridge CFStringRef)term, 0, 0);
            id itemsObject = CFBridgingRelease(found);
            BOOL invalidRecords = itemsObject && ![itemsObject isKindOfClass:[NSArray class]];
            NSArray *items = [itemsObject isKindOfClass:[NSArray class]] ? itemsObject : @[];
            NSMutableArray *entries = [NSMutableArray array];
            NSUInteger readFailures = invalidRecords ? 1 : 0;
            for (id record in items) {
                CFTypeRef r = (__bridge CFTypeRef)record;
                NSString *word = stringValue(head(r));
                NSString *root = rawHead ? stringValue(rawHead(r)) : @"";
                if (word.length == 0 && root.length == 0) { readFailures++; continue; }
                CFTypeRef value = data(r);
                if (!value) { readFailures++; continue; }
                id object = CFBridgingRelease(value);
                NSString *html = nil;
                if ([object isKindOfClass:[NSString class]]) html = object;
                else if ([object isKindOfClass:[NSData class]]) html = [[NSString alloc] initWithData:object encoding:NSUTF8StringEncoding];
                if (html.length==0) { readFailures++; continue; }
                [entries addObject:@{@"head":word,@"rawHead":root,@"html":html}];
                if (entries.count>=8) break;
            }
            // Same-source public API: a plain-text safety net, not a different
            // dictionary. A known common word proves that an empty search was
            // made against a readable source, even if the asset changed paths.
            NSString *plain = plainDefinition(d, term);
            BOOL ready = entries.count > 0 || plain.length > 0;
            if (!ready && assetPresent) {
                // Don't certify a negative result if the resource was changed
                // between searching the term and probing a known word.
                BOOL healthy = plainDefinition(d, @"important").length > 0;
                ready = healthy && [generation isEqualToArray:localAssetGeneration(dictURL)];
            }
            NSDictionary *candidate = @{@"identifier":identifier,@"source":target[identifier],
                @"state":ready?@"ready":@"unavailable",@"assetPresent":@(assetPresent),
                @"recordCount":@(items.count),@"readFailures":@(readFailures),
                @"plain":plain,@"entries":entries};
            // Prefer a readable copy if Apple exposes duplicate identifiers.
            if (![bySource[identifier][@"state"] isEqual:@"ready"] || ready) bySource[identifier] = candidate;
        }
        NSArray *output = [bySource allValues];
        NSError *err = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:output options:0 error:&err];
        if (!json) return 6;
        [[NSFileHandle fileHandleWithStandardOutput] writeData:json];
        return 0;
    }
}

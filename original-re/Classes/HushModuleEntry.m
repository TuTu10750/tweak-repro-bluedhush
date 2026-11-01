// Recovered from BluedHush_5.19.dylib @ class index 80 (HushModuleEntry)
// One top-level card on the settings root page.
#import "HushModuleEntry.h"

@implementation HushModuleEntry

@synthesize title = _title;
@synthesize icon = _icon;
@synthesize subtitle = _subtitle;
@synthesize footer = _footer;
@synthesize sections = _sections;
@synthesize items = _items;

- (NSString *)description {
    return [NSString stringWithFormat:@"<HushModuleEntry '%@' sections=%lu items=%lu>",
            _title, (unsigned long)[_sections count], (unsigned long)[_items count]];
}

@end

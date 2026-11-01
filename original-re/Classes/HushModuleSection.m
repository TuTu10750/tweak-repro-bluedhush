// Recovered from BluedHush_5.19.dylib @ class index 79 (HushModuleSection)
// One grouped section inside a module detail page.
#import "HushModuleSection.h"

@implementation HushModuleSection

@synthesize title = _title;
@synthesize icon = _icon;
@synthesize subtitle = _subtitle;
@synthesize items = _items;

+ (id)title:(id)a0 icon:(id)a1 subtitle:(id)a2 items:(id)a3 {
    HushModuleSection *s = [[HushModuleSection alloc] init];
    s->_title = [a0 copy];
    s->_icon = [a1 copy];
    s->_subtitle = [a2 copy];
    s->_items = [a3 copy];
    return s;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<HushModuleSection '%@' items=%lu>", _title, (unsigned long)[_items count]];
}

@end

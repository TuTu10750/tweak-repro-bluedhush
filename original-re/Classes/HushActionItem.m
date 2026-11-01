// Recovered from BluedHush_5.19.dylib @ class index 77 (HushActionItem)
// Data model for one action row (button that runs a block, not a persisted switch).
#import "HushActionItem.h"

@implementation HushActionItem

@synthesize title = _title;
@synthesize subtitle = _subtitle;
@synthesize icon = _icon;
@synthesize actionLabel = _actionLabel;
@synthesize handler = _handler;

+ (id)title:(id)a0 subtitle:(id)a1 actionLabel:(id)a2 handler:(id /* ^block */)a3 {
    return [self title:a0 subtitle:a1 icon:nil actionLabel:a2 handler:a3];
}

+ (id)title:(id)a0 subtitle:(id)a1 icon:(id)a2 actionLabel:(id)a3 handler:(id /* ^block */)a4 {
    HushActionItem *item = [[HushActionItem alloc] init];
    item->_title = [a0 copy];
    item->_subtitle = [a1 copy];
    item->_icon = [a2 copy];
    item->_actionLabel = [a3 copy];
    item->_handler = [a4 copy];
    return item;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<HushActionItem '%@' label=%@>", _title, _actionLabel];
}

@end

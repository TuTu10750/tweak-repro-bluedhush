// Recovered from BluedHush_5.19.dylib @ class index 78 (HushSwitchItem)
// Data model for one switch row inside a module section.
#import "HushSwitchItem.h"

@implementation HushSwitchItem

@synthesize key = _key;
@synthesize title = _title;
@synthesize subtitle = _subtitle;
@synthesize icon = _icon;
@synthesize effect = _effect;

+ (id)key:(id)a0 title:(id)a1 subtitle:(id)a2 {
    return [self key:a0 title:a1 subtitle:a2 icon:nil effect:0];
}

+ (id)key:(id)a0 title:(id)a1 subtitle:(id)a2 effect:(long long)a3 {
    return [self key:a0 title:a1 subtitle:a2 icon:nil effect:a3];
}

+ (id)key:(id)a0 title:(id)a1 subtitle:(id)a2 icon:(id)a3 {
    return [self key:a0 title:a1 subtitle:a2 icon:a3 effect:0];
}

+ (id)key:(id)a0 title:(id)a1 subtitle:(id)a2 icon:(id)a3 effect:(long long)a4 {
    HushSwitchItem *item = [[HushSwitchItem alloc] init];
    item->_key = [a0 copy];
    item->_title = [a1 copy];
    item->_subtitle = [a2 copy];
    item->_icon = [a3 copy];
    item->_effect = a4;
    return item;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<HushSwitchItem %@ '%@' effect=%lld>", _key, _title, _effect];
}

@end

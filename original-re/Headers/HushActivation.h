//
//  HushActivation.h
//  BluedHushRE
//
//  Source-level reconstruction of the original licence gate.
//
//  Recovered shape (BluedHush_5.19.4_1031-0011.dylib):
//
//      0x1be2c  _HushActivationIsActive      reads one byte at *(0x299000+0xf08)
//      0x1bda4  _HushKeyNeedsActivation(k)   [_HushActivationGatedKeys() containsObject:k]
//      0x1c14c  _HushActivationInterceptToggle  refuses setEnabled: when gated && !active
//
//  Every reader of the state inlines the byte load instead of calling
//  IsActive, so in the shipped tweak the flag is a single global that three
//  places write:
//
//      0x1bec4  strb w0,  [x8,#0xf08]   boot dispatch_once block
//      0x1c9e0  strb w26, [x8,#0xf08]   successful activation (w26 = 1)
//      0x1daec  strb wzr, [x8,#0xf08]   deactivate / failed re-check
//
//  This file keeps the same three-part shape.  The one intentional difference
//  is the *source* of the flag: the RE build has no licence server, so it
//  starts active and exposes a setter instead of an activation-code parser.
//  Mechanism (byte gate + gated key set + toggle interceptor) is identical;
//  the policy is "always activated".
//

#import <Foundation/Foundation.h>

/// YES when the activation overlay is satisfied. Mirrors @0x1be2c.
FOUNDATION_EXPORT BOOL HushActivationIsActive(void);

/// Flip the flag at runtime, i.e. what the original's byte writers did.
FOUNDATION_EXPORT void HushActivationSetActive(BOOL active);

/// The 17 keys that require activation (original: 8 tracking + 9 unlocks).
/// Mirrors @0x1bbf8 _HushActivationGatedKeys.
FOUNDATION_EXPORT NSArray<NSString *> *HushActivationGatedKeys(void);

/// True when `key` sits in the gated set. Declared in HushRuntime.h as well;
/// the definition stays next to the config cache that calls it.
FOUNDATION_EXPORT BOOL HushKeyNeedsActivationPair(NSString *key);

/// Publish the initial state, seal the activation cache and log one status
/// line, exactly like the original's boot block did.
FOUNDATION_EXPORT void HushActivationInstall(void);

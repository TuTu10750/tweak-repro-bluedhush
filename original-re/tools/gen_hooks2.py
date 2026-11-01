# -*- coding: utf-8 -*-
"""
Regenerate Hooks/Hooks.generated.xm with REAL host method signatures.

Why this exists
---------------
The v1 generator (gen_hooks.py) emitted `- (id)<sel>:(id)a0 ... { return %orig; }`
for every hook because it only had (class, selector) pairs and no type encoding.

That is fatal under -fobjc-arc: ARC materialises a __strong temporary for each
object-typed parameter and calls objc_storeStrong() on it. For a method whose
real parameter is `NSError **` (encoding ^@) the "object" is actually a
pointer-to-pointer, so ARC retains a non-object -> objc_retain reads a bogus
isa and the process dies with EXC_BAD_ACCESS at a tiny address.

Confirmed crash (Blued-2026-11-01-192236.ips):
    #0 objc_retain
    #1 objc_storeStrong
    #2 _logos_method$_ungrouped$BDNetworkAgent$sessionTaskForRequest$error$
    real type encoding: @32@0:8@16^@24
    disassembly: 0x4ba58 bl objc_storeStrong   ; retain(NSError **)

Fix strategy (two independent safe nets):
  1. emit the real signature read from the host binary, so pointer parameters
     are typed as pointers and ARC no longer retains them;
  2. compile this file with -fno-objc-arc anyway (see Makefile), because a
     signature we could not resolve falls back to the generic `id` form.

Input : _work/host_probe.json  (resolved[] carries the host type encoding)
Output: Hooks/Hooks.generated.xm
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = os.path.join(os.path.dirname(os.path.dirname(ROOT)), '_work', 'host_probe.json')
TARGET = os.path.join(ROOT, 'Hooks', 'Hooks.generated.xm')
TABLE = os.path.join(ROOT, 'Hooks', 'hooks.tsv')

# ---------------------------------------------------------------- type decoding

# Struct names we can render as ObjC types because UIKit/CoreGraphics are linked.
STRUCTS = {
    'CGRect', 'CGPoint', 'CGSize', 'CGVector', 'CGAffineTransform',
    'UIEdgeInsets', 'UIOffset', 'NSRange', 'CATransform3D',
}
# Scalar encodings -> ObjC type spelling.
SCALARS = {
    'c': 'char', 'i': 'int', 's': 'short', 'l': 'long', 'q': 'long long',
    'C': 'unsigned char', 'I': 'unsigned int', 'S': 'unsigned short',
    'L': 'unsigned long', 'Q': 'unsigned long long',
    'f': 'float', 'd': 'double', 'B': 'BOOL', 'v': 'void',
    '*': 'char *', '#': 'Class', ':': 'SEL', '?': 'void *',
}


def _skip_qualifiers(s, i):
    """Skip const/in/out/inout/bycopy/byref/oneway qualifiers."""
    while i < len(s) and s[i] in 'rnNoORV':
        i += 1
    return i


def _parse_one(s, i):
    """Parse one type encoding starting at i. Returns (objc_type, next_index)."""
    i = _skip_qualifiers(s, i)
    if i >= len(s):
        return ('id', i)

    c = s[i]

    if c == '@':
        i += 1
        if i < len(s) and s[i] == '?':          # block
            return ('id /*block*/', i + 1)
        if i < len(s) and s[i] == '"':          # @"ClassName"
            j = s.index('"', i + 1)
            name = s[i + 1:j]
            return (name + ' *', j + 1)
        return ('id', i)

    if c == '^':                                # pointer
        inner, j = _parse_one(s, i + 1)
        return (inner + ' *', j)

    if c == '{':                                # struct
        depth, j = 0, i
        while j < len(s):
            if s[j] == '{':
                depth += 1
            elif s[j] == '}':
                depth -= 1
                if depth == 0:
                    j += 1
                    break
            j += 1
        name = s[i + 1:].split('=')[0].split('}')[0]
        name = re.sub(r'[^A-Za-z0-9_]', '', name)
        if name in STRUCTS:
            return (name, j)
        return ('void * /*%s*/' % (name or 'anon'), j)

    if c == '[':                                # array
        depth, j = 0, i
        while j < len(s):
            if s[j] == '[':
                depth += 1
            elif s[j] == ']':
                depth -= 1
                if depth == 0:
                    j += 1
                    break
            j += 1
        return ('void *', j)

    if c == '(':                                # union
        depth, j = 0, i
        while j < len(s):
            if s[j] == '(':
                depth += 1
            elif s[j] == ')':
                depth -= 1
                if depth == 0:
                    j += 1
                    break
            j += 1
        return ('void *', j)

    if c == 'b':                                # bitfield
        j = i + 1
        while j < len(s) and s[j].isdigit():
            j += 1
        return ('unsigned int', j)

    if c in SCALARS:
        return (SCALARS[c], i + 1)

    # unknown encoding: consume one char, degrade to id
    return ('id', i + 1)


def _skip_offset(s, i):
    while i < len(s) and s[i].isdigit():
        i += 1
    return i


def decode_types(enc):
    """'@32@0:8@16^@24' -> ('id', ['id', 'id *']).

    Layout is: <ret><off><self><off>:<off><arg1><off><arg2><off>...
    self and _cmd are structural, never real arguments.
    """
    if not enc:
        return ('id', [])
    ret, i = _parse_one(enc, 0)
    i = _skip_offset(enc, i)

    # receiver slot (always @)
    if i < len(enc) and enc[i] == '@':
        _, i = _parse_one(enc, i)
        i = _skip_offset(enc, i)

    # _cmd slot (always :)
    if i < len(enc) and enc[i] == ':':
        i += 1
        i = _skip_offset(enc, i)

    args = []
    while i < len(enc):
        t, i = _parse_one(enc, i)
        i = _skip_offset(enc, i)
        args.append(t)
    return (ret, args)


def objc_param_type(t):
    """Turn a decoded type into something safe to put in a selector signature."""
    if t.endswith(' *'):
        # id * / NSError * * / char * are all pointers; keep them explicit
        return t.replace('  ', ' ')
    return t


# ---------------------------------------------------------------- generation

def split_selector(sel):
    """'a:b:c:' -> ['a', 'b', 'c'] ; 'foo' -> []"""
    if not sel.endswith(':'):
        return []
    return [p for p in sel.split(':')[:-1]]


def build_signature(ret, args, sel):
    """Render an ObjC method declaration with Logos %orig body."""
    parts = split_selector(sel)
    ret_t = ret if ret != 'void' else 'void'

    if not parts:
        params = ''
    else:
        chunks = []
        for idx, p in enumerate(parts):
            t = objc_param_type(args[idx]) if idx < len(args) else 'id'
            chunks.append('%s:(%s)a%d' % (p, t, idx))
        params = ' '.join(chunks)

    body = '%orig;' if ret_t == 'void' else 'return %orig;'
    return '- (%s)%s { %s }' % (ret_t, params, body)


def main():
    if not os.path.exists(PROBE):
        sys.exit('missing probe file: %s' % PROBE)
    probe = json.load(open(PROBE, encoding='utf-8'))
    resolved = probe['resolved']

    # (cls, sel) -> real type encoding from the host binary
    sig = {}
    for r in resolved:
        sig[(r['cls'], r['sel'])] = r.get('types') or ''

    # The authoritative (cls, sel) list is the one the ORIGINAL dylib hooks,
    # which the recovered tree already records in hooks.tsv.
    pairs = []
    seen = set()
    with open(TABLE, encoding='utf-8') as fh:
        next(fh, None)
        for line in fh:
            line = line.rstrip('\n')
            if not line:
                continue
            cls, sel = line.split('\t')[0], line.split('\t')[1]
            if (cls, sel) in seen:
                continue
            seen.add((cls, sel))
            pairs.append((cls, sel))

    by_cls = {}
    for cls, sel in pairs:
        by_cls.setdefault(cls, []).append(sel)

    out = []
    out.append('// Recovered hook layer for BluedHush 5.19 — signatures from the host binary.')
    out.append('// %d unique (class, selector) pairs across %d host classes.' % (len(pairs), len(by_cls)))
    out.append('//')
    out.append('// Every body is a pure passthrough (%orig). Two safety nets keep this from')
    out.append('// faulting on argument values we do not touch:')
    out.append('//   1. real type encodings below (pointer params stay pointers, so ARC')
    out.append('//      never objc_retain()s an NSError **);')
    out.append('//   2. this translation unit is compiled with -fno-objc-arc (see Makefile),')
    out.append('//      so any unresolved signature that fell back to `id` still cannot')
    out.append('//      trigger a spurious objc_storeStrong().')
    out.append('')
    out.append('#import <Foundation/Foundation.h>')
    out.append('#import <UIKit/UIKit.h>')
    out.append('#import <CoreLocation/CoreLocation.h>')
    out.append('#import <MapKit/MapKit.h>')
    out.append('#import <CoreGraphics/CoreGraphics.h>')
    out.append('#import <objc/runtime.h>')
    out.append('')
    out.append('// ---- host classes referenced by the original hook table ----')
    for cls in by_cls:
        out.append('@class %s;' % cls)
    out.append('')

    stats = {'typed': 0, 'generic': 0}
    for cls, sels in by_cls.items():
        out.append('%%hook %s' % cls)
        for sel in sels:
            enc = sig.get((cls, sel))
            if enc:
                ret, args = decode_types(enc)
                out.append(build_signature(ret, args, sel))
                stats['typed'] += 1
            else:
                # No host type encoding: keep the generic form. Safe only because
                # this file is MRC — no ARC retain is generated for `id` params.
                parts = split_selector(sel)
                if not parts:
                    out.append('- (id)%s { return %%orig; }' % sel)
                else:
                    params = ' '.join('%s:(id)a%d' % (p, i) for i, p in enumerate(parts))
                    out.append('- (id)%s { return %%orig; }' % params)
                stats['generic'] += 1
        out.append('%end')
        out.append('')

    open(TARGET, 'w', encoding='utf-8').write('\n'.join(out) + '\n')

    # refresh hooks.tsv with the resolved signature so downstream tools see it
    rows = ['class\tselector\tsite\treplacement\told_slot\ttypes']
    with open(TABLE, encoding='utf-8') as fh:
        next(fh, None)
        for line in fh:
            line = line.rstrip('\n')
            if not line:
                continue
            f = line.split('\t')
            key = (f[0], f[1])
            f = f[:5] + [sig.get(key, '')]
            rows.append('\t'.join(f))
    open(TABLE, 'w', encoding='utf-8').write('\n'.join(rows) + '\n')

    print('wrote %s' % TARGET)
    print('  hooks: %d   typed: %d   generic fallback: %d'
          % (len(pairs), stats['typed'], stats['generic']))


if __name__ == '__main__':
    main()

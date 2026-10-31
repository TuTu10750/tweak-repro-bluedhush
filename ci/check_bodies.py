"""Static sanity pass over the recovered method bodies.

clang is not available on this host, so this mirrors the checks clang would
reject first: unresolved markers left in live code, argument references past
the declared arity, semicolons inside a condition, unbalanced delimiters and a
bare `super` used as a value.
"""
import io
import os
import re
import sys

SRC = r'D:\DeepSeek\hush\BluedHush-Original-RE\Classes-recovered'
SIGLINE = re.compile(r'^\s*[-+]\s*\(')
UIDENT = re.compile(r'\bunknownSelector\b')
ARGS = re.compile(r'\ba(\d+)\b')
BARE_SUPER = re.compile(r'(?<![\w\[])\bsuper\b(?!\w)')


def scan_line(code, nargs):
    problems = []
    if UIDENT.search(code):
        problems.append('unknownSelector')
    if '/*' in code:
        problems.append('inline-comment')
    if nargs is not None:
        for m in ARGS.finditer(code):
            if int(m.group(1)) >= nargs:
                problems.append('arg%d>=nargs%d' % (int(m.group(1)), nargs))
    if BARE_SUPER.search(code) and '[super' not in code:
        problems.append('bare-super')
    m = re.search(r'if\s*\((.*)\)\s*goto', code)
    if m and ';' in m.group(1):
        problems.append('semicolon-in-cond')
    if re.search(r';\s*[\]\)]', code):
        problems.append('semicolon-before-close')
    if code.count('(') != code.count(')'):
        problems.append('paren-imbalance')
    if code.count('[') != code.count(']'):
        problems.append('bracket-imbalance')
    if code.count('{') != code.count('}'):
        problems.append('brace-imbalance')
    return problems


def main():
    total = 0
    bad = 0
    unresolved = 0
    kinds = {}
    for fn in sorted(os.listdir(SRC)):
        if not fn.endswith('.m'):
            continue
        lines = io.open(os.path.join(SRC, fn), encoding='utf-8').read().split('\n')
        nargs = None
        for i, line in enumerate(lines, 1):
            st = line.strip()
            if SIGLINE.match(line) and st.endswith('{'):
                nargs = line.count(':')
                continue
            if st.startswith('//'):
                continue
            if st.startswith('/*'):
                if '[UNRESOLVED]' in st:
                    unresolved += 1
                continue
            if not st:
                continue
            code = re.sub(r'/\*.*?\*/', '', line)
            if not code.strip() or code.strip() == '}':
                continue
            total += 1
            for p in scan_line(code, nargs):
                bad += 1
                kinds[p] = kinds.get(p, 0) + 1
                if bad <= 15:
                    print('BAD %s:%d %s | %s' % (fn, i, p, st[:70]))
    print('---')
    print('real_code_lines', total, 'problems', bad, 'unresolved_comments', unresolved)
    for k, v in sorted(kinds.items(), key=lambda kv: -kv[1]):
        print('  ', k, v)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())

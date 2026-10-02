#!/usr/bin/env python3
"""Lightweight structural validator for DTS files.

This environment's dtc 1.7.2 is a stripped build (no #include / #define /
/include/, and only a single root node), so it cannot compile real DTS that
uses the preprocessor or top-level &phandle references.  This script performs
the grammar/structure checks that apply across the whole file:
  - balanced {} brackets (strings/quotes stripped first)
  - balanced < > and ( )
  - every logical line is one of: root node, named node, &ref node, close,
    boolean prop (key;), property (key = ...; possibly multi-line), or
    array/prop continuation line.
"""
import re, sys

NODE_RE  = re.compile(r'^([A-Za-z0-9_\-]+\s*:\s*)?[A-Za-z0-9_,.\-]+\s*(@[0-9a-fA-Fx]+)?\s*\{\s*$')
REF_RE   = re.compile(r'^&[A-Za-z0-9_\-]+\s*\{\s*$')
ROOT_RE  = re.compile(r'^/\s*\{\s*$')
CLOSE_RE = re.compile(r'^\s*\}\s*;?\s*$')
BOOL_RE  = re.compile(r'^[A-Za-z0-9_,.\-]+;$')
PROP_RE  = re.compile(r'^[A-Za-z0-9_,.\-]+\s*=.*$')
CONT_RE  = re.compile(r'^\s*[<&"]')


def check(path):
    txt = open(path).read()
    txt = re.sub(r'/\*.*?\*/', '', txt, flags=re.S)   # block comments
    txt = re.sub(r'//[^\n]*', '', txt)                 # line comments
    raw = txt.split('\n')
    # join backslash-continued physical lines into logical lines
    lines, buf = [], ''
    for ln in raw:
        if ln.endswith('\\'):
            buf += ln[:-1]
        else:
            lines.append(buf + ln)
            buf = ''
    if buf:
        lines.append(buf)

    problems = []
    nos = re.sub(r'"[^"]*"', '""', txt)                # ignore strings for bracket counts
    if nos.count('{') != nos.count('}'):
        problems.append("brace mismatch: %d { vs %d }" % (nos.count('{'), nos.count('}')))
    if nos.count('<') != nos.count('>'):
        problems.append("angle mismatch: %d < vs %d >" % (nos.count('<'), nos.count('>')))

    depth = maxd = 0
    angle_depth = 0  # currently inside an (unclosed) <...> array value
    for i, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line:
            continue
        if line.startswith('#') or line.startswith('/include') or line.startswith('/dts-v1'):
            continue

        if line.count('{') + line.count('}') == 0:
            # Inside an open array: the whole line is array content.
            if angle_depth > 0:
                angle_depth += line.count('<') - line.count('>')
                continue
            ok = bool(NODE_RE.match(line) or CLOSE_RE.match(line) or
                      BOOL_RE.match(line) or PROP_RE.match(line) or CONT_RE.match(line))
            if not ok:
                problems.append("line %d: odd line: %s" % (i, line[:70]))
            angle_depth += line.count('<') - line.count('>')
            if angle_depth < 0:
                angle_depth = 0
            continue

        o, c = line.count('{'), line.count('}')
        if o and not c:
            ok = bool(NODE_RE.match(line) or REF_RE.match(line) or ROOT_RE.match(line))
            if not ok:
                problems.append("line %d: bad node header: %s" % (i, line[:70]))
        elif c and not o:
            if not CLOSE_RE.match(line):
                problems.append("line %d: bad close: %s" % (i, line[:70]))
        depth += o - c
        maxd = max(maxd, depth)
        if depth < 0:
            problems.append("line %d: depth went negative" % i)
    if depth != 0:
        problems.append("final depth %d != 0" % depth)

    status = "OK" if not problems else "FAIL"
    print("[%s] %s  (max depth %d)" % (status, path, maxd))
    for p in problems:
        print("    " + p)
    return not problems


if __name__ == '__main__':
    ok = True
    for f in sys.argv[1:]:
        ok &= check(f)
    sys.exit(0 if ok else 1)

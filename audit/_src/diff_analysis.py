#!/usr/bin/env python3
# Source-level diff: Glimpse v1.3.0 -> v1.5.1 (upstream evolution), and what 美术馆 lacks.
import re, sys, urllib.request, ssl, os, difflib

def fetch(ref):
    url = "https://raw.githubusercontent.com/Fank1/glimpse/%s/plugin/main.lua" % ref
    ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
    return urllib.request.urlopen(url, context=ctx, timeout=60).read().decode("utf-8", "replace")

WORK = "E:/Download/AIWorkshop/artgallery.koplugin"
art_path = WORK + "/main.lua"

# Download upstream sources into this process (ephemeral OK: same call)
v130 = fetch("v1.3.0")
v151 = fetch("v1.5.1")
with open(art_path, "r", encoding="utf-8", errors="replace") as f:
    art = f.read()

FILES = {"v1.3.0": v130, "v1.5.1": v151, "artgallery": art}

# Extract function/method definition names (normalized: strip Glimpse/glimpse -> ArtGallery/artgallery)
def normalize(s):
    return s.replace("Glimpse","ArtGallery").replace("glimpse","artgallery")

def defs(src):
    names = set()
    for m in re.finditer(r'(?:local\s+)?function\s+([A-Za-z_][A-Za-z0-9_.:]*)\s*\(', src):
        names.add(normalize(m.group(1)))
    # Class:method = function
    for m in re.finditer(r'([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*function', src):
        names.add(normalize(m.group(1)))
    return names

d130 = defs(v130)
d151 = defs(v151)
da   = defs(art)

upstream_new = sorted(d151 - d130)            # added in v1.5.1 vs v1.3.0
art_missing  = sorted(d151 - da)             # in v1.5.1 but not in artgallery (candidates)

print("=== sizes (chars) ===")
for k,v in FILES.items():
    print(k, len(v))

print("\n=== UPSTREAM NEW defs v1.3.0 -> v1.5.1 (count=%d) ===" % len(upstream_new))
for n in upstream_new:
    print("  +", n)

print("\n=== in v1.5.1 but NOT in artgallery (candidates to absorb, count=%d) ===" % len(art_missing))
for n in art_missing:
    print("  *", n)

# Show actual added code hunks (source-grounded) for context
print("\n=== ADDED CODE BLOCKS (v1.3.0 -> v1.5.1), grouped by enclosing function ===")
a = v130.splitlines()
b = v151.splitlines()
sm = difflib.SequenceMatcher(None, a, b)
for tag,i1,i2,j1,j2 in sm.get_opcodes():
    if tag == "insert":
        # find enclosing function name in b before j1
        ctx = ""
        for k in range(j1-1, max(-1,j1-40), -1):
            line = b[k]
            m = re.search(r'function\s+([A-Za-z_:.]+)', line)
            if m:
                ctx = m.group(1); break
        block = b[j1:j2]
        if len(block) <= 1 and not any(re.search(r'function|self[.:]', x) for x in block):
            continue
        print("\n--- @%s : lines %d-%d (added %d lines) ---" % (ctx, j1, j2, len(block)))
        for ln in block[:12]:
            print("   ", ln[:120])
        if len(block) > 12:
            print("   ...(+%d more)" % (len(block)-12))

#!/usr/bin/env python3
import re, urllib.request, ssl

def fetch(ref, path="plugin/main.lua"):
    url = "https://raw.githubusercontent.com/Fank1/glimpse/%s/%s" % (ref, path)
    ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
    return urllib.request.urlopen(url, context=ctx, timeout=60).read().decode("utf-8", "replace")

v130 = fetch("v1.3.0")
v151 = fetch("v1.5.1")
chlog = fetch("v1.5.1", "CHANGELOG.md")

with open("E:/Download/AIWorkshop/artgallery.koplugin/main.lua","r",encoding="utf-8",errors="replace") as f:
    art = f.read()

def norm(s): return s.replace("Glimpse","ArtGallery").replace("glimpse","artgallery")
def defs(src):
    s=set()
    for m in re.finditer(r'(?:local\s+)?function\s+([A-Za-z_][A-Za-z0-9_.:]*)\s*\(', src): s.add(norm(m.group(1)))
    for m in re.finditer(r'([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*function', src): s.add(norm(m.group(1)))
    return s

d130=defs(v130); d151=defs(v151); da=defs(art)
new151 = sorted(d151 - d130)
missing = sorted(d151 - da)

# For each new151 function, grab its definition region from v151 (signature + leading comment)
def grab_body(src, name):
    # find "function NAME" or "NAME = function"
    pat = re.compile(r'(?:local\s+)?function\s+' + re.escape(name) + r'\s*\(|' + re.escape(name) + r'\s*=\s*function')
    for m in re.finditer(pat, src):
        start=m.start()
        # back up to capture a leading comment block
        line_start = src.rfind("\n", 0, start)+1
        # find the line where this def's signature is
        # gather first ~14 lines from start
        end = src.find("\n", start)
        block_lines = src[start:].split("\n")
        out=[]
        # include preceding comment lines
        i = line_start
        # grab preceding comment lines (up to 6)
        prev = src[:line_start].split("\n")
        cm=[]
        for pl in reversed(prev[-8:]):
            if re.match(r'\s*--', pl) or pl.strip()=="":
                cm.insert(0, pl)
            else:
                break
        head = "\n".join(cm).strip()
        body = "\n".join(block_lines[:10])
        return head, body
    return "", ""

# group by prefix
import collections
groups = collections.defaultdict(list)
for n in new151:
    if "MiniMap" in n: groups["MiniMap 迷你地图"].append(n)
    elif "Layout" in n or "layout" in n or "Align" in n or "portrait" in n: groups["Layout 布局/抽屉位置"].append(n)
    elif "TabSwitcher" in n or "switchGalleryTab" in n: groups["TabSwitcher 标签切换"].append(n)
    elif "Zoom" in n or "zoom" in n or "Pinch" in n or "Spread" in n or "HoldRelease" in n: groups["Zoom 缩放/手势"].append(n)
    elif "Bookmark" in n or "bookmark" in n or "dogear" in n or "Dogear" in n: groups["Bookmark 书签/狗耳"].append(n)
    elif "bbCache" in n or "Cache" in n: groups["bbCache 位图缓存"].append(n)
    elif "Dim" in n or "Veil" in n: groups["DimVeil 遮罩"].append(n)
    elif "prefetch" in n or "Neighbor" in n or "repaint" in n or "updateImage" in n or "displayedImage" in n or "recentre" in n or "recenter" in n or "growForShadow" in n or "flash" in n: groups["渲染/预取优化"].append(n)
    else: groups["Other 其他"].append(n)

print("=== UPSTREAM EVOLUTION v1.3.0 -> v1.5.1 (new defs by area) ===")
for g in sorted(groups):
    print("\n## %s (%d)" % (g, len(groups[g])))
    for n in groups[g]:
        head, body = grab_body(v151, n)
        print("  - %s" % n)
        if head:
            print("      doc: %s" % head[:160].replace("\n"," | "))
        print("      sig: %s" % body.split('\n')[0][:120])

print("\n=== sanity: CHANGELOG v1.5.1 mentioned features (cross-check) ===")
for line in chlog.splitlines():
    if re.match(r'^\s*[-*#]\s', line) and len(line) < 200:
        print("  ", line.strip()[:140])

#!/usr/bin/env bats
# index.html (the GitHub Pages landing page): the contract in openspec/changes/front-door
# (design.md "index.html contract", tasks 7.1-7.6). README.md is the copy source of truth: the hero
# sentence and the install command must match it byte for byte.
#
# Read-only: parses index.html with python3 -I (stdlib html.parser, no network, no ImageMagick).
# Portable: bash 3.2 and BSD userland safe (docs/portability.md).

export LC_ALL=C

GRID_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

load helpers/setup

setup() {
  common_setup
}

teardown() {
  common_teardown
}

# Shared python prelude: parse index.html once per test into a small DOM-ish record.
#   P.tags     list of (tag, attrs dict, depth-stack classes) in source order
#   P.text[id] text of the element with that id (h1 and #install-cmd are what tests need)
# Each test appends its own checks and exits non-zero (with a message on stderr) on failure.
PRELUDE='
import json, os, re, sys
from html.parser import HTMLParser

ROOT = os.environ["GRID_ROOT"]
HTML = open(os.path.join(ROOT, "index.html"), encoding="utf-8").read()

def die(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)

class P(HTMLParser):
    def __init__(self):
        HTMLParser.__init__(self, convert_charrefs=True)
        self.tags = []        # (tag, attrs, ancestors) per start tag, source order
        self.stack = []       # open (tag, attrs)
        self.h1 = []          # text collected inside each <h1>
        self.install = ""     # text inside #install-cmd
        self.title = ""
        self.ld = ""          # JSON-LD script text
        self._in_h1 = False
        self._in_install = False
        self._in_title = False
        self._title_seen = False   # only the <head> title counts; the SVG has its own <title>
        self._in_ld = False
        self._h1_buf = ""
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        self.tags.append((tag, a, list(self.stack)))
        if tag not in ("meta", "link", "img", "br", "hr", "input", "path", "rect", "stop"):
            self.stack.append((tag, a))
        if tag == "h1":
            self._in_h1 = True
            self._h1_buf = ""
        if a.get("id") == "install-cmd":
            self._in_install = True
        if tag == "title" and not self._title_seen:
            self._in_title = True
            self._title_seen = True
        if tag == "script" and a.get("type") == "application/ld+json":
            self._in_ld = True
    def handle_startendtag(self, tag, attrs):
        a = dict(attrs)
        self.tags.append((tag, a, list(self.stack)))
    def handle_endtag(self, tag):
        if tag == "h1":
            self._in_h1 = False
            self.h1.append(self._h1_buf)
        if tag == "code" and self._in_install:
            self._in_install = False
        if tag == "title":
            self._in_title = False
        if tag == "script":
            self._in_ld = False
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i][0] == tag:
                del self.stack[i:]
                break
    def handle_data(self, data):
        if self._in_h1:
            self._h1_buf += data
        if self._in_install:
            self.install += data
        if self._in_title:
            self.title += data
        if self._in_ld:
            self.ld += data

p = P()
p.feed(HTML)

def metas(attr):
    out = {}
    for tag, a, _ in p.tags:
        if tag == "meta" and attr in a:
            out[a[attr]] = a.get("content")
    return out

def links(rel):
    return [a for tag, a, _ in p.tags if tag == "link" and a.get("rel") == rel]

def readme():
    return open(os.path.join(ROOT, "README.md"), encoding="utf-8").read()

def readme_hero():
    for line in readme().split("\n"):
        if line.startswith("**Inspired by Tron."):
            return line[2:-2]
    die("README hero line not found")

def readme_install():
    m = re.search(r"## Quickstart\s+```bash\n(.*?)\n```", readme(), re.S)
    if not m:
        die("README quickstart command not found")
    return m.group(1)

def jpeg_size(path):
    # Walk the JPEG segments to the first SOFn marker: height then width, big-endian.
    d = open(path, "rb").read()
    if d[:2] != b"\xff\xd8":
        die(path + " is not a JPEG")
    i = 2
    while i < len(d):
        if d[i] != 0xFF:
            i += 1
            continue
        m = d[i + 1]
        if m in (0xD8, 0x01) or 0xD0 <= m <= 0xD7:
            i += 2
            continue
        ln = int.from_bytes(d[i + 2:i + 4], "big")
        if 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC):
            return int.from_bytes(d[i + 7:i + 9], "big"), int.from_bytes(d[i + 5:i + 7], "big")
        i += 2 + ln
    die("no SOF marker in " + path)

def site_files():
    out = []
    for line in open(os.path.join(ROOT, "site-files.txt"), encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if line:
            out.append(line)
    return out
'

# Helper: run one python check against index.html. $1 = the check body.
py() {
  GRID_ROOT="$GRID_ROOT" python3 -I -c "$PRELUDE
$1"
}

@test "landing page: exactly one h1, visible, equal to the README hero sentence" {
  py '
h1s = [(a, anc) for tag, a, anc in p.tags if tag == "h1"]
if len(h1s) != 1:
    die("expected one <h1>, found %d" % len(h1s))
a, anc = h1s[0]
classes = " ".join([a.get("class", "")] + [x[1].get("class", "") for x in anc])
if re.search(r"wordmark|visually-hidden|sr-only|hidden", classes):
    die("h1 sits in a hidden-looking class: " + classes)
if p.h1[0] != readme_hero():
    die("h1 text differs from README hero:\n%r\n%r" % (p.h1[0], readme_hero()))
'
}

@test "landing page: DOM order is h1, #install-cmd, the GitHub link, then the hero img; no picture" {
  py '
order = []
for tag, a, _ in p.tags:
    if tag == "h1": order.append("h1")
    elif a.get("id") == "install-cmd": order.append("install")
    elif tag == "a" and a.get("href") == "https://github.com/oneafrikan/the-grid": order.append("gh")
    elif tag == "img" and a.get("src") == "assets/hero.webp": order.append("img")
    elif tag == "picture": die("<picture> is not allowed")
first = []
for x in order:
    if x not in first: first.append(x)
if first != ["h1", "install", "gh", "img"]:
    die("DOM order is %r" % first)
img = [a for tag, a, _ in p.tags if tag == "img" and a.get("src") == "assets/hero.webp"][0]
if (img.get("width"), img.get("height")) != ("1600", "873") or img.get("alt") != "the-grid":
    die("hero img attributes: %r" % img)
'
}

@test "landing page: no min-height clamp(560px rule is left over" {
  ! grep -q 'min-height: clamp(560px' "$GRID_ROOT/index.html" || false
  # and the hero opts out of any min-height
  grep -qE '^[[:space:]]*min-height: 0;' "$GRID_ROOT/index.html"
}

@test "landing page: #install-cmd equals the README quickstart command, byte for byte" {
  py '
if p.install != readme_install():
    die("install command differs:\n%r\n%r" % (p.install, readme_install()))
'
}

@test "landing page: title, description, canonical, og and twitter metadata agree" {
  py '
TITLE = "the-grid: Claude Code skills and agents on every machine"
m = metas("name"); pr = metas("property")
desc = m.get("description")
if not desc or len(desc) > 160:
    die("meta description missing or over 160 chars: %r" % desc)
if p.title.strip() != TITLE or pr.get("og:title") != TITLE:
    die("title/og:title mismatch: %r / %r" % (p.title, pr.get("og:title")))
if pr.get("og:description") != desc:
    die("og:description differs from meta description")
canon = links("canonical")
if len(canon) != 1:
    die("expected one canonical link")
ld = json.loads(p.ld)
if not (canon[0]["href"] == pr.get("og:url") == ld.get("url")):
    die("canonical, og:url and JSON-LD url differ")
for k in ("og:title", "og:description", "og:image", "og:image:type", "og:image:width",
          "og:image:height", "og:image:alt", "og:url"):
    if not pr.get(k):
        die("missing " + k)
if pr["og:image:type"] != "image/jpeg":
    die("og:image:type is not image/jpeg")
if m.get("twitter:card") != "summary_large_image" or not m.get("twitter:image:alt"):
    die("twitter:card / twitter:image:alt wrong")
if m.get("color-scheme") != "dark":
    die("color-scheme meta is not dark")
'
}

@test "landing page: og:image file exists under assets/ and its pixel size matches og:image:width/height" {
  py '
pr = metas("property")
url = pr["og:image"]
base = "https://oneafrikan.github.io/the-grid/"
if not url.startswith(base + "assets/"):
    die("og:image is not an absolute URL under assets/: " + url)
path = os.path.join(ROOT, url[len(base):])
if not os.path.isfile(path):
    die("missing " + path)
w, h = jpeg_size(path)
if (str(w), str(h)) != (pr["og:image:width"], pr["og:image:height"]):
    die("og.jpg is %dx%d but og:image:width/height say %sx%s" % (w, h, pr["og:image:width"], pr["og:image:height"]))
if os.path.getsize(path) >= 250000:
    die("og.jpg is not under 250 KB")
'
}

@test "landing page: icon links are in order and their files exist" {
  py '
icons = [(a.get("rel"), a.get("href")) for tag, a, _ in p.tags
         if tag == "link" and a.get("rel") in ("icon", "apple-touch-icon")]
want = [("icon", "assets/favicon.svg"), ("icon", "assets/favicon-48.png"),
        ("apple-touch-icon", "assets/apple-touch-icon.png")]
if icons != want:
    die("icon links: %r" % icons)
for _, href in icons:
    if not os.path.isfile(os.path.join(ROOT, href)):
        die("missing " + href)
'
}

@test "landing page: JSON-LD parses as SoftwareSourceCode with the required fields and no WebSite node" {
  py '
ld = json.loads(p.ld)
if ld.get("@type") != "SoftwareSourceCode":
    die("@type is %r" % ld.get("@type"))
for k in ("name", "url", "codeRepository", "license"):
    if not ld.get(k):
        die("JSON-LD lacks " + k)
if not ld.get("author", {}).get("name"):
    die("JSON-LD lacks author.name")
if "WebSite" in p.ld:
    die("JSON-LD must not carry a WebSite node")
'
  ! grep -qi 'hreflang' "$GRID_ROOT/index.html" || false
}

@test "landing page: links point at the repo, never at relative .md files or external hosts" {
  py '
hrefs = [a.get("href", "") for tag, a, _ in p.tags if tag == "a"]
if "https://github.com/oneafrikan/the-grid" not in hrefs:
    die("no link to the repo")
for h in hrefs:
    if re.match(r"^[^:#]*\.md(#.*)?$", h):
        die("relative .md link (Pages does not render markdown): " + h)
for tag, a, _ in p.tags:
    if tag == "script" and a.get("src"):
        die("external script: " + a["src"])
    if tag == "link" and a.get("href", "").startswith("http") and a.get("rel") != "canonical":
        die("external link tag: " + a["href"])
'
}

@test "landing page: size budget and hero asset" {
  [ "$(wc -c < "$GRID_ROOT/index.html" | tr -d ' ')" -lt 100000 ]
  [ -f "$GRID_ROOT/assets/hero.webp" ]
  [ "$(wc -c < "$GRID_ROOT/assets/hero.webp" | tr -d ' ')" -lt 300000 ]
}

@test "landing page: the old 5.6 MB poster is gone" {
  ! grep -q 'the-grid\.png' "$GRID_ROOT/index.html" || false
  ! git -C "$GRID_ROOT" ls-files --error-unmatch the-grid.png >/dev/null 2>&1 || false
}

@test "landing page: every relative src/href is listed in site-files.txt and exists; index.html is listed" {
  py '
listed = site_files()
if "index.html" not in listed:
    die("index.html is not in site-files.txt")
for tag, a, _ in p.tags:
    for k in ("src", "href"):
        v = a.get(k)
        if not v or re.match(r"^([a-z][a-z0-9+.-]*:|#|//)", v):
            continue
        v = v.split("#", 1)[0].split("?", 1)[0]
        if not v:
            continue
        if v not in listed:
            die("%s is referenced by index.html but not listed in site-files.txt" % v)
        if not os.path.exists(os.path.join(ROOT, v)):
            die("%s is listed but does not exist" % v)
'
}

@test "landing page: no robots.txt or sitemap.xml is tracked" {
  [ -z "$(git -C "$GRID_ROOT" ls-files -- robots.txt sitemap.xml)" ]
}

@test "landing page: no leftover your-username placeholder" {
  # tests/ is excluded: other bats files name the placeholder on purpose, to assert its absence.
  run git -C "$GRID_ROOT" grep -l your-username -- . ':!openspec' ':!repos' ':!tests'
  # git grep exits 1 when nothing matches; any hit is a failure
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "landing page: Flynn attribution and the full monologue are present" {
  grep -q 'Kevin Flynn, <cite>TRON: Legacy</cite> (2010)' "$GRID_ROOT/index.html"
  grep -q 'A digital frontier\.' "$GRID_ROOT/index.html"
  grep -q 'I got in\.' "$GRID_ROOT/index.html"
}

@test "landing page: no bare '<N> skills/agents/roles' outside count markers" {
  py '
# Remove each marker with its value, then look for a bare number next to the words.
text = re.sub(r"<!--count:[^>]*?-->.*?<!--/count-->", "", HTML)
hits = re.findall(r"\b[0-9]{2,4}\s+(?:skills|agents|roles)\b", text)
if hits:
    die("typed counts outside markers: %r" % hits)
'
}

@test "landing page: stamp-counts.py --check passes" {
  run python3 -I "$GRID_ROOT/scripts/stamp-counts.py" --check
  [ "$status" -eq 0 ]
}

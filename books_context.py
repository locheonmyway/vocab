#!/usr/bin/env python3
"""Read-only Books context adapter, based on Reading/tools/scan_apple_books.py.

Evidence distinguishes a confirmed window title from a recently opened
candidate, and an existing highlighter/unique text match from the live page.
"""
import json
import pathlib
import re
import sqlite3
import sys
from html.parser import HTMLParser

ROOT = pathlib.Path.home() / "Library/Containers/com.apple.iBooksX/Data/Documents"


def newest(directory, pattern):
    return max((ROOT / directory).glob(pattern), key=lambda p: p.stat().st_mtime)


def norm(s):
    return re.sub(r"\s+", " ", s or "").strip()


class HTMLText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.suppressed = 0
        self.heading = ""
        self.in_heading = False

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style", "head"):
            self.suppressed += 1
        if tag in ("h1", "h2"):
            self.in_heading = True
        if tag in ("p", "div", "br", "li", "h1", "h2", "h3", "section"):
            self.parts.append(" ")

    def handle_endtag(self, tag):
        if tag in ("script", "style", "head"):
            self.suppressed = max(0, self.suppressed - 1)
        if tag in ("h1", "h2"):
            self.in_heading = False
        if tag in ("p", "div", "li", "h1", "h2", "h3", "section"):
            self.parts.append(" ")

    def handle_data(self, data):
        if not self.suppressed:
            self.parts.append(data)
            if self.in_heading and len(self.heading) < 120:
                self.heading += data


def unique_in_epub(path, term, hints=()):
    if not path or len(term) < 3:
        return None
    root = pathlib.Path(path)
    # Apple Books stores readable imported EPUBs as directories. Do not touch
    # encrypted assets or attempt to defeat platform/content restrictions.
    if not root.is_dir() or root.suffix.lower() != ".epub":
        return None
    # Try the exact OCR line, its intact inner anchor, then the selected term.
    # Scan the readable source once; require a unique match corroborated by
    # the actual selected expression. Cropped edges are never treated as text.
    anchors = list(dict.fromkeys([h for h in hints if h] + [term]))
    patterns = [re.compile(r"(?<!\w)" + re.escape(a) + r"(?!\w)", re.IGNORECASE) for a in anchors]
    target_pattern=re.compile(r"(?<!\w)"+re.escape(term)+r"(?!\w)",re.IGNORECASE)
    found = [None] * len(patterns)
    counts = [0] * len(patterns)
    total_bytes = 0
    for file in root.rglob("*"):
        if file.suffix.lower() not in (".html", ".xhtml", ".htm"):
            continue
        try:
            size = file.stat().st_size
            total_bytes += size
            if total_bytes > 25_000_000 or size > 3_000_000:
                return None  # incomplete search can't prove uniqueness
            parser = HTMLText()
            parser.feed(file.read_text(encoding="utf-8", errors="replace"))
            text = norm("".join(parser.parts))
            for i,pattern in enumerate(patterns):
                if counts[i]>1:
                    continue
                for m in pattern.finditer(text):
                    counts[i]+=1
                    if counts[i]>1:
                        found[i]=None
                        break
                    lo,hi=max(0,m.start()-240),min(len(text),m.end()+240)
                    excerpt=text[lo:hi].strip()
                    if target_pattern.search(excerpt):
                        found[i]={"context":excerpt,"location":str(file.relative_to(root)),"chapter":norm(parser.heading)[:120],"recordKind":"uniqueTextMatch"}
        except (OSError, ValueError):
            return None
    return next((match for count,match in zip(counts,found) if count==1 and match),None)


def intact_anchors(context, term):
    context,term=norm(context),norm(term)
    target=re.compile(r"(?<!\w)"+re.escape(term)+r"(?!\w)",re.I)
    if len(context.split())<4 or not target.search(context):
        return []
    words=context.split()
    trimmed=" ".join(words[1:-1])
    return [context]+([trimmed] if len(trimmed.split())>=3 and target.search(trimmed) else [])


def lookup(term, title, visible_context=""):
    term, title = norm(term), norm(title)
    if not term:
        return None
    anno = newest("AEAnnotation", "AEAnnotation*.sqlite")
    lib = newest("BKLibrary", "BKLibrary*.sqlite")
    conn = sqlite3.connect(lib.as_uri() + "?mode=ro", uri=True, timeout=1)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("ATTACH DATABASE ? AS anno", (anno.as_uri() + "?mode=ro",))
        books = conn.execute("""SELECT ZASSETID AS asset, ZTITLE AS title,
            ZAUTHOR AS author, ZPATH AS path, ZREADINGPROGRESS AS progress, ZLASTOPENDATE AS opened
            FROM ZBKLIBRARYASSET WHERE ZTITLE IS NOT NULL
            ORDER BY ZLASTOPENDATE DESC NULLS LAST""").fetchall()
        # Prefer a sufficiently distinctive title corroborated by the live window.
        matched = [b for b in books if len(norm(b["title"])) >= 3 and
                   (norm(b["title"]).casefold() == title.casefold() or
                    norm(b["title"]).casefold() in title.casefold())]
        exact = [b for b in matched if norm(b["title"]).casefold() == title.casefold()]
        match = (exact if exact else matched)
        confirmed = len(match) == 1
        book = match[0] if confirmed else next((b for b in books if b["opened"]), None)
        if book is None:
            return None
        result = {"assetID": book["asset"], "title": book["title"], "author": book["author"] or "",
                  "evidence": "windowTitle" if confirmed else "recentCandidate",
                  "progress": book["progress"]}
        if not confirmed:
            # No present-book claim or historical location from mere recency.
            return result
        rows = conn.execute("""SELECT ZANNOTATIONSELECTEDTEXT AS text,
            ZANNOTATIONLOCATION AS loc, ZANNOTATIONUUID AS uuid FROM anno.ZAEANNOTATION
            WHERE ZANNOTATIONASSETID=? AND ZANNOTATIONDELETED=0 AND ZANNOTATIONTYPE=2
            AND ZANNOTATIONSELECTEDTEXT IS NOT NULL""", (book["asset"],)).fetchall()
        pattern = re.compile(r"(?<!\w)" + re.escape(term) + r"(?!\w)", re.IGNORECASE)
        hits = [r for r in rows if pattern.search(norm(r["text"]))]
        if len(hits) == 1:
            r = hits[0]
            result.update(context=norm(r["text"]), location=r["loc"] or "",
                          highlightID=r["uuid"] or "", recordKind="existingHighlight")
        # A readable local source can supply a unique surrounding text match;
        # an existing highlight remains the stronger identified record.
        elif book["path"] and len(term) >= 3:
            hit = unique_in_epub(book["path"],term,intact_anchors(visible_context,term))
            if hit:
                result.update(hit)
        return result
    finally:
        conn.close()


if __name__ == "__main__":
    try:
        obj = json.load(sys.stdin)
        print(json.dumps(lookup(obj.get("term", ""), obj.get("windowTitle", ""), obj.get("visibleContext","")), ensure_ascii=False))
    except Exception as err:
        print(json.dumps({"error": str(err)}, ensure_ascii=False))

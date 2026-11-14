"""Book Quest tests.

    python3 -m unittest discover -s tests -v

The unit tests run anywhere. The end-to-end tests need macOS (PDFKit + swiftc from the Xcode command line
tools): they write a small PDF with a table of contents, import it with `./quest add`, start the real world
server and talk to it over HTTP. No book is needed and nothing outside a temporary folder is touched.
"""
import http.client
import importlib.machinery
import importlib.util
import json
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import zlib
from pathlib import Path
from types import SimpleNamespace

REPO = Path(__file__).resolve().parent.parent


def load_quest():
    loader = importlib.machinery.SourceFileLoader("quest_under_test", str(REPO / "quest"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


q = load_quest()
NATIVE = sys.platform == "darwin" and shutil.which("swiftc") is not None


# ───────────────────────────── a tiny PDF writer for the tests ─────────────────────────────
def make_pdf(path, chapters):
    """Write a PDF with an outline. chapters: [(title, [(section title, pages)])]. Text uses Helvetica, a
    standard PDF font, so nothing is embedded. Returns the total page count."""
    objs = {}

    def esc(t):
        return t.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
    nxt = [5]                                    # 1 catalog, 2 pages, 3 font, 4 outline root

    def new():
        nxt[0] += 1
        return nxt[0] - 1
    pages, outline = [], []                      # outline: (title, page index, [(title, page index)])
    for ci, (title, sections) in enumerate(chapters, 1):
        first, subs = len(pages), []
        for si, (stitle, n) in enumerate(sections):
            subs.append((stitle, len(pages)))
            for k in range(n):
                lines = [f"Chapter {ci}: {title}"] if (si == 0 and k == 0) else []
                lines += [f"{stitle}, page {k + 1}."] + ["The quick brown fox jumps over the lazy dog. " * 2] * 18
                ops = ["BT /F1 22 Tf 72 610 Td"] if lines[0].startswith("Chapter") else ["BT /F1 11 Tf 72 610 Td"]
                for i, ln in enumerate(lines):
                    if i == 1 and lines[0].startswith("Chapter"):
                        ops.append("/F1 11 Tf 0 -40 Td")
                    elif i:
                        ops.append("0 -16 Td")
                    ops.append(f"({esc(ln)}) Tj")
                ops.append("ET")
                content = "\n".join(ops).encode()
                cid, pid = new(), new()
                objs[cid] = b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream"
                objs[pid] = (f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 504 666] /Contents {cid} 0 R "
                             f"/Resources << /Font << /F1 3 0 R >> >> >>").encode()
                pages.append(pid)
        outline.append((title, first, subs))
    objs[3] = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    objs[2] = f"<< /Type /Pages /Kids [{' '.join(f'{p} 0 R' for p in pages)}] /Count {len(pages)} >>".encode()
    ids = [new() for _ in outline]
    for i, (title, first, subs) in enumerate(outline):
        sids = [new() for _ in subs]
        for j, (stitle, spage) in enumerate(subs):
            links = (f" /Prev {sids[j - 1]} 0 R" if j else "") + (f" /Next {sids[j + 1]} 0 R" if j + 1 < len(sids) else "")
            objs[sids[j]] = (f"<< /Title ({esc(stitle)}) /Parent {ids[i]} 0 R{links} /Dest [{pages[spage]} 0 R /Fit] >>").encode()
        links = (f" /Prev {ids[i - 1]} 0 R" if i else "") + (f" /Next {ids[i + 1]} 0 R" if i + 1 < len(ids) else "")
        kids = f" /First {sids[0]} 0 R /Last {sids[-1]} 0 R /Count {len(sids)}" if sids else ""
        objs[ids[i]] = (f"<< /Title (Chapter {i + 1}: {esc(title)}) /Parent 4 0 R{links}{kids} "
                        f"/Dest [{pages[first]} 0 R /Fit] >>").encode()
    objs[4] = f"<< /Type /Outlines /First {ids[0]} 0 R /Last {ids[-1]} 0 R /Count {len(ids)} >>".encode()
    objs[1] = b"<< /Type /Catalog /Pages 2 0 R /Outlines 4 0 R /PageMode /UseOutlines >>"
    out, offsets = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"), {}
    for n in range(1, nxt[0]):
        offsets[n] = len(out)
        out += b"%d 0 obj\n" % n + objs[n] + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % nxt[0]
    out += b"".join(b"%010d 00000 n \n" % offsets[n] for n in range(1, nxt[0]))
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (nxt[0], xref)
    Path(path).write_bytes(bytes(out))
    return len(pages)


def png_info(data):
    """Parse a PNG by hand: check every chunk's CRC, inflate the image data and return (width, height, bit
    depth, color type, inflated length)."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, ihdr = 8, b"", None
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body, crc = data[pos + 8:pos + 8 + n], struct.unpack(">I", data[pos + 8 + n:pos + 12 + n])[0]
        assert zlib.crc32(kind + body) == crc, f"bad CRC in {kind}"
        if kind == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    w, h, depth, color = ihdr[:4]
    return w, h, depth, color, len(zlib.decompress(idat))


# ───────────────────────────── unit tests ─────────────────────────────
class Titles(unittest.TestCase):
    def test_clean_title(self):
        self.assertEqual(q.clean_title("It&#8217;s Your Life "), "It’s Your Life")
        self.assertEqual(q.clean_title("DRY—The EvilsDRY—The Evils"), "DRY—The Evils")      # some PDFs repeat titles
        self.assertEqual(q.clean_title("COLOPHON\\"), "COLOPHON")

    def test_strip_number(self):
        for raw, want in [("Chapter 1: The Basics Revisited", "The Basics Revisited"), ("1: Up and Running", "Up and Running"),
                          ("2. A Pragmatic Approach", "A Pragmatic Approach"), ("Topic 7. Communicate!", "Communicate!"),
                          ("Chapter Seven Other Tools", "Other Tools"), ("A1. Bibliography", "Bibliography"),
                          ("3D Graphics", "3D Graphics"), ("C: A Language", "C: A Language"), ("1984 Revisited", "1984 Revisited")]:
            self.assertEqual(q.strip_number(raw), want, raw)

    def test_tidy_caps_keeps_acronyms(self):
        self.assertEqual(q.tidy_caps("PGP KEY MANAGEMENT"), "PGP Key Management")
        self.assertEqual(q.tidy_caps("THE WEB OF TRUST"), "The Web of Trust")
        self.assertEqual(q.tidy_caps("Mixed Case Stays"), "Mixed Case Stays")

    def test_appendix_and_optional_detection(self):
        for t in ("A1. Bibliography", "Appendix B: Tools", "B. Further Reading"):
            self.assertTrue(q.APPENDIX_RE.match(t), t)
        self.assertFalse(q.APPENDIX_RE.match("C: A Language"))
        self.assertTrue(q.OPTIONAL_RE.match("Introduction"))
        self.assertFalse(q.OPTIONAL_RE.match("Introduction to PGP Command Line"))
        for t in ("Index", "Brief Contents", "Contents in Detail", "Acknowledgments", "Copyright"):
            self.assertTrue(q.SKIP_RE.search(t), t)

    def test_title_from_filename(self):
        self.assertEqual(q.title_from_filename("John Doe - The Make Book-No Starch Press (2015).pdf"), "The Make Book")
        self.assertEqual(q.title_from_filename("The.Art.of.Debugging.pdf"), "The Art of Debugging")


class Planning(unittest.TestCase):
    def outline_meta(self):
        rows = [[0, 1, "Cover"], [0, 3, "Contents"], [0, 5, "Foreword"], [0, 8, "Introduction"], [1, 9, "Who This Is For"],
                [0, 12, "PART I: The Core"], [1, 13, "1: Basics"], [2, 13, "Hello"], [2, 17, "Types"], [2, 25, "Values"],
                [1, 30, "2: More"], [2, 30, "Loops"], [2, 33, "Functions"], [0, 60, "PART II: Libraries"],
                [1, 61, "3: Containers"], [2, 61, "Vectors"], [2, 64, "Maps"], [0, 90, "Appendix A: Tools"], [0, 95, "Index"]]
        return {"n": 100, "labels": [str(i) for i in range(1, 101)], "outline": rows}

    def test_parts_front_matter_and_back_matter(self):
        chapters, parts = q.plan_chapters(self.outline_meta())
        self.assertEqual(parts, {1: "The Core", 2: "Libraries"})
        self.assertEqual([(c["num"], c["title"], c["optional"]) for c in chapters],
                         [(0, "Before You Begin", True), (1, "Basics", False), (2, "More", False),
                          (3, "Containers", False), (4, "Appendix A: Tools", True)])
        self.assertEqual([c["part"] for c in chapters[1:4]], [1, 1, 2])
        self.assertEqual((chapters[3]["start"], chapters[3]["end"]), ("61", "89"))   # stops before the appendix

    def test_quests_cover_every_page_once(self):
        for c in q.plan_chapters(self.outline_meta())[0]:
            spans = [(r["pdf"], r["end"]) for r in c["reading"]]
            self.assertEqual(spans[0][0], c["pdf"])
            for (a, b), (a2, _) in zip(spans, spans[1:]):
                self.assertEqual(a2, b + 1, f"gap or overlap in chapter {c['num']}")
            for a, b in spans:
                self.assertTrue(1 <= b - a + 1 <= 12, f"quest of {b - a + 1} pages in chapter {c['num']}")

    def test_no_outline_splits_into_slices(self):
        chapters, _ = q.plan_chapters({"n": 95, "labels": None, "outline": []})
        self.assertEqual(len(chapters), 5)
        self.assertEqual(chapters[-1]["end"], "95")

    def test_bosses_cover_each_required_chapter_once(self):
        chapters, parts = q.plan_chapters(self.outline_meta())
        bosses = q.plan_bosses(chapters, parts)
        unlocked = [n for b in bosses for n in b["unlock"]]
        self.assertEqual(sorted(unlocked), [c["num"] for c in chapters if not c["optional"]])
        self.assertEqual(bosses[-1]["name"], "The Final Exam Titan")
        self.assertTrue(all(b["build"] == "none" and len(b["goals"]) == 5 for b in bosses))

    def test_outline_under_one_title_entry(self):
        rows = [[0, 1, "Cover"], [0, 3, "My Book"]] + [[1, 10 + 30 * i, f"Lesson {i + 1}"] for i in range(8)]
        chapters, _ = q.plan_chapters({"n": 300, "labels": None, "outline": rows})
        self.assertEqual([c["title"] for c in chapters], [f"Lesson {i}" for i in range(1, 9)])

    def test_parts_found_by_chapter_numbers_in_any_language(self):
        rows = [[0, 3, "Table des matières"], [0, 5, "Préface"], [0, 10, "Fondations"], [1, 11, "1 Démarrer"],
                [1, 60, "2 Types"], [0, 120, "Pratique"], [1, 121, "3 Plus"], [1, 200, "4 Fin"],
                [0, 280, "Annexe A : Outils"], [0, 290, "Index"]]
        chapters, parts = q.plan_chapters({"n": 300, "labels": None, "outline": rows})
        self.assertEqual(parts, {1: "Fondations", 2: "Pratique"})
        self.assertEqual([(c["num"], c["part"], c["optional"]) for c in chapters],
                         [(0, 0, True), (1, 1, False), (2, 1, False), (3, 2, False), (4, 2, False), (5, 2, True)])
        self.assertEqual(chapters[4]["end"], "279")                 # stops before the appendix; Index is skipped

    def test_german_names(self):
        rows = [[0, 5, "Vorwort"], [0, 10, "Teil I: Grundlagen"], [1, 11, "Kapitel 1: Start"], [1, 60, "Kapitel 2: Typen"],
                [0, 120, "Teil II: Praxis"], [1, 121, "Kapitel 3: Mehr"], [0, 290, "Stichwortverzeichnis"]]
        chapters, parts = q.plan_chapters({"n": 300, "labels": None, "outline": rows})
        self.assertEqual(parts, {1: "Grundlagen", 2: "Praxis"})
        self.assertEqual([c["title"] for c in chapters], ["Before You Begin", "Start", "Typen", "Mehr"])

    def test_numbered_sections_are_not_parts(self):
        rows = [[0, 10, "1 Basics"], [1, 10, "1 Hello"], [1, 15, "2 World"], [0, 30, "2 More"], [1, 30, "1 Loops"],
                [1, 40, "2 Functions"]]                             # section numbers start again in each chapter
        chapters, parts = q.plan_chapters({"n": 60, "labels": None, "outline": rows})
        self.assertEqual((len(chapters), parts), (2, {}))

    def test_side_book_keys(self):
        self.assertEqual(q.side_key("The Pragmatic Programmer", set()), "pp")
        self.assertEqual(q.side_key("The Pragmatic Programmer", {"pp"}), "pp2")
        self.assertEqual(q.side_key("Make", set()), "make")


def contents_entries():
    """What Claude returns for a small book: roman front matter, two parts, sections, an appendix and an index."""
    rows = [("skip", "Contents", "v"), ("optional", "Vorwort", "vii"), ("part", "Teil I: Grundlagen", "1"),
            ("chapter", "Kapitel 1: Start", "3"), ("section", "Installieren", "4"), ("section", "Erste Schritte", "10"),
            ("chapter", "Kapitel 2: Typen", "20"), ("part", "Teil II: Praxis", "40"), ("chapter", "Kapitel 3: Mehr", "42"),
            ("optional", "Anhang A: Werkzeuge", "70"), ("skip", "Stichwortverzeichnis", "80")]
    return [{"kind": k, "title": t, "page": p} for k, t, p in rows]


def book_text(n=100, front=10):
    """Page heads of a typeset book whose printed page 1 is PDF page front + 1: a contents page, roman front
    matter, chapter openers, running heads (title on odd pages, "N Chapter k" on even ones) and a body page that
    happens to start with a later chapter's title."""
    heads = {1: "Cover", 2: "Contents Vorwort vii Teil I Grundlagen 1 Kapitel 1 Start 3 Typen 20 Mehr 42 Anhang 70"}
    heads.update({front - 3 + i: (f"V O R W O R T {'Why this book' * 3}" if i == 0 else f"Vorwort {['', 'viii', 'ix'][i]}")
                  for i in range(3)})
    openers = {1: "Teil I Grundlagen", 3: "Kapitel 1 S T A R T", 20: "Kapitel 2 TYPEN", 40: "TEIL II PRAXIS",
               42: "Kapitel 3 MEHR", 70: "ANHANG A WERKZEUGE", 80: "STICHWORTVERZEICHNIS"}
    title = None
    for printed in range(1, n - front + 1):
        pg = front + printed
        if printed in openers:
            heads[pg], title = openers[printed] + " In this chapter we look at things.", openers[printed]
        elif title:
            heads[pg] = f"{title.title()} {printed}" if pg % 2 else f"{printed} Chapter"
    heads[front + 12] = "Typen are what this paragraph is about, as the next chapter shows."
    return lambda a, b: [heads.get(p, "") for p in range(a, b + 1)]


class AiContents(unittest.TestCase):
    """./quest add --ai, without the network: the request it builds, and everything it does with the answer."""

    def test_request(self):
        p = q.ai_request(b"%PDF-1.7 pages", "claude-opus-5-5")
        self.assertEqual((p["model"], p["max_tokens"], p["fallbacks"]), ("claude-opus-5-5", 64000, "default"))
        self.assertEqual(p["betas"], ["server-side-fallback-2026-07-01"])
        doc, text = p["messages"][0]["content"]
        self.assertEqual(__import__("base64").b64decode(doc["source"]["data"]), b"%PDF-1.7 pages")
        self.assertEqual((doc["type"], doc["source"]["media_type"], text["type"]), ("document", "application/pdf", "text"))
        self.assertNotIn("fallbacks", q.ai_request(b"x", "claude-haiku-5-5"))     # no server-side fallback there

    def test_schema_is_strict(self):
        def walk(s):
            if s.get("type") == "object":
                self.assertIs(s["additionalProperties"], False)
                self.assertEqual(sorted(s["required"]), sorted(s["properties"]))
                for v in s["properties"].values():
                    walk(v)
            elif s.get("type") == "array":
                walk(s["items"])
        schema = q.ai_request(b"x", "claude-opus-5-5")["output_config"]["format"]["schema"]
        walk(schema)
        self.assertEqual(schema["properties"]["entries"]["items"]["properties"]["kind"]["enum"], list(q.AI_KINDS))

    def test_printed_page(self):
        self.assertEqual([q.printed_page(s) for s in ("23", " xv ", "XIV", "", "A-3", "iiii", "mmxx")],
                         [("a", 23), ("r", 15), ("r", 14), None, None, None, ("r", 2020)])

    def test_place_by_page_labels(self):
        labels = ["c1", "c2", "c3", "c4", "v", "vi", "vii", "viii", "ix", "x"] + [str(i) for i in range(1, 91)]
        pages, how = q.place_entries(contents_entries(), 100, labels, None)
        self.assertEqual(pages, [5, 7, 11, 13, 14, 20, 30, 50, 52, 80, 90])
        self.assertIn("page labels", how)

    def test_place_by_text_despite_running_heads(self):
        pages, how = q.place_entries(contents_entries(), 100, [str(i) for i in range(1, 101)], book_text(),
                                     contents_until=4)
        self.assertEqual(pages, [5, 7, 11, 13, 14, 20, 30, 50, 52, 80, 90])
        self.assertIn("printed page 1 is PDF page 11", how)

    def test_offset_flag(self):
        pages, how = q.place_entries(contents_entries(), 100, None, book_text(), offset=10, contents_until=4)
        self.assertEqual(pages[2:], [11, 13, 14, 20, 30, 50, 52, 80, 90])
        self.assertTrue(how.startswith("--offset 10"))

    def test_no_match_gives_up(self):
        self.assertEqual(q.place_entries(contents_entries(), 100, None, lambda a, b: [""] * (b - a + 1)), (None, None))

    def test_outline_and_plan(self):
        pages = [5, 7, 11, 13, 14, 20, 30, 50, 52, 80, 90]
        rows = q.ai_outline(contents_entries(), pages, 100)
        self.assertEqual([r[0] for r in rows], [0, 0, 0, 1, 2, 2, 1, 0, 1, 0, 0])
        chapters, parts = q.plan_chapters({"n": 100, "labels": None, "outline": rows})
        self.assertEqual(parts, {1: "Grundlagen", 2: "Praxis"})
        self.assertEqual([(c["num"], c["title"], c["part"], c["optional"]) for c in chapters],
                         [(0, "Before You Begin", 0, True), (1, "Start", 1, False), (2, "Typen", 1, False),
                          (3, "Mehr", 2, False), (4, "Anhang A: Werkzeuge", 2, True)])
        self.assertEqual((chapters[3]["pdf"], chapters[3]["end"]), (52, "79"))

    def test_entries_out_of_order_are_dropped(self):
        rows = q.ai_outline(contents_entries(), [5, 7, 11, 13, 14, 20, 12, 50, 52, 80, 90], 100)
        self.assertNotIn("Kapitel 2: Typen", [r[2] for r in rows])

    def ask(self, message):
        """Run ai_ask against a stand-in for the anthropic package that returns `message`."""
        import contextlib
        import io
        import types
        fake = types.ModuleType("anthropic")
        for name in ("AnthropicError", "APIStatusError", "AuthenticationError", "APIConnectionError"):
            setattr(fake, name, type(name, (Exception,), {}))

        class Stream:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def get_final_message(self):
                return message
        fake.Anthropic = lambda: SimpleNamespace(beta=SimpleNamespace(messages=SimpleNamespace(stream=lambda **kw: Stream())))
        saved = sys.modules.get("anthropic")
        sys.modules["anthropic"] = fake
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                return q.ai_ask({})
        finally:
            sys.modules.pop("anthropic")
            if saved:
                sys.modules["anthropic"] = saved

    def message(self, stop, text):
        return SimpleNamespace(stop_reason=stop, content=[SimpleNamespace(type="text", text=text)],
                               usage=SimpleNamespace(input_tokens=1200, output_tokens=80))

    def test_answer_parsed(self):
        self.assertEqual(self.ask(self.message("end_turn", '{"entries": []}')), ({"entries": []}, 1200, 80))

    def test_refusal_and_cut_off_answers_stop(self):
        for m in (self.message("refusal", ""), self.message("max_tokens", '{"entr'), self.message("end_turn", "nope")):
            with self.assertRaises(SystemExit):
                self.ask(m)


class Validation(unittest.TestCase):
    def test_strokes_accepted_and_rounded(self):
        got = q.clean_strokes([{"t": "pen", "c": "#1d2433", "w": 0.0028, "pts": [[0.1234567, 0.5, 0.7], [0.2, 0.5, 0.71]]}])
        self.assertEqual(got[0]["pts"][0], [0.12346, 0.5, 0.7])

    def test_strokes_rejected(self):
        bad = [{"t": "spray", "c": "#000000", "w": 0.002, "pts": [[0, 0, 0]]},
               {"t": "pen", "c": "red", "w": 0.002, "pts": [[0, 0, 0]]},
               {"t": "pen", "c": "#000000", "w": 5, "pts": [[0, 0, 0]]},
               {"t": "pen", "c": "#000000", "w": 0.002, "pts": [[0, 0]]},
               {"t": "pen", "c": "#000000", "w": 0.002, "pts": [["x", 0, 0]]}]
        for s in bad:
            self.assertIsNone(q.clean_strokes([s]), s)
        self.assertIsNone(q.clean_strokes("nope"))

    def test_unit_for_page(self):
        ch = lambda n, a, b: {"num": n, "title": f"C{n}", "dir": f"ch{n:02d}", "reading": [{"id": f"{n}.1", "title": "x", "pdf": a, "page": str(a), "end": b}]}
        book = SimpleNamespace(chapters=[ch(1, 10, 19), ch(2, 20, 40)], side={})
        self.assertEqual(q.unit_for_page(book, "main", 25)[0]["num"], 2)
        self.assertEqual(q.unit_for_page(book, "main", 45)[0]["num"], 2)       # past the last quest: last chapter
        self.assertEqual(q.unit_for_page(book, "nope", 5), (None, None))

    def test_rel(self):
        self.assertEqual(q.rel(q.ROOT / "a" / "b.md"), "a/b.md")
        self.assertEqual(q.rel("/elsewhere/x"), "/elsewhere/x")


class Encoder(unittest.TestCase):
    def test_multiply_shift_quantizer_is_exact(self):
        # render_fast.h relies on this: round(v·15/255) == (v·15 + 135) >> 8 for every 8-bit v, and 135 is
        # the only constant that works with a shift of 8.
        self.assertTrue(all((v * 15 + 135) >> 8 == (v * 15 + 127) // 255 for v in range(256)))
        self.assertEqual([c for c in range(256) if all((v * 15 + c) >> 8 == (v * 15 + 127) // 255 for v in range(256))], [135])


class Pages(unittest.TestCase):
    def test_cdn_scripts_carry_integrity_hashes(self):
        # The map draws the pairing QR code with a script from cdnjs: if that file changed, it could read the
        # pairing key. Every script fetched from a CDN must be pinned to a version and a sha384 hash.
        for name in ("world.html", "reader.html"):
            js = (REPO / ".quest" / name).read_text(encoding="utf-8")
            calls = [c for c in re.findall(r"loadScript\(([^;]+)", js) if not c.startswith("src,")]
            self.assertTrue(calls, name)
            for c in calls:
                self.assertIn('"sha384-', c, f"{name}: loadScript({c[:60]}…) has no integrity hash")
            for c in re.findall(r"fetch\(PDFJS[^;]+", js):
                self.assertIn('integrity:"sha384-', c, name)
            self.assertNotRegex(js, r"<script[^>]*\bsrc=", f"{name}: a <script src> tag skips the integrity check")


# ───────────────────────────── end to end (macOS) ─────────────────────────────
FAKE_ANTHROPIC = '''"""Stands in for the anthropic package in test_add_with_ai: logs the request, returns FAKE_ANSWER."""
import json, os
from types import SimpleNamespace as NS

class AnthropicError(Exception): pass
class APIStatusError(AnthropicError): pass
class AuthenticationError(APIStatusError): pass
class APIConnectionError(AnthropicError): pass

class _Stream:
    def __init__(self, params): self.params = params
    def __enter__(self): return self
    def __exit__(self, *exc): return False
    def get_final_message(self):
        with open(os.environ["FAKE_LOG"], "w") as f: json.dump(self.params, f)
        with open(os.environ["FAKE_ANSWER"]) as f: text = f.read()
        return NS(stop_reason="end_turn", content=[NS(type="text", text=text)], usage=NS(input_tokens=900, output_tokens=60))

class Anthropic:
    def __init__(self): self.beta = NS(messages=NS(stream=lambda **params: _Stream(params)))
'''


@unittest.skipUnless(NATIVE, "needs macOS with swiftc (PDFKit)")
class EndToEnd(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = Path(tempfile.mkdtemp(prefix="bookquest-"))
        shutil.copy(REPO / "quest", cls.dir / "quest")
        (cls.dir / ".quest").mkdir()
        for name in ("world.html", "reader.html", "render.swift", "render_fast.h"):
            shutil.copy(REPO / ".quest" / name, cls.dir / ".quest" / name)
        shutil.copytree(REPO / ".quest" / "icons", cls.dir / ".quest" / "icons")
        cls.pages = make_pdf(cls.dir / "Test Book.pdf", [
            ("Getting Started", [("Setup", 5), ("First Steps", 4), ("Next Steps", 5)]),
            ("Going Further", [("Patterns", 6), ("Pitfalls", 3)]),
            ("Wrapping Up", [("Review", 4)])])
        cls.run_quest("add", "Test Book.pdf", "--title", "Test Book")
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            cls.port = s.getsockname()[1]
        cls.server = subprocess.Popen([sys.executable, "quest", "world", "--no-open", "--port", str(cls.port)], cwd=cls.dir,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 300                     # the first run compiles the Swift helper
        while time.time() < deadline:
            try:
                if json.loads(cls.get("/api/book?key=main")[2]).get("native"):
                    break
            except (OSError, ValueError):
                pass
            time.sleep(0.5)
        else:
            raise RuntimeError("world server didn't start")
        cls.token = re.search(r'const TOKEN = "([0-9a-f]+)"', cls.get("/read")[2].decode()).group(1)

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        cls.server.wait(10)
        shutil.rmtree(cls.dir, ignore_errors=True)

    @classmethod
    def run_quest(cls, *args, env=None):
        r = subprocess.run([sys.executable, "quest", *args], cwd=cls.dir, capture_output=True, text=True,
                           env={"NO_COLOR": "1", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", **(env or {})}, timeout=600)
        if r.returncode:
            raise AssertionError(r.stdout + r.stderr)
        return r.stdout

    def test_add_with_ai(self):
        # ./quest add --ai end to end, with a stand-in for the anthropic package that logs the request and gives
        # back the contents of the test book. The helper cuts out the pages; page text lines up the numbers.
        sdk = self.dir / "fake_sdk" / "anthropic"
        sdk.mkdir(parents=True)
        (sdk / "__init__.py").write_text(FAKE_ANTHROPIC)
        answer = {"title": "Test Book", "author": "A. Writer", "found_contents": True, "complete": True, "entries": [
            {"kind": "chapter", "title": "Getting Started", "page": "1"}, {"kind": "section", "title": "Setup", "page": "1"},
            {"kind": "section", "title": "First Steps", "page": "6"}, {"kind": "section", "title": "Next Steps", "page": "10"},
            {"kind": "chapter", "title": "Going Further", "page": "15"}, {"kind": "section", "title": "Pitfalls", "page": "21"},
            {"kind": "chapter", "title": "Wrapping Up", "page": "24"}]}
        (self.dir / "answer.json").write_text(json.dumps(answer))
        env = {"PYTHONPATH": str(self.dir / "fake_sdk"), "FAKE_ANSWER": str(self.dir / "answer.json"),
               "FAKE_LOG": str(self.dir / "request.json")}
        out = self.run_quest("add", "Test Book.pdf", "--ai", "--dry-run", env=env)
        self.assertIn("3 chapters", out)
        self.assertIn("printed page 1 is PDF page 1", out)
        self.assertRegex(out, r"Going Further\s+p\.15–23")
        sent = json.loads((self.dir / "request.json").read_text())
        self.assertEqual(sent["model"], "claude-opus-5-5")
        pages = __import__("base64").b64decode(sent["messages"][0]["content"][0]["source"]["data"])
        self.assertTrue(pages.startswith(b"%PDF"))
        (self.dir / "request.json").unlink()
        again = self.run_quest("add", "Test Book.pdf", "--ai", "--dry-run", env=env)
        self.assertIn("earlier reading", again)                    # answered from .quest/.cache/ai: no request
        self.assertFalse((self.dir / "request.json").exists())

    @classmethod
    def request(cls, method, path, body=None, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", cls.port, timeout=60)
        try:
            c.request(method, path, body=body, headers=headers or {})
            r = c.getresponse()
            return r.status, dict(r.getheaders()), r.read()
        finally:
            c.close()

    @classmethod
    def get(cls, path, **kw):
        return cls.request("GET", path, **kw)

    def post(self, path, body, **extra):
        h = {"Content-Type": "application/json", "X-Quest-Token": self.token}
        h.update(extra)
        return self.request("POST", path, json.dumps(body).encode(), h)

    def test_import_built_the_book(self):
        book = json.loads((self.dir / ".quest" / "book.json").read_text())
        self.assertEqual(book["title"], "Test Book")
        self.assertEqual([c["title"] for c in book["chapters"]], ["Getting Started", "Going Further", "Wrapping Up"])
        self.assertEqual(sum(r["pages"] for c in book["chapters"] for r in c["reading"]), self.pages)
        self.assertGreaterEqual(len(book["bosses"]), 1)
        self.assertIn("TEST BOOK · QUEST LOG", self.run_quest())

    def test_text_pages_are_exact_4_bit_pngs(self):
        status, headers, body = self.get("/page/main/3?w=808&h=1068&v=t")
        self.assertEqual((status, headers["Content-Type"]), (200, "image/png"))
        w, h, depth, color, raw = png_info(body)
        self.assertEqual((depth, color), (4, 0))                   # 16-shade grayscale
        self.assertEqual(raw, h * ((w + 1) // 2 + 1))              # every row: filter byte + packed pixels
        self.assertLessEqual(w, 808)
        self.assertIn("immutable", headers["Cache-Control"])

    def test_preview_is_small_jpeg(self):
        status, headers, body = self.get("/page/main/3?w=202&h=267&v=t&lq=1")
        self.assertEqual((status, headers["Content-Type"]), (200, "image/jpeg"))
        self.assertLess(len(body), 60_000)

    def test_rejects_foreign_host_header(self):                    # DNS rebinding
        self.assertEqual(self.get("/api/state", headers={"Host": f"evil.example:{self.port}"})[0], 421)
        self.assertEqual(self.get("/api/state", headers={"Host": f"127.0.0.1:{self.port}"})[0], 200)
        self.assertEqual(self.get("/api/state", headers={"Host": f"my-mac.local:{self.port}"})[0], 200)

    def test_post_needs_token_and_matching_origin(self):
        self.assertEqual(self.request("POST", "/api/ack", b"{}", {"Content-Type": "application/json"})[0], 403)
        self.assertEqual(self.post("/api/ack", {"seq": 0}, Origin="http://evil.example")[0], 403)
        self.assertEqual(self.post("/api/ack", {"seq": 0})[0], 200)

    def test_oversized_body_refused_unread(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.putrequest("POST", "/api/ink")
        for k, v in (("Content-Type", "application/json"), ("X-Quest-Token", self.token), ("Content-Length", str(64 << 20))):
            c.putheader(k, v)
        c.endheaders()
        try:
            self.assertEqual(c.getresponse().status, 413)
        finally:
            c.close()

    def test_security_headers(self):
        _, h, _ = self.get("/read")
        self.assertEqual((h["X-Frame-Options"], h["X-Content-Type-Options"], h["Referrer-Policy"]), ("DENY", "nosniff", "no-referrer"))

    def test_ink_round_trip_and_validation(self):
        strokes = [{"t": "pen", "c": "#2457c5", "w": 0.0028, "pts": [[0.1, 0.2, 0.5], [0.3, 0.25, 0.6]]}]
        self.assertEqual(self.post("/api/ink", {"key": "main", "page": 5, "strokes": strokes})[0], 200)
        self.assertEqual(json.loads(self.get("/api/ink?key=main")[2])["5"], strokes)
        self.assertEqual(self.post("/api/ink", {"key": "main", "page": 5, "strokes": [{"t": "x"}]})[0], 400)
        self.assertEqual(self.post("/api/ink", {"key": "../../etc", "page": 5, "strokes": []})[0], 400)
        self.assertEqual(self.post("/api/transcribe", {"key": "main", "page": 999})[0], 200)   # no ink there: empty

    def test_notes_save_and_conflict(self):
        status, _, body = self.get("/api/notes?key=main&page=20")
        d = json.loads(body)
        self.assertEqual(status, 200)
        self.assertTrue(d["path"].endswith("notes.md"))
        ok = self.post("/api/notes", {"key": "main", "page": 20, "text": "Q: test?\nA: yes\n", "mtime": d["mtime"]})
        self.assertEqual(ok[0], 200)
        stale = self.post("/api/notes", {"key": "main", "page": 20, "text": "older", "mtime": d["mtime"]})
        self.assertEqual(stale[0], 409)                            # the iPad's copy is out of date: not overwritten
        self.assertIn("Q: test?", json.loads(stale[2])["text"])


if __name__ == "__main__":
    unittest.main()

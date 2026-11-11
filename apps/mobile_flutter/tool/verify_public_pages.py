"""Verify the public website pages and their build-local asset/link targets."""
from html.parser import HTMLParser
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit


class Page(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.ids = set()
        self.links = []
        self.assets = []
        self.feed(source)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if attrs.get("id"):
            self.ids.add(attrs["id"])
        if tag == "a" and attrs.get("href"):
            self.links.append(attrs["href"])
        if attrs.get("src"):
            self.assets.append(attrs["src"])
        if tag == "link" and attrs.get("rel") in {"stylesheet", "icon", "apple-touch-icon"}:
            self.assets.append(attrs["href"])


def verify(directory):
    root = Path(directory).resolve()
    pages = {name: Page((root / name / "index.html").read_text())
             for name in ("about", "support", "privacy", "terms")}
    for name, page in pages.items():
        html = (root / name / "index.html").read_text()
        # This script is intentionally parser-blocking in the head: a deferred
        # appearance change would flash a white legal/About page in dark mode.
        appearance = '<script src="/appearance.js"></script>'
        assert appearance in html, f"{name}: missing first-paint appearance script"
        assert html.index(appearance) < html.index('<body'), f"{name}: appearance must run before paint"
        assert '/appearance.css' in page.assets, f"{name}: missing shared appearance palette"
        for target in page.assets:
            url = urlsplit(target)
            assert not url.scheme, f"{name}: public assets should be bundled: {target}"
            assert (root / unquote(url.path).lstrip("/")).is_file(), f"{name}: missing asset {target}"
        for target in page.links:
            url = urlsplit(target)
            if url.scheme or url.netloc:
                continue
            path = url.path
            if path in {"", "/"}:
                if url.fragment.startswith("/") or path == "/":
                    assert (root / "index.html").is_file()
                    continue
                destination = page
            else:
                destination = pages[path.strip("/")]
            if url.fragment:
                assert url.fragment in destination.ids, f"{name}: missing anchor {target}"
        if name != "about":
            assert "/about/" in page.links, f"{name}: About page is not discoverable"
    about = (root / "about/index.html").read_text()
    assert '<h1 id="about-title">Where We Surfing</h1>' in about
    assert '<h2 id="today-title">Find your break.<br /> Meet your crew.</h2>' in about
    assert 'id="partnerships"' in about
    assert "stays cannot currently be booked through Tydes" in about
    assert "mailto:support@tydes.io?subject=Tydes%20partnership%20enquiry" in about
    assert not re.search(r"Bali surf sprint|364|<strong>9</strong>|product-demo", about, re.I)
    print("Public pages verified: local assets, working navigation, public access and clear planned-feature copy.")


if __name__ == "__main__":
    verify(sys.argv[1] if len(sys.argv) > 1 else "build/web")

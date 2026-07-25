"""
Web search tool — gives Dross internet access.

Uses DuckDuckGo HTML (no API key needed) and a simple HTML fetcher.
Designed to be called as a tool by the AI agent.
"""
import re
import urllib.request
import urllib.error
import urllib.parse
from html.parser import HTMLParser
from typing import Optional


class _DDGParser(HTMLParser):
    """Tiny parser for DuckDuckGo HTML results."""

    def __init__(self):
        super().__init__()
        self.results: list[dict] = []
        self._current: Optional[dict] = None
        self._in_snippet = False

    def handle_starttag(self, tag, attrs):
        attrs_d = dict(attrs)
        if tag == "a" and "result__a" in attrs_d.get("class", ""):
            self._current = {"url": attrs_d.get("href", ""), "title": ""}
            self.results.append(self._current)
        elif tag == "a" and self._current and "result__snippet" in (attrs_d.get("class") or ""):
            self._in_snippet = True

    def handle_data(self, data):
        if self._current and not self._in_snippet and self._current.get("title") is not None:
            self._current["title"] += data
        elif self._current and self._in_snippet:
            self._current.setdefault("snippet", "")
            self._current["snippet"] += data

    def handle_endtag(self, tag):
        if tag == "a" and self._in_snippet:
            self._in_snippet = False
        if tag == "a" and self._current and self._current.get("title") is not None:
            self._current["title"] = self._current["title"].strip()
            self._current = None


def search(query: str, max_results: int = 5, timeout: float = 10.0) -> list[dict]:
    """Search the web using DuckDuckGo HTML. Returns a list of results."""
    if not query.strip():
        return []
    url = "https://html.duckduckgo.com/html/?" + urllib.parse.urlencode({
        "q": query,
        "kl": "us-en",
    })
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "text/html",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            html = resp.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, OSError) as e:
        return [{"error": f"search failed: {e}"}]

    parser = _DDGParser()
    try:
        parser.feed(html)
    except Exception as e:
        return [{"error": f"parse failed: {e}"}]

    out = []
    for r in parser.results[:max_results]:
        if not r.get("title"):
            continue
        r["snippet"] = (r.get("snippet") or "").strip()[:300]
        href = r.get("url", "")
        if "uddg=" in href:
            m = re.search(r"uddg=([^&]+)", href)
            if m:
                r["url"] = urllib.parse.unquote(m.group(1))
        out.append(r)
    return out


def fetch_url(url: str, max_chars: int = 4000, timeout: float = 10.0) -> dict:
    """Fetch a URL and extract readable text. Returns {url, text, title}."""
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            content_type = resp.headers.get("Content-Type", "")
            raw = resp.read()
            if "charset" in content_type:
                encoding = content_type.split("charset=")[-1].split(";")[0].strip()
            else:
                encoding = "utf-8"
            html = raw.decode(encoding, errors="replace")
    except (urllib.error.URLError, OSError) as e:
        return {"url": url, "error": f"fetch failed: {e}"}

    html = re.sub(r"<script[^>]*>.*?</script>", " ", html, flags=re.DOTALL | re.IGNORECASE)
    html = re.sub(r"<style[^>]*>.*?</style>", " ", html, flags=re.DOTALL | re.IGNORECASE)

    title = ""
    m = re.search(r"<title[^>]*>(.*?)</title>", html, re.DOTALL | re.IGNORECASE)
    if m:
        title = re.sub(r"<[^>]+>", "", m.group(1)).strip()

    text = re.sub(r"<[^>]+>", " ", html)
    text = re.sub(r"\s+", " ", text).strip()
    text = text[:max_chars]

    return {"url": url, "title": title, "text": text}


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        q = " ".join(sys.argv[1:])
        results = search(q, max_results=5)
        for r in results:
            print(f"- {r.get('title', '')}")
            print(f"  {r.get('url', '')}")
            print(f"  {r.get('snippet', '')[:150]}")
            print()
    else:
        print("Usage: python web_search.py <query>")

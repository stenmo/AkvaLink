"""Web landing-page checks — HTML well-formedness + EN/SV structural sync.

Pure stdlib (html.parser + re), no browser, no network. Guards against a broken
tag nesting sneaking into web/index.html or web/index.sv.html, and enforces the
"keep both languages in sync" rule structurally.
"""

import re
from html.parser import HTMLParser
from pathlib import Path

import pytest

WEB = Path(__file__).resolve().parents[1] / "web"
EN = WEB / "index.html"
SV = WEB / "index.sv.html"

# HTML void elements never need a closing tag.
VOID = {
    "area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "param", "source", "track", "wbr",
}

# The sections both pages must have, in either language.
SECTION_IDS = {"live", "why", "hardware", "battery", "how", "variants", "download", "status"}


class _BalanceChecker(HTMLParser):
    """Verify every non-void start tag gets a matching end tag, correctly nested.

    html.parser treats <script>/<style> bodies as CDATA, so JavaScript's `<`
    and CSS selectors don't confuse the tag balance.
    """

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.errors = []

    def handle_starttag(self, tag, attrs):
        if tag not in VOID:
            self.stack.append((tag, self.getpos()))

    def handle_startendtag(self, tag, attrs):
        pass  # self-closing (<br />, <img … />) — nothing to balance

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if not self.stack:
            self.errors.append(f"stray </{tag}> at {self.getpos()}")
            return
        open_tag, pos = self.stack.pop()
        if open_tag != tag:
            self.errors.append(f"</{tag}> at {self.getpos()} closes <{open_tag}> opened at {pos}")


def _check(path: Path):
    parser = _BalanceChecker()
    parser.feed(path.read_text(encoding="utf-8"))
    parser.close()
    return parser.errors, [t for t, _ in parser.stack]


def _section_ids(text: str) -> set:
    return set(re.findall(r'<section[^>]*\bid="([^"]+)"', text))


@pytest.mark.parametrize("path", [EN, SV], ids=["en", "sv"])
def test_page_exists_and_nonempty(path):
    assert path.is_file(), f"{path} is missing"
    assert path.stat().st_size > 1000


@pytest.mark.parametrize("path", [EN, SV], ids=["en", "sv"])
def test_html_tags_balanced(path):
    errors, unclosed = _check(path)
    assert not errors, f"{path.name}: {errors[:5]}"
    assert not unclosed, f"{path.name}: unclosed tags {unclosed}"


@pytest.mark.parametrize("path", [EN, SV], ids=["en", "sv"])
def test_has_expected_sections(path):
    ids = _section_ids(path.read_text(encoding="utf-8"))
    missing = SECTION_IDS - ids
    assert not missing, f"{path.name} missing sections {missing}"


def test_en_sv_sections_in_sync():
    assert _section_ids(EN.read_text(encoding="utf-8")) == _section_ids(SV.read_text(encoding="utf-8"))


@pytest.mark.parametrize("path", [EN, SV], ids=["en", "sv"])
def test_download_cards_present(path):
    text = path.read_text(encoding="utf-8")
    for anchor_id in ("dlThread", "dlWifi", "dlBle"):
        assert f'id="{anchor_id}"' in text, f"{path.name} missing #{anchor_id}"


@pytest.mark.parametrize("path", [EN, SV], ids=["en", "sv"])
def test_release_badge_and_links(path):
    text = path.read_text(encoding="utf-8")
    assert "img.shields.io/github/v/release/stenmo/AkvaLink" in text
    assert "github.com/stenmo/AkvaLink/releases" in text


@pytest.mark.parametrize("path,other", [(EN, "index.sv.html"), (SV, "index.html")], ids=["en", "sv"])
def test_lang_toggle_links_to_other(path, other):
    text = path.read_text(encoding="utf-8")
    assert 'class="lang-toggle"' in text
    assert f'href="{other}"' in text, f"{path.name} lang toggle should link to {other}"


def test_lang_attribute_matches_file():
    assert '<html lang="en">' in EN.read_text(encoding="utf-8")
    assert '<html lang="sv">' in SV.read_text(encoding="utf-8")


@pytest.mark.parametrize("path", [EN, SV], ids=["en", "sv"])
def test_no_old_project_name(path):
    # Regression guard: the pre-rename "AquaLink" spelling must never come back.
    assert "AquaLink" not in path.read_text(encoding="utf-8")

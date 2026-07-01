"""Pytest bootstrap: make the host helper scripts importable from tests.

The scripts under scripts/ are stand-alone tools (not an installed package),
so add that directory to sys.path for the test session. Kept version-agnostic
(works without pytest's ini `pythonpath` option).
"""

import pathlib
import sys

_SCRIPTS = pathlib.Path(__file__).resolve().parent / "scripts"
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))

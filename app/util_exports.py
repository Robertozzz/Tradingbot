
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

def read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)

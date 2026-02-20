"""AnkiConnect共通ユーティリティ"""

from __future__ import annotations

import html
import json
import re
import subprocess
import urllib.request
from typing import Any


DEFAULT_ANKI_HOST = "172.29.64.1"
DEFAULT_ANKI_PORT = 8765


def detect_anki_host() -> str:
    """WSL2環境でAnkiConnectホストIPを自動検出する。"""
    try:
        out = subprocess.check_output(["ip", "route", "show", "default"], text=True)
        parts = out.split()
        if len(parts) >= 3:
            return parts[2]
    except Exception:
        pass
    return DEFAULT_ANKI_HOST


def anki_request(
    action: str,
    params: dict[str, Any] | None = None,
    host: str = DEFAULT_ANKI_HOST,
    port: int = DEFAULT_ANKI_PORT,
):
    """AnkiConnect APIを呼び出し、resultを返す。"""
    payload: dict[str, Any] = {"action": action, "version": 6}
    if params is not None:
        payload["params"] = params

    request = urllib.request.Request(
        f"http://{host}:{port}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=10) as response:  # noqa: S310
        result = json.loads(response.read())
        if result.get("error"):
            raise RuntimeError(f'AnkiConnect error: {result["error"]}')
        return result.get("result")


def to_html_block(text: str) -> str:
    """テキストをAnkiカード用HTMLに変換する。"""
    if not text:
        return ""
    return html.escape(str(text)).replace("\n", "<br>")


def sanitize_anki_tag(value: str) -> str:
    """Ankiタグ名をサニタイズする（スペース→_）。"""
    val = str(value or "").strip()
    val = re.sub(r"\s+", "_", val)
    return val if val else "未分類"

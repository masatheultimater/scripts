"""AnkiConnect共通ユーティリティのユニットテスト"""

import json

import pytest

from lib import anki_common


class _FakeResponse:
    def __init__(self, payload):
        self._payload = payload

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return json.dumps(self._payload).encode("utf-8")


def test_detect_anki_host_from_ip_route(monkeypatch):
    monkeypatch.setattr(
        anki_common.subprocess,
        "check_output",
        lambda *args, **kwargs: "default via 172.20.80.1 dev eth0 proto dhcp",
    )
    assert anki_common.detect_anki_host() == "172.20.80.1"


def test_detect_anki_host_fallback(monkeypatch):
    def _raise(*args, **kwargs):
        raise RuntimeError("ip command failed")

    monkeypatch.setattr(anki_common.subprocess, "check_output", _raise)
    assert anki_common.detect_anki_host() == anki_common.DEFAULT_ANKI_HOST


def test_anki_request_success(monkeypatch):
    captured = {}

    def _fake_urlopen(req, timeout):
        captured["url"] = req.full_url
        captured["timeout"] = timeout
        captured["payload"] = json.loads(req.data.decode("utf-8"))
        return _FakeResponse({"result": 6, "error": None})

    monkeypatch.setattr(anki_common.urllib.request, "urlopen", _fake_urlopen)

    result = anki_common.anki_request("version", host="127.0.0.1", port=8765)

    assert result == 6
    assert captured["url"] == "http://127.0.0.1:8765"
    assert captured["timeout"] == 10
    assert captured["payload"] == {"action": "version", "version": 6}


def test_anki_request_error(monkeypatch):
    def _fake_urlopen(req, timeout):
        return _FakeResponse({"result": None, "error": "boom"})

    monkeypatch.setattr(anki_common.urllib.request, "urlopen", _fake_urlopen)

    with pytest.raises(RuntimeError, match="AnkiConnect error: boom"):
        anki_common.anki_request("addNotes", {"notes": []})


def test_to_html_block():
    text = "<tag>\nline2"
    assert anki_common.to_html_block(text) == "&lt;tag&gt;<br>line2"


def test_sanitize_anki_tag():
    assert anki_common.sanitize_anki_tag(" A B ") == "A_B"
    assert anki_common.sanitize_anki_tag("") == "未分類"

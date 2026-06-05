"""Tests for the Phase 0 OpenAI-compatible stub."""

from fastapi.testclient import TestClient

from stub_server import app

client = TestClient(app)


def test_models_lists_gpt4o_mini():
    resp = client.get("/v1/models")
    assert resp.status_code == 200
    ids = [m["id"] for m in resp.json()["data"]]
    assert "gpt-4o-mini" in ids


def test_chat_completions_returns_canned_content():
    resp = client.post(
        "/v1/chat/completions",
        json={
            "model": "gpt-4o-mini",
            "messages": [{"role": "user", "content": "ping"}],
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["model"] == "gpt-4o-mini"
    assert body["choices"][0]["message"]["content"] == "pong"
    assert body["choices"][0]["finish_reason"] == "stop"


def test_chat_completions_is_deterministic():
    payload = {
        "model": "gpt-4o-mini",
        "messages": [{"role": "user", "content": "anything"}],
    }
    first = client.post("/v1/chat/completions", json=payload).json()
    second = client.post("/v1/chat/completions", json=payload).json()
    assert first["choices"][0]["message"]["content"] == second["choices"][0]["message"]["content"]

"""Minimal OpenAI-compatible stub for Phase 0 hermetic CI.

Serves just enough of the OpenAI API for the `openai_compat` provider:
- POST /v1/chat/completions  -> deterministic canned completion ("pong")
- GET  /v1/models            -> lists gpt-4o-mini so provider health passes

Run standalone:
    uvicorn stub_server:app --host 127.0.0.1 --port 8081
"""

from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="phase0-openai-stub")


class Message(BaseModel):
    role: str
    content: str | None = None


class ChatRequest(BaseModel):
    model: str
    messages: list[Message]


@app.get("/v1/models")
def list_models() -> dict:
    return {
        "object": "list",
        "data": [{"id": "gpt-4o-mini", "object": "model", "owned_by": "stub"}],
    }


@app.post("/v1/chat/completions")
def chat_completions(req: ChatRequest) -> dict:
    return {
        "id": "chatcmpl-phase0-stub",
        "object": "chat.completion",
        "created": 0,
        "model": req.model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": "pong"},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
    }

"""One prompt in, one JSON object out, from whichever AI is set up in Settings > AI planner.

Providers ("none" = no AI; the app's manual planning needs none of this):
    claude-code        the `claude` CLI, signed in with a Claude subscription (no API key)
    anthropic          Claude API key
    openai             OpenAI API key
    openai-compatible  any /chat/completions endpoint: OpenRouter, Gemini, Groq, Ollama, LM Studio...

The API key comes from FOCUS_AI_KEY (the app reads it from the Keychain), or ANTHROPIC_API_KEY / OPENAI_API_KEY.
Plain urllib on purpose: this runs under macOS's built-in Python 3.9, so there is nothing to pip install.
"""
import json
import os
import shutil
import subprocess
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_MODELS = {"claude-code": "sonnet", "anthropic": "claude-opus-5-5", "openai": "gpt-5-mini", "openai-compatible": ""}
BASE_URLS = {"anthropic": "https://api.anthropic.com", "openai": "https://api.openai.com/v1"}
KEY_ENV = {"anthropic": "ANTHROPIC_API_KEY", "openai": "OPENAI_API_KEY"}
# Claude models that accept server-side refusal fallbacks (a declined request is re-run on another model)
FALLBACK_MODELS = ("claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5")


class AIError(RuntimeError):
    def __init__(self, msg, status=None):
        super().__init__(msg)
        self.status = status


def settings(cfg):
    ai = cfg.get("ai") or {}
    provider = ai.get("provider") or "none"
    model = ai.get("model") or DEFAULT_MODELS.get(provider, "")
    base = (ai.get("base_url") or BASE_URLS.get(provider, "")).rstrip("/")
    key = os.environ.get("FOCUS_AI_KEY") or os.environ.get(KEY_ENV.get(provider, ""), "")
    return provider, model, base, key


def ask_json(cfg, prompt, schema, system="Answer only in the requested JSON."):
    provider, model, base, key = settings(cfg)
    if provider == "none":
        raise AIError("no AI is set up: add blocks by hand, or pick an AI in Settings > AI planner")
    if provider == "claude-code":
        return _claude_code(prompt, schema, system, model)
    if provider == "anthropic":
        return _anthropic(prompt, schema, system, model, base, key)
    if provider in ("openai", "openai-compatible"):
        return _openai(prompt, schema, system, model, base, key, provider)
    raise AIError(f"unknown AI provider {provider!r}: pick one in Settings > AI planner")


def _claude_code(prompt, schema, system, model):
    if not shutil.which("claude"):
        raise AIError("Claude Code isn't installed (no `claude` command): install it or pick another AI in Settings > AI planner")
    lean = ["--tools", "", "--disable-slash-commands", "--setting-sources", "project",
            "--exclude-dynamic-system-prompt-sections", "--no-session-persistence", "--strict-mcp-config"]
    proc = subprocess.run(["claude", "-p", prompt, "--model", model, "--output-format", "json", "--json-schema",
                           json.dumps(schema), *lean, "--system-prompt", system],
                          capture_output=True, text=True, timeout=180, cwd=os.path.expanduser("~"))
    try:
        out = json.loads(proc.stdout)
    except json.JSONDecodeError:
        raise AIError((proc.stderr or proc.stdout or "no response from Claude Code").strip()[:200])
    if out.get("is_error") or "structured_output" not in out:
        raise AIError(str(out.get("result") or out.get("subtype") or "Claude Code returned nothing")[:200])
    return out["structured_output"]


def _anthropic(prompt, schema, system, model, base, key):
    if not key:
        raise AIError("no Claude API key: add one in Settings > AI planner")
    body = {"model": model, "max_tokens": 16000, "system": system,
            "messages": [{"role": "user", "content": prompt}],
            "output_config": {"format": {"type": "json_schema", "schema": schema}}}
    if not model.startswith(("claude-haiku-4", "claude-3")):
        body["output_config"]["effort"] = "low"  # planning a day is light work
    headers = {"x-api-key": key, "anthropic-version": "2026-10-21"}
    if model in FALLBACK_MODELS:
        body["fallbacks"] = "default"
        headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
    r = _post(base + "/v1/messages", headers, body)
    if r.get("stop_reason") == "refusal":
        raise AIError("Claude declined this request")
    if r.get("stop_reason") == "max_tokens":
        raise AIError("the answer got cut off: try again")
    return _parse(next((b["text"] for b in r.get("content", []) if b.get("type") == "text"), ""))


def _openai(prompt, schema, system, model, base, key, provider):
    if not base:
        raise AIError("set the server's base URL in Settings > AI planner")
    if not model:
        raise AIError("set a model name in Settings > AI planner")
    if provider == "openai" and not key:
        raise AIError("no OpenAI API key: add one in Settings > AI planner")
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    msgs = [{"role": "system", "content": system}, {"role": "user", "content": prompt}]
    body = {"model": model, "messages": msgs,
            "response_format": {"type": "json_schema", "json_schema": {"name": "answer", "schema": schema, "strict": True}}}
    try:
        r = _post(base + "/chat/completions", headers, body)
    except AIError as e:
        if e.status not in (400, 422):
            raise
        # Servers without JSON-schema support: ask for plain JSON and describe the shape in the prompt instead.
        msgs[1]["content"] += "\n\nReply with only one JSON object that matches this JSON Schema:\n" + json.dumps(schema)
        body["response_format"] = {"type": "json_object"}
        r = _post(base + "/chat/completions", headers, body)
    try:
        text = r["choices"][0]["message"].get("content") or ""
    except (KeyError, IndexError, TypeError):
        raise AIError("the AI returned an unexpected response")
    return _parse(text)


def _post(url, headers, body, timeout=120):
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", **headers})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        try:
            err = json.loads(detail).get("error")
            detail = (err.get("message") if isinstance(err, dict) else err) or detail
        except (ValueError, AttributeError):
            pass
        if e.code in (401, 403):
            raise AIError("the API key was rejected: check it in Settings > AI planner", e.code)
        raise AIError(f"HTTP {e.code}: {str(detail)[:160]}", e.code)
    except (urllib.error.URLError, OSError) as e:
        raise AIError(f"couldn't reach {urllib.parse.urlparse(url).netloc}: {getattr(e, 'reason', e)}")


def _parse(text):
    """JSON from a model reply; tolerates ```json fences and stray text around the object."""
    t = text.strip()
    try:
        return json.loads(t)
    except json.JSONDecodeError:
        a, b = t.find("{"), t.rfind("}")
        if a != -1 and b > a:
            try:
                return json.loads(t[a:b + 1])
            except json.JSONDecodeError:
                pass
    raise AIError("the AI's answer wasn't valid JSON: try again")

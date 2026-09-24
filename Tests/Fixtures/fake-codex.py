"""Offline JSONL App Server fixture; never reads credentials or calls a model."""
import json
import sys

scenario = sys.argv[1]
authenticated = scenario not in ("signed-out", "login", "login-fails", "login-waits", "bad-url")


def send(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def notify(method, params):
    send({"method": method, "params": params})


for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    params = request.get("params", {})
    ident = request.get("id")
    if ident is None:
        continue
    result = {}
    if method == "initialize":
        version = "0.146.0" if scenario == "old" else "0.155.1"
        result = {"userAgent": f"codex_cli_rs/{version} (Mac OS; arm64)"}
    elif method == "account/read":
        result = {"account": {"type": "chatgpt", "email": "test@example.com", "planType": "plus"} if authenticated else None}
    elif method == "account/login/start":
        if scenario == "login-start-hangs":
            continue
        result = {"type": params["type"], "loginId": "login-1"}
        if params["type"] == "chatgptDeviceCode":
            result.update(verificationUrl="https://auth.openai.com/codex/device", userCode="ABCD-1234")
        else:
            result["authUrl"] = "https://evil.example/login" if scenario == "bad-url" else "https://auth.openai.com/authorize"
        if scenario != "login-waits":
            authenticated = scenario != "login-fails"
            # Intentionally complete BEFORE returning the start response.
            notify("account/login/completed", {"loginId": "login-1", "success": authenticated})
    elif method == "account/logout":
        if scenario.startswith("logout-fails"):
            send({"id": ident, "error": {"code": -1, "message": "private token secret"}})
            continue
        authenticated = False
    elif method == "model/list":
        result = {"data": [{"id": "model-2" if params.get("cursor") else "model-1", "model": "test-model-2" if params.get("cursor") else "test-model", "displayName": "Test model", "isDefault": not bool(params.get("cursor"))}], "nextCursor": None if params.get("cursor") else "page-2"}
    elif method == "account/rateLimits/read":
        result = {"rateLimits": {"primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 2000000000}}}
    elif method == "mcpServerStatus/list":
        result = {"data": [{"name": "unexpected"}] if scenario == "mcp" else [], "nextCursor": None}
    elif method == "thread/start":
        assert params["ephemeral"] is True
        assert params["permissions"] == "seminarly-notes"
        assert "sandbox" not in params
        result = {"thread": {"id": "thread-1", "ephemeral": scenario != "persistent"}, "activePermissionProfile": {"id": "wrong" if scenario == "wrong-profile" else "seminarly-notes"}, "approvalPolicy": "never"}
    elif method == "turn/start":
        assert params["permissions"] == "seminarly-notes"
        assert params["outputSchema"]["additionalProperties"] is False
        send({"id": ident, "result": {"turn": {"id": "turn-1", "status": "inProgress"}}})
        metadata = {"threadId": "thread-1", "turnId": "turn-1"}
        if scenario.endswith("hang"):
            continue
        if scenario == "server-request":
            send({"id": 9999, "method": "item/commandExecution/requestApproval", "params": metadata})
            continue
        if scenario == "tool":
            notify("item/started", dict(metadata, item={"type": "commandExecution", "id": "tool-1"}))
            continue
        text = json.dumps({"title": "會議筆記", "summary": "完成", "topics": []}, ensure_ascii=False)
        notify("item/completed", dict(metadata, item={"type": "agentMessage", "phase": "commentary", "text": "Thinking"}))
        notify("item/completed", dict(metadata, item={"type": "agentMessage", "phase": "final_answer", "text": text}))
        failure = scenario in ("failed", "quota")
        notify("turn/completed", {"threadId": "thread-1", "turn": {"id": "turn-1", "status": "failed" if failure else "completed", "error": {"message": "usage limit reached" if scenario == "quota" else "private transcript secret"} if failure else None}})
        continue
    elif method == "never-replies":
        continue
    elif method == "crash":
        sys.exit(1)
    send({"id": ident, "result": result})

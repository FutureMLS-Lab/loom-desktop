#!/usr/bin/env python3
"""Mock Loom server for developing/demoing Loom Desktop without a cluster.

Serves just enough of the Loom HTTP API on http://127.0.0.1:8787:

- /api/projects, /api/tasks           — two projects, four tasks
- /api/activity, /api/activity/ack    — one task working (rotating ring),
                                        one finished-unseen (blinking),
                                        one idle
- /api/tasks/<slug>[/conversation]    — a canned feed with every message kind
- /api/tasks/<slug>/claude/send       — echoes your message, "works" for a
                                        few seconds, then replies
- /api/tasks/<slug>/conversation/answer, /api/tmux/send-key,
  /api/tasks/<slug>/interview/start   — accepted and reflected in the feed

Run:  python3 scripts/mock-loom.py [port]
"""

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
START = time.time()

LOCK = threading.Lock()

PROJECTS = [
    {"id": "p1", "path": "/home/charlie/CoQuant", "name": "CoQuant"},
    {"id": "p2", "path": "/home/charlie/xorl", "name": "xorl"},
]

TASKS = {
    "p1": [
        {"slug": "video2bit", "title": "video2bit", "agent": "cursor",
         "tmux_interview_target": "loom-cursor-video2bit:0.0"},
        {"slug": "quant-eval", "title": "quant eval harness", "agent": "claude",
         "tmux_interview_target": "loom-claude-quant-eval:0.0"},
    ],
    "p2": [
        {"slug": "web-refactor", "title": "web refactor", "agent": "claude",
         "tmux_interview_target": "loom-claude-web-refactor:0.0"},
        {"slug": "paper-draft", "title": "paper draft", "agent": "codex",
         "tmux_interview_target": ""},
    ],
}

# key -> activity entry; video2bit spins, quant-eval blinks, web-refactor idles
ACTIVITY = {
    "p1/video2bit": {"project": "p1", "slug": "video2bit", "working": True, "finished_at": 0},
    "p1/quant-eval": {"project": "p1", "slug": "quant-eval", "working": False,
                      "finished_at": START - 60},
    "p2/web-refactor": {"project": "p2", "slug": "web-refactor", "working": False,
                        "finished_at": 0},
}

_mid = [0]


def msg(kind, **kw):
    _mid[0] += 1
    return {"id": f"m{_mid[0]}", "kind": kind, "created_at": time.time(), **kw}


FEEDS = {
    "p1/video2bit": {
        "session_id": "sess-video2bit",
        "messages": [
            msg("user", text="Quantize the video encoder to 2-bit and keep PSNR above 38."),
            msg("assistant", text="I'll start by profiling the current encoder. **Plan**: measure baseline, then apply progressive quantization with a distillation loss."),
            msg("tool", tool={"name": "Shell", "summary": "python profile_encoder.py --all-layers",
                              "status": "completed",
                              "input": "python profile_encoder.py --all-layers",
                              "output": "baseline PSNR: 41.3 dB\nlayers: 48\nparams: 2.1B"}),
            msg("event", text="Worktree zhongzhu/video2bit created"),
            msg("assistant", text="Baseline is 41.3 dB. Profiling notes:\n\n> PSNR holds above 38 up to layer 30; the tail layers are the fragile ones.\n\n---\n\nNow running the 2-bit sweep — this takes a while."),
            msg("tool", tool={"name": "Shell", "summary": "python quantize.py --bits 2 --distill",
                              "status": "running",
                              "input": "python quantize.py --bits 2 --distill"}),
        ],
    },
    "p1/quant-eval": {
        "session_id": "sess-quant-eval",
        "messages": [
            msg("user", text="Build an eval harness comparing all quant levels."),
            msg("assistant", text="Harness is done and the sweep finished. Results:\n\n- 8-bit: 41.1 dB\n  - attention layers: 41.3 dB\n  - mlp layers: 40.9 dB\n- 4-bit: 40.2 dB\n- 2-bit: 38.4 dB\n\nRemaining steps:\n\n1. Freeze the tail layers at 4-bit\n2. Re-run the sweep overnight\n\nOne decision left before I write the report."),
            msg("question", question={
                "id": "q1", "title": "Report format", "status": "pending",
                "questions": [{
                    "id": "q1a",
                    "prompt": "Which format should the final eval report use?",
                    "allow_multiple": False,
                    "options": [
                        {"id": "o1", "label": "Markdown table in PLAN.md", "value": "markdown",
                         "description": "Simple, versioned with the task"},
                        {"id": "o2", "label": "Jupyter notebook with plots", "value": "notebook",
                         "description": "Interactive, heavier"},
                        {"id": "o3", "label": "Other", "value": "other"},
                    ],
                }],
            }),
        ],
    },
    "p2/web-refactor": {
        "session_id": "sess-web-refactor",
        "messages": [
            msg("user", text="Split app.js into modules without changing behavior."),
            msg("assistant", text="Done. `app.js` is now 6 modules with an entry shim; all 214 tests pass. Ready for review in the Changes tab."),
        ],
    },
    "p2/paper-draft": {
        "session_id": None,
        "messages": [],
    },
}


def feed_working(key):
    return bool(ACTIVITY.get(key, {}).get("working"))


def feed_online(key):
    slug = key.split("/", 1)[1]
    project = key.split("/", 1)[0]
    meta = next((t for t in TASKS.get(project, []) if t["slug"] == slug), None)
    return bool(meta and meta.get("tmux_interview_target"))


def schedule_reply(key, text):
    """Simulate the agent chewing on a message, then replying."""
    def run():
        with LOCK:
            ACTIVITY.setdefault(key, {"project": key.split("/")[0],
                                      "slug": key.split("/")[1],
                                      "working": False, "finished_at": 0})
            ACTIVITY[key]["working"] = True
            ACTIVITY[key]["finished_at"] = 0
        time.sleep(4)
        with LOCK:
            FEEDS[key]["messages"].append(msg(
                "assistant",
                text=f"(mock) Acknowledged: “{text[:80]}”. I did the thing — check the diff when ready.",
            ))
            ACTIVITY[key]["working"] = False
            ACTIVITY[key]["finished_at"] = time.time()
    threading.Thread(target=run, daemon=True).start()


class Handler(BaseHTTPRequestHandler):
    def _json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("[mock] %s\n" % (fmt % args))

    def _key(self, parsed, slug):
        project = parse_qs(parsed.query).get("project", ["p1"])[0]
        return f"{project}/{slug}", project

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        with LOCK:
            if path == "/api/projects":
                return self._json({"projects": PROJECTS})
            if path == "/api/tasks":
                project = parse_qs(parsed.query).get("project", ["p1"])[0]
                return self._json({"tasks": TASKS.get(project, [])})
            if path == "/api/activity":
                return self._json({"ok": True, "tasks": ACTIVITY})
            parts = path.strip("/").split("/")
            # /api/tasks/<slug>/conversation
            if len(parts) == 4 and parts[:2] == ["api", "tasks"] and parts[3] == "conversation":
                key, _ = self._key(parsed, parts[2])
                feed = FEEDS.get(key, {"session_id": None, "messages": []})
                messages = feed["messages"]
                return self._json({
                    "ok": True, "available": True, "agent": "mock",
                    "online": feed_online(key), "working": feed_working(key),
                    "session_id": feed["session_id"], "updated_at": time.time(),
                    "messages": messages[-160:], "total": len(messages),
                    "has_more": len(messages) > 160,
                })
            # /api/tasks/<slug>
            if len(parts) == 3 and parts[:2] == ["api", "tasks"]:
                key, project = self._key(parsed, parts[2])
                meta = next((t for t in TASKS.get(project, []) if t["slug"] == parts[2]), None)
                if not meta:
                    return self._json({"error": "not found"}, 404)
                return self._json({
                    "meta": meta,
                    "claude": {
                        "tmux_target": meta.get("tmux_interview_target", ""),
                        "tmux_alive": feed_online(key),
                        "agent_running": feed_online(key),
                    },
                })
        self._json({"error": "unknown route"}, 404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}") if length else {}
        parts = path.strip("/").split("/")

        with LOCK:
            if path == "/api/activity/ack":
                project = parse_qs(parsed.query).get("project", ["p1"])[0]
                key = f"{project}/{body.get('slug', '')}"
                if key in ACTIVITY:
                    ACTIVITY[key]["finished_at"] = 0
                return self._json({"ok": True})
            if path == "/api/tmux/send-key":
                return self._json({"ok": True})
            if len(parts) == 5 and parts[3] == "claude" and parts[4] == "send":
                key, _ = self._key(parsed, parts[2])
                text = str(body.get("text", ""))
                FEEDS.setdefault(key, {"session_id": f"sess-{parts[2]}", "messages": []})
                FEEDS[key]["messages"].append(msg("user", text=text))
                schedule_reply(key, text)
                return self._json({"ok": True})
            if len(parts) == 5 and parts[3] == "conversation" and parts[4] == "answer":
                key, _ = self._key(parsed, parts[2])
                for m in FEEDS.get(key, {}).get("messages", []):
                    q = m.get("question")
                    if q and q.get("id") == body.get("question_id"):
                        q["status"] = "answered"
                        q["answer"] = body.get("custom_text") or ", ".join(
                            body.get("selected_ids", []))
                FEEDS[key]["messages"].append(msg("event", text="Answer sent to agent"))
                schedule_reply(key, "answer")
                return self._json({"ok": True})
            if len(parts) == 5 and parts[3] == "interview" and parts[4] == "start":
                key, project = self._key(parsed, parts[2])
                for t in TASKS.get(project, []):
                    if t["slug"] == parts[2] and not t.get("tmux_interview_target"):
                        t["tmux_interview_target"] = f"loom-mock-{parts[2]}:0.0"
                ACTIVITY.setdefault(key, {"project": project, "slug": parts[2],
                                          "working": False, "finished_at": 0})
                return self._json({"ok": True, "target": f"loom-mock-{parts[2]}:0.0"})
        self._json({"error": "unknown route"}, 404)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"mock loom listening on http://127.0.0.1:{PORT}")
    server.serve_forever()

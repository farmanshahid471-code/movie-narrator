"""Transport and real background-task lifecycle regression tests (no LLM calls)."""
import time
from types import SimpleNamespace
from unittest.mock import patch

import pytest

pytest.importorskip("movie_narrator_web")
from fastapi.testclient import TestClient
from movie_narrator.web_ui import create_app


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    with TestClient(create_app()) as client:
        yield client


def wait_terminal(client, task_id):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        data = client.get(f"/api/tasks/{task_id}/progress").json()
        if data["status"] != "running":
            return data
        time.sleep(0.01)
    pytest.fail("Background task did not reach a terminal state")


def test_rest_fallback_completes_without_websocket(client):
    ctx = SimpleNamespace(services=SimpleNamespace(console=None), video_path=None)
    def pipeline(ctx, **kwargs):
        ctx.services.console.step("script")
        ctx.services.console.warn("Generating outline")

    with patch("movie_narrator.contract.build_context", return_value=ctx) as build, \
         patch("movie_narrator.contract.run_pipeline", side_effect=pipeline), \
         patch("movie_narrator_web.tasks.collect_artifacts", return_value=[]):
        response = client.post("/api/tasks", data={"movie": "Test movie", "format": "9:16"})
        assert response.status_code == 200
        task_id = response.json()["task_id"]
        data = wait_terminal(client, task_id)
    assert data["status"] == "done"
    assert "Generating outline" in data["log"]
    assert data["current_step"] == "script"
    assert build.call_args.kwargs["video_format"] == "9:16"
    assert "format" not in build.call_args.kwargs
    # Logs survive after the task exits, even without a browser connection.
    info = client.app.state.task_manager.get_task(task_id)
    deadline = time.monotonic() + 3
    while not (info.output_dir / "web-task.log").exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert "Generating outline" in (info.output_dir / "web-task.log").read_text()


def test_worker_error_visible_without_websocket(client):
    with patch("movie_narrator.contract.build_context", side_effect=RuntimeError("Model unavailable")):
        task_id = client.post("/api/tasks", data={"movie": "Test"}).json()["task_id"]
        data = wait_terminal(client, task_id)
    assert data["status"] == "failed"
    assert "Model unavailable" in data["error"]


def test_websocket_delivers_terminal_and_unknown_task(client):
    with client.websocket_connect("/ws/task/missing") as ws:
        assert ws.receive_json()["error"] == "Task not found"
    with patch("movie_narrator.contract.build_context", side_effect=RuntimeError("Failure")):
        task_id = client.post("/api/tasks", data={"movie": "Test"}).json()["task_id"]
        wait_terminal(client, task_id)
        with client.websocket_connect(f"/ws/task/{task_id}") as ws:
            ws.send_json({"action": "subscribe"})
            assert ws.receive_json()["type"] == "progress"
            terminal = ws.receive_json()
            assert terminal["status"] == "failed"
            assert "Failure" in terminal["error"]


def test_frontend_has_polling_and_no_cached_stale_bundle(client):
    import movie_narrator_web
    from pathlib import Path
    bundle = next((Path(movie_narrator_web.__file__).parent / "static/assets").glob("index-*.js"))
    response = client.get(f"/assets/{bundle.name}")
    assert response.status_code == 200
    assert "'/progress'" in response.text
    assert "AbortSignal.timeout(10000)" in response.text
    assert "clearTimeout(timer)" in response.text
    assert response.headers["cache-control"] == "no-store"
    assert client.get("/api/tasks/unknown/progress").status_code == 404


def test_repeat_submit_is_not_silently_queued(client):
    import threading
    entered = threading.Event()
    release = threading.Event()
    ctx = SimpleNamespace(services=SimpleNamespace(console=None), video_path=None)

    def pipeline(*args, **kwargs):
        entered.set()
        assert release.wait(5)

    with patch("movie_narrator.contract.build_context", return_value=ctx), \
         patch("movie_narrator.contract.run_pipeline", side_effect=pipeline), \
         patch("movie_narrator_web.tasks.collect_artifacts", return_value=[]):
        try:
            first = client.post("/api/tasks", data={"movie": "First"})
            assert entered.wait(3)
            second = client.post("/api/tasks", data={"movie": "Second"})
            assert second.status_code == 409
            assert "already running" in second.json()["detail"]
        finally:
            release.set()
        assert wait_terminal(client, first.json()["task_id"])["status"] == "done"

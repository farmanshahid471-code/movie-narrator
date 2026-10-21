# Web UI accepts a task but appears stuck

An HTTP `POST /api/tasks` response of `200 OK` means the task was accepted,
not that a recap was generated. The pipeline runs in another thread. The
external `movie-narrator-web==1.0.4` frontend relies on WebSockets alone;
if that connection fails, neither progress nor a worker exception reaches
the page. Its worker also does not print caught exceptions to Uvicorn's log.
An unannotated upstream WebSocket route is another compatibility problem
with FastAPI (previously patched in `run.bat`).

## Updated launcher

Use the updated **src folder and run.bat together**, keeping `.env`, `.venv`,
`tools`, and output files. Close the old Web UI server window before restarting
`run.bat` option 2. Refresh the browser with Ctrl+F5. Installing just a new
`run.bat`, or refreshing without restarting Python, does not update running code.

Option 2 now uses:

```bat
.venv\Scripts\python.exe -m movie_narrator.web_ui --host 127.0.0.1 --port 8760
```

The launcher keeps the installed UI, form fields and task APIs, but provides:

- A correctly annotated WebSocket endpoint.
- HTTP progress polling every two seconds, independent of WebSocket availability.
- Cleanup of timers/sockets when the page changes or a task finishes.
- Stage messages, worker errors, and 15-second waiting heartbeats in the terminal.
- Per-task `output/<movie>/<task-id>/web-task.log`, written while the task runs.
- A startup error if the pinned UI bundle is no longer compatible, rather than
  silently serving a broken progress hook.

Check `http://127.0.0.1:8760/api/health`: the new launcher returns
`"progress_fallback": true`. If it is absent, an old server/launcher is still running.

A heartbeat means the worker is **waiting**, not that an external API has made
progress. LLM requests can wait up to `MN_LLM_TIMEOUT` per request and retry on
transient failures; the Windows configuration uses 600 seconds. Removing
application token caps does not remove the provider's output limits or reduce
its response latency. Use the named step and final error to diagnose the actual
provider/network issue instead of repeatedly submitting jobs to the single-worker
queue. Cancel is cooperative: an in-flight external request may need to return
or time out before cancellation takes effect.

## Validation

Install the optional web UI and run:

```sh
python -m pip install -e . movie-narrator-web==1.0.4 pytest
python -m pytest tests/test_web_ui.py
```

The tests submit real HTTP task requests, execute the background worker with
mocked pipeline calls (no paid APIs), and verify both REST-only completion/error
reporting and WebSocket terminal delivery. A live LLM/FFmpeg/TTS run still depends
on local credentials, network access, source media and binaries.

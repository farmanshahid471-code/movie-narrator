"""Reliable launcher for the separately installed movie-narrator-web 1.0.4.

Own the transport boundary without editing the installed server/tasks modules.
Pipeline failures remain failures; heartbeats report waiting, not fake progress.
"""
from __future__ import annotations

import argparse
import hashlib
import logging
import threading
import time
from pathlib import Path

log = logging.getLogger("uvicorn.error")


def _frontend_with_polling(source: str) -> str:
    """Add a REST safety net to the pinned UI's WebSocket hook."""
    start = source.find("function Eo(e,t){")
    end = source.find("var Do=", start)
    if start < 0 or end < 0:
        raise RuntimeError("Unsupported web UI assets; install movie-narrator-web==1.0.4")
    hook = '''function Eo(e,t){
let socket=(0,S.useRef)(null),[connected,setConnected]=(0,S.useState)(false);
(0,S.useEffect)(()=>{
 if(!e)return;
 let stopped=false,timer=null,ws=null,terminal=false;
 const deliver=data=>{if(stopped)return;t(data);if(data.type==='terminal')terminal=true;};
 const poll=async()=>{
  try{
   const res=await fetch('/api/tasks/'+encodeURIComponent(e)+'/progress',{cache:'no-store',signal:AbortSignal.timeout(10000)});
   if(!res.ok)throw Error('Progress HTTP '+res.status);
   const data=await res.json();
   deliver({type:'progress',step:data.current_step,log:data.log});
   if(['done','failed','cancelled'].includes(data.status))deliver({...data,type:'terminal'});
  }catch(err){if(!stopped)console.warn('Task progress polling failed:',err);}
  if(!stopped&&!terminal)timer=setTimeout(poll,2000);
 };
 poll();
 try{
  ws=new WebSocket(Co(e));socket.current=ws;
  ws.onopen=()=>{if(stopped){ws.close();return;}setConnected(true);};
  ws.onmessage=event=>{try{deliver(JSON.parse(event.data));}catch(err){console.warn(err);}};
  ws.onclose=()=>{if(!stopped)setConnected(false);};
  ws.onerror=()=>{if(!stopped)setConnected(false);};
 }catch(err){console.warn('Using REST progress fallback:',err);}
 return()=>{stopped=true;clearTimeout(timer);if(ws){ws.onclose=null;ws.close();}socket.current=null;};
},[e,t]);
return {connected,sendCancel:(0,S.useCallback)(()=>{if(socket.current?.readyState===1)socket.current.send(JSON.stringify({action:'cancel'}));},[])};
}'''
    return source[:start] + hook + source[end:]


def create_app():
    from fastapi import FastAPI, HTTPException, WebSocket
    from fastapi.responses import Response
    from fastapi.staticfiles import StaticFiles
    import movie_narrator_web
    from movie_narrator_web import tasks
    from movie_narrator_web.routes import create_router
    from movie_narrator_web.ws import task_ws_endpoint

    # FastAPI resolves postponed annotations against module globals.
    globals()["WebSocket"] = WebSocket
    original_args = tasks.form_to_context_args

    def context_args(data):
        kwargs = original_args(data)
        if "format" in kwargs:
            kwargs["video_format"] = kwargs.pop("format")
        return kwargs

    # Patch once, including when tests create multiple application instances.
    if not getattr(tasks.form_to_context_args, "_engine_compat", False):
        context_args._engine_compat = True
        tasks.form_to_context_args = context_args

    class ObservableManager(tasks.TaskManager):
        def __init__(self):
            super().__init__()
            self._submission_lock = threading.Lock()

        def create_task(self, request, video_path=None, bgm_path=None):
            # The upstream single-worker pool silently queues repeat submits.
            # Reject overlap instead of showing another indefinitely running job.
            with self._submission_lock:
                with self._lock:
                    active = any(info.status == "running" for info in self._tasks.values())
                if active:
                    raise HTTPException(
                        409,
                        "A recap is already running. Wait for it to finish or cancel it. "
                        "An in-flight API call must return before cancellation completes.",
                    )
                return super().create_task(request, video_path=video_path, bgm_path=bgm_path)

        def _run_task(self, task_id, form_data, output_dir):
            info = self.get_task(task_id)
            stop = threading.Event()
            started = time.monotonic()
            log.info("Task %s starting; output: %s", task_id, output_dir)
            file_lock = threading.Lock()

            def report(message):
                log.info("Task %s: %s", task_id, message)
                try:
                    with file_lock:
                        with (Path(output_dir) / "web-task.log").open("a", encoding="utf-8") as stream:
                            stream.write(str(message) + "\n")
                except OSError:
                    log.exception("Could not append task log for %s", task_id)

            append = info.console._append
            step = info.console.step

            def mirrored_append(message):
                append(message)
                report(message)

            def mirrored_step(name):
                step(name)
                report(f"Starting step: {name}")

            info.console._append = mirrored_append
            info.console.step = mirrored_step
            report("Worker started; preparing pipeline context")

            def heartbeat():
                while not stop.wait(15):
                    _, _, step = info.console.snapshot()
                    message = (
                        f"Task {task_id}: waiting in {step or 'initialization'} "
                        f"({time.monotonic() - started:.0f}s elapsed). "
                        "External API calls may take several minutes."
                    )
                    info.console.warn(message)

            thread = threading.Thread(target=heartbeat, daemon=True)
            thread.start()
            try:
                super()._run_task(task_id, form_data, output_dir)
            except Exception as exc:
                # Also catch errors before the upstream worker's try block.
                log.exception("Task %s worker crashed", task_id)
                info.set_terminal("failed", str(exc))
            finally:
                stop.set()
                thread.join(timeout=1)
                _, text, _ = info.console.snapshot()
                try:
                    (Path(output_dir) / "web-task.log").write_text(
                        text + "\n" + (info.error or info.status), encoding="utf-8"
                    )
                except OSError:
                    log.exception("Could not write task log for %s", task_id)
                log.info("Task %s finished: %s", task_id, info.status)
                if info.error:
                    log.error("Task %s: %s", task_id, info.error)

    app = FastAPI(title="Movie Narrator Web UI")
    manager = ObservableManager()
    app.state.task_manager = manager
    uploads = Path("output/_uploads")
    uploads.mkdir(parents=True, exist_ok=True)
    app.include_router(create_router(manager, uploads))

    @app.get("/api/tasks/{task_id}/progress")
    async def progress(task_id: str):
        info = manager.get_task(task_id)
        if info is None:
            raise HTTPException(404, "Task not found")
        status = info.to_status_dict()
        version, text, _ = info.console.snapshot()
        return {**status, "version": version, "log": text}

    @app.websocket("/ws/task/{task_id}")
    async def websocket(websocket: WebSocket, task_id: str):
        await task_ws_endpoint(websocket, task_id, manager)

    @app.get("/api/health")
    async def health():
        return {"status": "ok", "progress_fallback": True}

    static = Path(movie_narrator_web.__file__).parent / "static"
    # Validate the pinned bundle at startup, not after the user submits a job.
    bundles = list((static / "assets").glob("index-*.js"))
    if len(bundles) != 1:
        raise RuntimeError("Expected movie-narrator-web==1.0.4 frontend bundle")
    javascript = _frontend_with_polling(bundles[0].read_text(encoding="utf-8"))

    @app.get(f"/assets/{bundles[0].name}")
    async def bundle():
        return Response(javascript, media_type="text/javascript", headers={"Cache-Control": "no-store"})

    # The modified bundle retains the upstream filename. Give it a content
    # revision so a browser cannot reuse a pre-patch cached copy of that file.
    revision = hashlib.sha256(javascript.encode("utf-8")).hexdigest()[:16]
    html = (static / "index.html").read_text(encoding="utf-8")
    html = html.replace(
        f'/assets/{bundles[0].name}', f'/assets/{bundles[0].name}?v={revision}'
    )
    bootstrap = """<script>
(function(){
 let failure=null;
 function show(message){
  failure=message;
  const root=document.getElementById('root');
  if(!root||root.querySelector('[data-ui-error]'))return;
  const box=document.createElement('section');box.dataset.uiError='true';
  box.style.cssText='margin:40px auto;max-width:760px;padding:24px;color:#e2e8f0;background:#172033;font:16px/1.6 system-ui;white-space:pre-wrap';
  const title=document.createElement('h2');title.textContent='Movie Narrator could not load the interface';
  const detail=document.createElement('p');detail.textContent=message;
  const help=document.createElement('p');help.textContent='Restart run.bat, then press Ctrl+F5. If this persists, copy the message below and the browser Console error. The backend may still be healthy.';
  const reload=document.createElement('button');reload.textContent='Reload interface';reload.onclick=()=>location.reload();
  box.append(title,detail,help,reload);root.replaceChildren(box);
 }
 window.addEventListener('error',event=>{
  if(event.target && event.target.tagName==='SCRIPT')show('JavaScript asset failed to load: '+event.target.src);
  else if(event.message)show(event.message);
 },true);
 window.addEventListener('unhandledrejection',event=>show(String(event.reason?.message||event.reason||'Unknown JavaScript error')));
 document.addEventListener('DOMContentLoaded',()=>{
  if(failure)show(failure);
  setTimeout(()=>{
   const root=document.getElementById('root');
   if(root && (!root.childElementCount||root.querySelector('[data-ui-loading]')))
    show('The frontend did not start within 12 seconds. Check the browser Console and Network tabs for a blocked or failed JavaScript module.');
  },12000);
 });
})();
</script>"""
    html = html.replace('<script type="module"', bootstrap + '<script type="module"', 1)
    html = html.replace(
        '<div id="root"></div>',
        '<div id="root"><p data-ui-loading style="padding:32px;color:#e2e8f0">Loading Movie Narrator…</p></div>',
    )

    @app.get("/", include_in_schema=False)
    async def index():
        return Response(html, media_type="text/html", headers={"Cache-Control": "no-store"})

    @app.get("/index.html", include_in_schema=False)
    async def index_file():
        return await index()

    app.mount("/", StaticFiles(directory=str(static), html=True), name="static")
    return app


def main():
    import uvicorn

    parser = argparse.ArgumentParser(description="Launch the reliable Movie Narrator Web UI")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8760)
    args = parser.parse_args()
    uvicorn.run(create_app(), host=args.host, port=args.port)


if __name__ == "__main__":
    main()

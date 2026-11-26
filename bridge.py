#!/usr/bin/env python3
"""Background language answers via Pi; explicit handoff to the Codex chat.

Pi owns authentication. Codex handoff uses its documented queue CLI only.
The legacy readback path remains available without acquiring a live writer.
"""
import json
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

PI_PROVIDER = "qoder-cn"
PI_MODEL = "DeepSeek-Flash"
PI_EFFORT = "high"


def pi_environment(inherited=None):
    """GUI/launchd processes do not inherit a login shell's Homebrew PATH."""
    env = dict(os.environ if inherited is None else inherited)
    home = Path.home()
    data_home = Path(env.get("XDG_DATA_HOME") or home / ".local/share")
    candidates = [str(data_home / "pi-node/current/bin"), "/opt/homebrew/bin",
                  "/usr/local/bin", str(home / ".local/bin")]
    candidates += (env.get("PATH") or os.defpath).split(os.pathsep)
    candidates += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    env["PATH"] = os.pathsep.join(dict.fromkeys(p for p in candidates if p and os.path.isabs(p)))
    return env


def pi_command(provider=PI_PROVIDER, model=PI_MODEL, effort=PI_EFFORT):
    home = Path.home()
    candidates = (home / ".local/bin/pi", shutil.which("pi", path=pi_environment()["PATH"]))
    pi = next((str(p) for p in candidates if p and os.access(p, os.X_OK)), None)
    extension = home / ".pi/agent/npm/node_modules/pi-provider-qoder/dist/index.js"
    if not pi:
        raise RuntimeError("找不到 Pi；可检查 Pi 的安装。")
    for value in (provider,model):
        if not isinstance(value,str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/+ -]{0,159}",value):
            raise RuntimeError("请在设置中指定有效 Pi provider 和 model。")
    if effort not in {"off","minimal","low","medium","high","max"}:
        raise RuntimeError("不支持该思考档位。")
    if provider in {"qoder-cn","qoder"} and model=="DeepSeek-Flash" and effort not in {"off","low","high","max"}:
        raise RuntimeError("DeepSeek-Flash 支持 Low/High/Max；请选择其一或 Off。")
    extensions = ["--no-extensions"]
    if provider in {"qoder-cn","qoder"}:
        if not extension.is_file():
            raise RuntimeError("找不到 Pi 的 Qoder 扩展；请在 Pi 中安装并登录。")
        extensions += ["--extension",str(extension)]
    return [pi, *extensions,
            "--provider", provider, "--model", model, "--thinking", effort,
            "--no-session", "--no-tools", "--no-mcp", "--no-skills",
            "--no-context-files", "--no-prompt-templates", "--no-themes", "--no-approve",
            "--system-prompt", "You are Vocab's concise English language tutor. Never use tools. "
            "Follow the user's requested output format. For practice prompts never reveal the target "
            "expression or an answer; describe a concrete situation instead. Distinguish dictionary "
            "evidence supplied by the user from your interpretation.", "--mode", "json", "-p"]


def pi_answer(output, provider=PI_PROVIDER, model=PI_MODEL):
    """Use only the final successful assistant event from the explicitly selected provider."""
    answer = None
    for line in output.splitlines():
        try:
            event = json.loads(line)
        except (ValueError, UnicodeError):
            continue
        if not isinstance(event, dict) or event.get("type") != "message_end":
            continue
        msg = event.get("message") or {}
        if msg.get("role") == "assistant":
            answer = msg
    if not answer or answer.get("stopReason") != "stop":
        raise RuntimeError("AI 暂未返回完整回复；可重试或在 Codex 继续聊。")
    if answer.get("provider") != provider or answer.get("model") != model:
        raise RuntimeError("Pi 返回的模型与本机配置不一致，未采用该回复。")
    text = "\n".join(c.get("text", "") for c in answer.get("content", [])
                     if c.get("type") == "text").strip()
    if not text:
        raise RuntimeError("AI 返回空回复；可重试或在 Codex 继续聊。")
    return text


def pi_failure(returncode, output, stderr, provider=PI_PROVIDER):
    """Classify errors without exposing raw provider logs or credentials in the UI."""
    if returncode == 127 or re.search(r"\bnode:\s*(?:no such file|not found|command not found)", stderr, re.I):
        return "Pi 的 Node.js 运行环境不可用；请检查本机 Pi 安装。"
    diagnostics = stderr
    for line in output.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict):
            msg = event.get("message") or {}
            if isinstance(msg, dict) and msg.get("role") == "assistant":
                diagnostics += "\n" + str(msg.get("errorMessage") or "")
    if re.search(r"\b401\b|unauthorized|not authenticated|invalid credentials|login required|no api key", diagnostics, re.I):
        return f"{provider} 登录过期或不可用；请在 Pi 中重新登录。"
    if re.search(r"\b429\b|quota|rate.limit|usage limit|insufficient credits", diagnostics, re.I):
        return f"{provider} 当前额度或请求频率受限；可稍后重试。"
    if re.search(r"\bECONN|ENOTFOUND|ETIMEDOUT|network error|connection refused|fetch failed", diagnostics, re.I):
        return f"连接 {provider} 失败；请检查网络后重试。"
    return f"Pi 后台请求失败（退出码 {returncode}）；可重试或在 Codex 继续聊。"


def stop_process_group(proc):
    # The group is the request's own newly created session, not a shared Pi.
    # Even if the leader has exited, its descendants might still own pipes.
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    if proc.poll() is None:
        proc.wait()


def direct_answer(args, request_id):
    provider, model, effort=(args.get("provider",PI_PROVIDER),args.get("model",PI_MODEL),args.get("effort",PI_EFFORT))
    command = pi_command(provider,model,effort)
    env = pi_environment()
    if not shutil.which("node", path=env["PATH"]):
        raise RuntimeError("找不到 Pi 所需的 Node.js；请检查本机 Pi 安装。")
    # The prompt travels via stdin, not a command-line argument or a saved session.
    # An empty working directory prevents implicit project context and files.
    proc = None
    cancelled = False

    def interrupted(_signum, _frame):
        nonlocal cancelled
        cancelled = True
        # If interrupted inside Popen before the child is assigned, wait until
        # it has been assigned so the finally block owns the exact group.
        if proc is not None:
            raise KeyboardInterrupt()

    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        with tempfile.TemporaryDirectory(prefix="vocab-ai-") as work:
            try:
                proc = subprocess.Popen(command, cwd=work, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, start_new_session=True, env=env)
                if cancelled:
                    raise KeyboardInterrupt()
                emit("started", request=request_id, model=model, provider=provider, effort=effort)
                output, stderr = proc.communicate(args["prompt"], timeout=min(120, float(args.get("timeout", 90))))
                if proc.returncode:
                    raise RuntimeError(pi_failure(proc.returncode, output, stderr,provider))
                reply = pi_answer(output,provider,model)
                emit("result", request=request_id, text=reply, model=model,
                     provider=provider, effort=effort)
            except subprocess.TimeoutExpired:
                emit("timeout", request=request_id, text="AI 回复超时；可重试或在 Codex 继续聊。")
            except KeyboardInterrupt:
                pass
            finally:
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                if proc is not None:
                    stop_process_group(proc)
    finally:
        signal.signal(signal.SIGTERM, previous)


def codex_path():
    for path in ("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                 shutil.which("codex")):
        if path and os.access(path, os.X_OK):
            return path
    raise RuntimeError("找不到 Codex；请打开或安装 ChatGPT 桌面应用。")


def emit(kind, **fields):
    print(json.dumps(dict(type=kind, **fields), ensure_ascii=False), flush=True)


class Reader:
    def __init__(self, codex):
        self.proc = subprocess.Popen(
            [codex, "app-server", "--stdio"], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        self.buffer = b""
        self.next_id = 0
        try:
            self.rpc("initialize", {"clientInfo": {"name": "vocab-readback", "version": "2.0"}})
            self.send({"method": "initialized"})
        except BaseException:
            self.close()
            raise

    def send(self, data):
        self.proc.stdin.write(json.dumps(data).encode() + b"\n")
        self.proc.stdin.flush()

    def rpc(self, method, params):
        self.next_id += 1
        idx = self.next_id
        self.send({"id": idx, "method": method, "params": params})
        end = time.monotonic() + 8
        while time.monotonic() < end:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                try:
                    obj = json.loads(line)
                except (ValueError, UnicodeError):
                    continue
                if obj.get("id") != idx:
                    continue
                if "error" in obj:
                    raise RuntimeError(str(obj["error"].get("message", "读取聊天失败")))
                return obj["result"]
            if select.select([self.proc.stdout], [], [], .4)[0]:
                data = os.read(self.proc.stdout.fileno(), 65536)
                if not data:
                    raise RuntimeError("Codex 读取服务已退出")
                self.buffer += data
        raise RuntimeError("读取聊天超时")

    def turns(self, thread_id):
        return self.rpc("thread/turns/list", {"threadId": thread_id,
                        "limit": 20, "sortDirection": "desc", "itemsView": "full"})["data"]

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()


def find_reply(turns, marker):
    """Correlate to the USER item, never search for a marker in model text."""
    for turn in turns:
        items = turn.get("items") or []
        matched = any(
            item.get("type") == "userMessage" and any(
                content.get("type") == "text" and content.get("text", "").startswith(marker)
                for content in item.get("content", []))
            for item in items)
        if not matched:
            continue
        state = turn.get("status")
        final = [i for i in items if i.get("type") == "agentMessage"
                 and i.get("phase") == "final_answer" and i.get("text")]
        if state == "completed" and final:
            return "completed", turn.get("id"), final[-1]["text"]
        # A read-only App Server rebuilds a turn from the durable log; while
        # Desktop is still writing it can temporarily look "interrupted".
        # Do not treat that transient reconstruction as a completed failure.
        if state == "failed" and turn.get("error") and turn.get("completedAt"):
            return "failed", turn.get("id"), "语言助手没有完成本轮。可在完整聊天中查看。"
        return "started", turn.get("id"), ""
    return "waiting", None, ""


def main():
    args = json.load(sys.stdin)
    request_id = args.get("request") or str(uuid.uuid4())
    uuid.UUID(request_id)
    if args.get("route") == "pi":
        try:
            direct_answer(args, request_id)
        except Exception as e:
            emit("error", request=request_id, text=str(e))
        return
    thread = args["thread"]
    # Never accept a path/option in place of a thread ID.
    uuid.UUID(thread)
    marker = "[Vocab request " + request_id + "]"
    codex = codex_path()
    reader = None
    try:
        if not args.get("poll_only"):
            # A failure after dispatch is not retried automatically: that would duplicate the turn.
            message = marker + "\n" + args["prompt"]
            p = subprocess.run([codex, "queue", "--thread", thread, "--message", message],
                               text=True, capture_output=True, timeout=12)
            if p.returncode:
                raise RuntimeError((p.stderr or p.stdout or "未成功进入聊天队列").strip()[:500])
            queue = re.search(r"Queued message ([\w-]+)", p.stdout)
            emit("queued", request=request_id, queue=queue.group(1) if queue else "")
            if args.get("route") == "codex_handoff":
                emit("result", request=request_id, text="已发送到 Codex。")
                return
        reader = Reader(codex)
        end = time.monotonic() + float(args.get("timeout", 100))
        began = time.monotonic()
        last_state = None
        told_open = False
        while time.monotonic() < end:
            status, turn_id, reply = find_reply(reader.turns(thread), marker)
            if status in ("completed", "failed"):
                try:
                    meta = reader.rpc("thread/read", {"threadId": thread, "includeTurns": False}).get("thread", {})
                except Exception:
                    meta = {}
                emit("result" if status == "completed" else "error",
                     request=request_id, turn=turn_id, text=reply, model=meta.get("model"), effort=meta.get("reasoningEffort"))
                return
            if status != last_state:
                emit(status, request=request_id, turn=turn_id)
                last_state = status
            if status == "waiting" and not told_open and time.monotonic() - began > 7:
                emit("hint", text="语言助手尚未开始；若聊天未加载，可点「打开完整对话」。")
                told_open = True
            time.sleep(1.15)
        emit("timeout", request=request_id, text="本轮仍可能在排队。打开完整对话或重新查看回复，不重复投递。")
    except Exception as e:
        emit("error", request=request_id, text=str(e))
    finally:
        if reader is not None:
            reader.close()


if __name__ == "__main__":
    # Terminating the local wait must also close our read-only child process;
    # it does not attempt to cancel the user's already queued remote turn.
    def interrupted(signum, frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    main()

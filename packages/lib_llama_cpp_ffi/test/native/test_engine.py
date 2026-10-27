"""Isolated native ABI regression tests. Run: python3 test_engine.py LIB [MODEL]."""
import ctypes
import json
import os
import subprocess
import sys
import threading
import time
import unittest

LIBRARY = sys.argv[1] if len(sys.argv) > 1 else None
MODEL = sys.argv[2] if len(sys.argv) > 2 else None


class Engine:
    def __init__(self, params):
        self.lib = ctypes.CDLL(LIBRARY)
        self.lib.llcs_engine_create.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
        self.lib.llcs_engine_create.restype = ctypes.c_void_p
        self.lib.llcs_engine_destroy.argtypes = [ctypes.c_void_p]
        self.lib.llcs_string_free.argtypes = [ctypes.c_void_p]
        self.lib.llcs_engine_submit.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
        self.lib.llcs_engine_submit.restype = ctypes.c_int64
        self.lib.llcs_engine_poll.argtypes = [ctypes.c_void_p, ctypes.c_int64, ctypes.c_int32]
        self.lib.llcs_engine_poll.restype = ctypes.c_void_p
        self.lib.llcs_engine_cancel.argtypes = [ctypes.c_void_p, ctypes.c_int64]
        self.error = ctypes.c_void_p()
        self.ptr = self.lib.llcs_engine_create(json.dumps(params).encode(), ctypes.byref(self.error))

    def read(self, ptr):
        if not ptr:
            return None
        try:
            value = ctypes.string_at(ptr).decode()
            return json.loads(value) if value else ""
        finally:
            self.lib.llcs_string_free(ptr)

    def submit(self, body):
        err = ctypes.c_void_p()
        task = self.lib.llcs_engine_submit(self.ptr, json.dumps(body).encode(), ctypes.byref(err))
        return task, self.read(err)

    def close(self):
        self.lib.llcs_engine_destroy(self.ptr)

    def complete(self, body):
        task, error = self.submit(body)
        assert task >= 0, error
        events = []
        deadline = time.monotonic() + 90
        drained = False
        while time.monotonic() < deadline:
            event = self.read(self.lib.llcs_engine_poll(self.ptr, task, 100))
            if event is None:
                drained = True
                break
            if event != "":
                assert isinstance(event, dict) and "error" not in event, event
                events.append(event)
        assert drained, "stream timed out"
        assert events and any(c.get("finish_reason") for e in events for c in e["choices"]), events
        assert len({e["id"] for e in events}) == 1
        assert events[0]["choices"][0]["delta"].get("role") == "assistant"
        deltas = [c["delta"] for e in events for c in e["choices"]]
        assert any(d.get("content") or d.get("reasoning_content") or d.get("tool_calls") for d in deltas), events
        return events


def process_resources():
    if sys.platform == "win32":
        from ctypes import wintypes

        class Counters(ctypes.Structure):
            _fields_ = [("cb", wintypes.DWORD), ("faults", wintypes.DWORD)] + [
                (name, ctypes.c_size_t) for name in (
                    "peak_ws", "ws", "qpp", "qpc", "qnpp", "qnpc", "page", "peak_page")]

        class ThreadEntry(ctypes.Structure):
            _fields_ = [("size", wintypes.DWORD), ("usage", wintypes.DWORD),
                        ("thread", wintypes.DWORD), ("owner", wintypes.DWORD),
                        ("base_priority", wintypes.LONG), ("delta_priority", wintypes.LONG),
                        ("flags", wintypes.DWORD)]

        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        psapi = ctypes.WinDLL("psapi", use_last_error=True)
        kernel.GetCurrentProcess.argtypes = []
        kernel.GetCurrentProcess.restype = wintypes.HANDLE
        psapi.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
        psapi.GetProcessMemoryInfo.restype = wintypes.BOOL
        counters = Counters()
        counters.cb = ctypes.sizeof(counters)
        if not psapi.GetProcessMemoryInfo(kernel.GetCurrentProcess(), ctypes.byref(counters), counters.cb):
            raise ctypes.WinError(ctypes.get_last_error())
        kernel.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
        kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle.restype = wintypes.BOOL
        for name in ("Thread32First", "Thread32Next"):
            function = getattr(kernel, name)
            function.argtypes = [wintypes.HANDLE, ctypes.POINTER(ThreadEntry)]
            function.restype = wintypes.BOOL
        snapshot = kernel.CreateToolhelp32Snapshot(0x00000004, 0)  # TH32CS_SNAPTHREAD
        if snapshot == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        count = 0
        try:
            entry = ThreadEntry()
            entry.size = ctypes.sizeof(entry)
            found = kernel.Thread32First(snapshot, ctypes.byref(entry))
            while found:
                count += entry.owner == os.getpid()
                found = kernel.Thread32Next(snapshot, ctypes.byref(entry))
            if ctypes.get_last_error() != 18:  # ERROR_NO_MORE_FILES
                raise ctypes.WinError(ctypes.get_last_error())
        finally:
            kernel.CloseHandle(snapshot)
        return count, counters.ws // 1024
    try:
        with open("/proc/self/status") as status:
            rows = dict(line.split(":", 1) for line in status if ":" in line)
        return int(rows["Threads"]), int(rows["VmRSS"].split()[0])
    except FileNotFoundError:
        return None


def case(name):
    if name == "wrapper_errors":
        lib = ctypes.CDLL(LIBRARY)
        lib.lib_llama_cpp_chat_parse_json.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
        lib.lib_llama_cpp_chat_parse_json.restype = ctypes.c_void_p
        lib.lib_llama_cpp_string_free.argtypes = [ctypes.c_void_p]
        for request in [None, b"[]", b'{"format":123}']:
            error = ctypes.c_void_p()
            result = lib.lib_llama_cpp_chat_parse_json(request, ctypes.byref(error))
            assert not result and error
            value = json.loads(ctypes.string_at(error).decode())
            lib.lib_llama_cpp_string_free(error)
            assert value["code"] == "invalid_request", value
        lib.lib_llama_cpp_chat_templates_caps_json.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        lib.lib_llama_cpp_chat_templates_caps_json.restype = ctypes.c_void_p
        error = ctypes.c_void_p()
        assert not lib.lib_llama_cpp_chat_templates_caps_json(None, ctypes.byref(error))
        value = json.loads(ctypes.string_at(error).decode())
        lib.lib_llama_cpp_string_free(error)
        assert value["code"] == "invalid_request", value
        return
    if name == "shared_abi":
        lib = ctypes.CDLL(LIBRARY)
        lib.llcs_backend_acquire.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        lib.llcs_backend_acquire.restype = ctypes.c_int32
        error = ctypes.c_void_p()
        assert lib.llcs_backend_acquire(ctypes.byref(error)) == 0 and not error
        assert lib.llcs_backend_acquire(ctypes.byref(error)) == 0 and not error
        lib.llcs_backend_release()
        lib.llcs_backend_release()
        lib.llcs_cancel_create.restype = ctypes.c_void_p
        for method in ["free", "request", "reset", "is_requested"]:
            getattr(lib, "llcs_cancel_" + method).argtypes = [ctypes.c_void_p]
        flag = lib.llcs_cancel_create()
        assert flag and lib.llcs_cancel_is_requested(flag) == 0
        lib.llcs_cancel_request(flag)
        assert lib.llcs_cancel_is_requested(flag) == 1
        lib.llcs_cancel_reset(flag)
        assert lib.llcs_cancel_is_requested(flag) == 0
        lib.llcs_cancel_wait_credit.argtypes = [ctypes.c_void_p]
        lib.llcs_cancel_wait_credit.restype = ctypes.c_int32
        lib.llcs_cancel_release_credit.argtypes = [ctypes.c_void_p]
        for _ in range(64):
            assert lib.llcs_cancel_wait_credit(flag) == 1
        returned = []
        waiter = threading.Thread(target=lambda: returned.append(lib.llcs_cancel_wait_credit(flag)))
        waiter.start()
        try:
            waiter.join(0.05)
            assert waiter.is_alive(), "65th response bypassed backpressure"
            lib.llcs_cancel_request(flag)
            waiter.join(2)
            assert returned == [0] and not waiter.is_alive(), returned
        finally:
            lib.llcs_cancel_request(flag)
            waiter.join(2)
        lib.llcs_cancel_reset(flag)
        for _ in range(64):
            assert lib.llcs_cancel_wait_credit(flag) == 1
        lib.llcs_cancel_release_credit(flag)
        assert lib.llcs_cancel_wait_credit(flag) == 1
        lib.llcs_cancel_free(flag)
        return
    if name == "invalid_config":
        for field, value in [("n_ctx", "bad"), ("n_batch", 0), ("n_ubatch", -1),
                             ("n_parallel", 0), ("cache_type_k", "bad"), ("flash_attn", "bad"),
                             ("backend", "bad"), ("require_backend", "bad"), ("n_threads", 513)]:
            engine = Engine({"model_path": "/missing.gguf", field: value})
            assert not engine.ptr
            error = engine.read(engine.error)
            assert error["code"] == "invalid_request", error
        return
    if name == "missing_model":
        engine = Engine({"model_path": "/missing.gguf"})
        assert not engine.ptr
        assert engine.read(engine.error)["code"] == "backend"
        return
    if name == "native_ceiling":
        engine = Engine({"model_path": MODEL, "n_ctx": 2147483647, "n_gpu_layers": 0})
        assert not engine.ptr
        assert engine.read(engine.error)["code"] == "context_overflow"
        return
    engine = Engine({"model_path": MODEL, "n_ctx": 512, "n_batch": 64, "n_ubatch": 64,
                     "n_parallel": 1, "n_gpu_layers": 0,
                     "result_retention_ms": 100 if name == "expiry" else 30000})
    assert engine.ptr, engine.read(engine.error)
    engine.lib.llcs_engine_caps.argtypes = [ctypes.c_void_p]
    engine.lib.llcs_engine_caps.restype = ctypes.c_void_p
    caps = engine.read(engine.lib.llcs_engine_caps(engine.ptr))
    assert caps["effective"]["n_batch"] == 64, caps
    assert caps["effective"]["cache_type_k"] == "f16", caps
    assert caps["effective"]["swa_full"] is False, caps
    assert caps["effective"]["n_threads"] > 0 and caps["effective"]["n_threads_batch"] > 0, caps
    assert caps["supports_tools"] == caps["chat_template_caps"]["supports_tools"], caps
    assert caps["supports_parallel_tool_calls"] == caps["chat_template_caps"]["supports_parallel_tool_calls"], caps
    assert caps["native_n_ctx"] >= caps["effective"]["n_ctx"] and caps["rope_extrapolation"] is False, caps
    body = {"messages": [{"role": "user", "content": "Count from one to five."}],
            "stream": True, "max_tokens": 16, "temperature": 0}
    engine.lib.llcs_engine_prepare.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    engine.lib.llcs_engine_prepare.restype = ctypes.c_void_p
    error = ctypes.c_void_p()
    prepared = engine.read(engine.lib.llcs_engine_prepare(engine.ptr, json.dumps(body).encode(), ctypes.byref(error)))
    assert prepared and prepared["fits"] and prepared["prompt_tokens"] > 0, engine.read(error)
    assert prepared["reserved_output_tokens"] == 16 and prepared["effective_context"] == 512, prepared
    try:
        if name == "invalid_request":
            invalid = [None, [], dict(body, messages="bad"), dict(body, tools="bad"),
                       dict(body, stream="bad"), dict(body, max_tokens="bad"),
                       dict(body, temperature="bad"), dict(body, repeat_last_n=-2),
                       dict(body, max_tokens=1.5), dict(body, stream_options=[]),
                       dict(body, stream_options={"include_usage": "bad"}), dict(body, response_format="bad"),
                       dict(body, temperature=1e100)]
            for request in invalid:
                task, error = engine.submit(request)
                assert task == -1 and error["code"] == "invalid_request", (request, task, error)
                engine.complete(body)
            task, error = engine.submit(dict(body, max_tokens=513))
            assert task == -1 and error["code"] == "context_overflow", (task, error)
            err = ctypes.c_void_p()
            overflow = engine.read(engine.lib.llcs_engine_prepare(engine.ptr,
                json.dumps(dict(body, max_tokens=513)).encode(), ctypes.byref(err)))
            assert overflow and not overflow["fits"], engine.read(err)
            engine.complete(body)
        elif name == "budget_boundary":
            exact_output = prepared["usable_context"] - prepared["prompt_tokens"]
            assert exact_output > 0
            for extra, fits in [(0, True), (1, False)]:
                err = ctypes.c_void_p()
                measured = engine.read(engine.lib.llcs_engine_prepare(engine.ptr,
                    json.dumps(dict(body, max_tokens=exact_output + extra)).encode(), ctypes.byref(err)))
                assert measured and measured["fits"] is fits, engine.read(err)
                assert measured["prompt_tokens"] == prepared["prompt_tokens"], measured
            task, error = engine.submit(dict(body, max_tokens=exact_output + 1))
            assert task == -1 and error["code"] == "context_overflow", (task, error)
            engine.complete(dict(body, max_tokens=exact_output))
        elif name == "queued_cancel":
            engine.lib.llcs_engine_stats.argtypes = [ctypes.c_void_p]
            engine.lib.llcs_engine_stats.restype = ctypes.c_void_p
            long_body = dict(body, max_tokens=128, ignore_eos=True, messages=[
                {"role": "system", "content": "queued cancellation regression unique prefix"},
                {"role": "user", "content": "Count from1 to1000. " + "please " * 200}])
            first, error = engine.submit(long_body)
            assert first >= 0, error
            second, error = engine.submit(body)
            assert second >= 0, error
            stats = engine.read(engine.lib.llcs_engine_stats(engine.ptr))
            queued = next(task for task in stats["tasks"] if task["id"] == second)
            assert queued["state"] == "queued", stats
            engine.lib.llcs_engine_cancel(engine.ptr, second)
            # No poll of the cancelled task is needed to reclaim request state.
            stats = engine.read(engine.lib.llcs_engine_stats(engine.ptr))
            assert all(task["id"] != second for task in stats["tasks"]), stats
            engine.lib.llcs_engine_cancel(engine.ptr, first)
            engine.complete(body)
        elif name == "prefill_state":
            engine.lib.llcs_engine_stats.argtypes = [ctypes.c_void_p]
            engine.lib.llcs_engine_stats.restype = ctypes.c_void_p
            # Leave a nonzero previous decode count in the resident slot.
            engine.complete(body)
            long_body = dict(body, messages=[
                {"role": "system", "content": "fresh prefill state regression prefix"},
                {"role": "user", "content": "please " * 300}])
            task, error = engine.submit(long_body)
            assert task >= 0, error
            saw_prefill = False
            deadline = time.monotonic() + 90
            while True:
                stats = engine.read(engine.lib.llcs_engine_stats(engine.ptr))
                record = next(item for item in stats["tasks"] if item["id"] == task)
                progress = record["prompt_progress"]
                if 0 < progress.get("processed", 0) < progress.get("total", 0):
                    saw_prefill = True
                    assert record["state"] == "prefilling", {"state": record["state"], "progress": progress}
                if record["state"] in ["decoding", "completed"] and progress.get("processed", 0) >= progress.get("total", 1):
                    break
                assert time.monotonic() < deadline, {"state": record["state"], "progress": progress}
                time.sleep(0.001)
            assert saw_prefill, "no actual prefill progress observed"
            engine.lib.llcs_engine_cancel(engine.ptr, task)
            engine.complete(body)
            print(json.dumps({"case": "prefill_state", "observed_partial_prefill": saw_prefill}))
        elif name == "terminal_cancel":
            engine.lib.llcs_engine_stats.argtypes = [ctypes.c_void_p]
            engine.lib.llcs_engine_stats.restype = ctypes.c_void_p
            task, error = engine.submit(body)
            assert task >= 0, error
            deadline = time.monotonic() + 90
            while True:
                stats = engine.read(engine.lib.llcs_engine_stats(engine.ptr))
                if stats["completed"] == 1:
                    break
                assert time.monotonic() < deadline, stats
                time.sleep(0.02)
            assert stats["retained_tasks"] == 1 and stats["cancelled"] == 0, stats
            engine.lib.llcs_engine_cancel(engine.ptr, task)
            stats = engine.read(engine.lib.llcs_engine_stats(engine.ptr))
            assert stats["completed"] == 1 and stats["cancelled"] == 0 and stats["failed"] == 0, stats
            assert stats["retained_tasks"] == 0 and stats["buffered_bytes"] == 0 and stats["pending_cancellations"] == 0, stats
            engine.complete(body)
            stats = engine.read(engine.lib.llcs_engine_stats(engine.ptr))
            assert stats["completed"] == 2 and stats["cancelled"] == 0, stats
            print(json.dumps({"case": "terminal_cancel", "completed": stats["completed"],
                              "cancelled": stats["cancelled"], "retained_tasks": stats["retained_tasks"]}))
        elif name == "expiry":
            engine.lib.llcs_engine_stats.argtypes = [ctypes.c_void_p]
            engine.lib.llcs_engine_stats.restype = ctypes.c_void_p
            task, error = engine.submit(body)
            assert task >= 0, error
            deadline = time.monotonic() + 90
            while True:
                stats = engine.read(engine.lib.llcs_engine_stats(engine.ptr))
                if stats["retained_tasks"] == 0 and stats["expired_results"] == 1:
                    break
                assert time.monotonic() < deadline, stats
                time.sleep(0.02)
            assert stats["buffered_bytes"] == 0 and stats["expiry_tombstones"] == 1, stats
            expired = engine.read(engine.lib.llcs_engine_poll(engine.ptr, task, 0))
            assert expired["error"]["code"] == "result_expired", expired
            assert engine.read(engine.lib.llcs_engine_poll(engine.ptr, task, 0)) is None
            engine.complete(body)
        elif name == "nonstream":
            task, error = engine.submit(dict(body, stream=False))
            assert task >= 0, error
            deadline = time.monotonic() + 90
            while True:
                event = engine.read(engine.lib.llcs_engine_poll(engine.ptr, task, 100))
                assert time.monotonic() < deadline, "nonstream timed out"
                if event != "":
                    break
            assert isinstance(event, dict) and event["object"] == "chat.completion", event
            message = event["choices"][0]["message"]
            assert message.get("content") or message.get("reasoning_content") or message.get("tool_calls"), event
            assert engine.read(engine.lib.llcs_engine_poll(engine.ptr, task, 100)) is None
        elif name in ["stream", "two_engines"]:
            if name == "two_engines":
                other = Engine({"model_path": MODEL, "n_ctx": 512, "n_gpu_layers": 0})
                assert other.ptr, other.read(other.error)
                other.close()
            engine.complete(body)
        elif name == "cancel":
            engine.lib.llcs_engine_stats.argtypes = [ctypes.c_void_p]
            engine.lib.llcs_engine_stats.restype = ctypes.c_void_p
            # A single cancel must permit an immediately succeeding valid task.
            task, error = engine.submit(body)
            assert task >= 0, error
            engine.lib.llcs_engine_cancel(engine.ptr, task)
            engine.complete(body)
            after_warmup = None
            for index in range(100):
                deadline = time.monotonic() + 15
                while True:
                    task, error = engine.submit(body)
                    if task >= 0:
                        break
                    assert error["code"] == "allocation" and time.monotonic() < deadline, error
                    time.sleep(0.02)
                engine.lib.llcs_engine_cancel(engine.ptr, task)
                if index in [49, 99]:
                    deadline = time.monotonic() + 15
                    while True:
                        stats = engine.read(engine.lib.llcs_engine_stats(engine.ptr))
                        if not stats["pending_cancellations"]:
                            break
                        assert time.monotonic() < deadline, stats
                        time.sleep(0.02)
                    if index == 49:
                        after_warmup = process_resources()
            stats = engine.read(engine.lib.llcs_engine_stats(engine.ptr))
            assert stats["active_tasks"] == 0, stats
            assert stats["retained_tasks"] == 0, stats
            assert stats["collector_threads"] == 1, stats
            after_repeat = process_resources()
            if after_warmup and after_repeat:
                assert after_repeat[0] <= after_warmup[0] + 2, (after_warmup, after_repeat)
                assert after_repeat[1] <= after_warmup[1] + 32 * 1024, (after_warmup, after_repeat)
            engine.complete(body)
            print(json.dumps({"case": "cancel", "warmup_50": after_warmup, "repeat_100": after_repeat,
                              "active_tasks": stats["active_tasks"], "retained_tasks": stats["retained_tasks"],
                              "pending_cancellations": stats["pending_cancellations"],
                              "collector_threads": stats["collector_threads"]}))
    finally:
        engine.close()


class NativeTests(unittest.TestCase):
    def test_subprocesses(self):
        names = ["invalid_config", "missing_model", "shared_abi", "wrapper_errors"]
        if MODEL:
            names += ["native_ceiling", "invalid_request", "budget_boundary", "queued_cancel",
                      "prefill_state", "terminal_cancel", "expiry", "stream", "nonstream", "cancel", "two_engines"]
        for name in names:
            with self.subTest(name=name):
                proc = subprocess.run([sys.executable, __file__, LIBRARY, MODEL or "", "--case", name],
                                      capture_output=True, text=True, timeout=120)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                print(proc.stdout, end="")


if __name__ == "__main__":
    if "--case" in sys.argv:
        case(sys.argv[-1])
        print(json.dumps({"case": sys.argv[-1], "status": "passed"}))
    else:
        unittest.main(argv=[sys.argv[0]])

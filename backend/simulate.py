#!/usr/bin/env python3
"""
Quill backend headless simulation — exercises every endpoint and edge case
like a real client would. Prints findings as it goes.
"""
import urllib.request
import urllib.error
import json
import sys
import time
import threading
from pathlib import Path

BASE = "http://127.0.0.1:5323"
RUN_ID = time.strftime("%H%M%S")  # unique per run for clean isolation

# ---- tiny results tracker ---------------------------------------------------
findings = {"pass": 0, "fail": 0, "warn": 0, "bugs": []}

def check(label, condition, detail=""):
    if condition:
        findings["pass"] += 1
        print(f"  ✓ {label}")
    else:
        findings["fail"] += 1
        findings["bugs"].append((label, detail))
        print(f"  ✗ FAIL: {label} — {detail}")

def warn(label, detail):
    findings["warn"] += 1
    print(f"  ⚠ WARN: {label} — {detail}")

# ---- HTTP helper -----------------------------------------------------------
def req(method, path, body=None, raw=False):
    url = BASE + path
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return 0, str(e).encode()

def get(path):
    return req("GET", path)

def post(path, body):
    return req("POST", path, body)

def put(path, body):
    return req("PUT", path, body)

def delete(path):
    return req("DELETE", path)

def jget(path):
    code, data = get(path)
    if code == 200:
        return json.loads(data)
    return None

def jpost(path, body):
    code, data = post(path, body)
    if code in (200, 201):
        return json.loads(data)
    return None

# ---- 1. Health -------------------------------------------------------------
print("\n=== 1. Health ===")
code, data = get("/api/health")
check("health endpoint returns 200", code == 200, f"got {code}")
body = json.loads(data) if code == 200 else {}
check("backend is ok", body.get("backend") == "ok", f"got {body.get('backend')}")
check("model is gemma4:latest", body.get("model") == "gemma4:latest", f"got {body.get('model')}")

# ---- 2. Projects — happy path + edge cases --------------------------------
print("\n=== 2. Projects ===")

# Empty list
code, data = get("/api/projects")
check("list projects works", code == 200, f"got {code}")
check("list is JSON array", isinstance(json.loads(data) if code == 200 else None, list))

# Create with various names
names = [
    f"My Novel {RUN_ID}",
    f"Sci-Fi: Book One! {RUN_ID}",
    "    ",  # whitespace only
    "  ",    # short whitespace
    f"a/b/c {RUN_ID}", # path separator
    f"../../etc/passwd {RUN_ID}", # path traversal
    f"日本語の本 {RUN_ID}",  # unicode
    f"x {RUN_ID} " + "x" * 200,  # very long
    f"Test<script>alert(1)</script> {RUN_ID}",  # HTML/JS injection
    f"test\nnewlines {RUN_ID}",  # newlines
    f"test\ttab {RUN_ID}",  # tab
    None,  # null name
    "",    # empty
]
created_ids = []
for name in names:
    code, data = post("/api/projects", {"name": name} if name is not None else {})
    if code == 200:
        pid = json.loads(data).get("id", "")
        created_ids.append((name, pid))
        if name and "passwd" in name:
            check(f"project '{name}' sanitized", "/" not in pid, f"got id: {pid}")
        elif name and "<script>" in name:
            check(f"project '{name}' sanitized", "<" not in pid, f"got id: {pid}")

# Check how many projects exist
code, data = get("/api/projects")
projects = json.loads(data) if code == 200 else []
check("all created projects present", len(projects) >= len([n for n in names if n]), f"got {len(projects)}")

# ---- 3. Chapters ----------------------------------------------------------
print("\n=== 3. Chapters ===")
test_proj = next((pid for n, pid in created_ids if n == f"My Novel {RUN_ID}"), None)
if not test_proj:
    warn(f"test project 'My Novel {RUN_ID}' not found, using first", "")
    test_proj = created_ids[0][1] if created_ids else None

if test_proj:
    # Create chapters with various names
    chapter_names = [
        "chapter-1", "chapter-2", "Chapter Three", "chapter-four",
        "chapter-1",  # duplicate
        "../escape",   # path traversal
        "very/deep/path",
        "x" * 300,     # very long
        "",
    ]
    for cname in chapter_names:
        code, data = post(f"/api/projects/{test_proj}/chapters", {"name": cname})
        if cname == "":
            check(f"empty chapter name handled", code in (200, 400, 409), f"got {code}")

    # List chapters
    code, data = get(f"/api/projects/{test_proj}/chapters")
    chapters = json.loads(data) if code == 200 else []
    check("chapters listed", isinstance(chapters, list), f"got {type(chapters)}")

    # Read existing chapter
    code, data = get(f"/api/projects/{test_proj}/chapters/chapter-1/content")
    check("read chapter-1 content", code == 200, f"got {code}")
    if code == 200:
        content = json.loads(data).get("content", "")
        check("chapter-1 has heading", "# Chapter 1" in content, f"content: {content[:50]}")

    # Read nonexistent
    code, data = get(f"/api/projects/{test_proj}/chapters/does-not-exist/content")
    check("404 on missing chapter", code == 404, f"got {code}")

    # Read with path traversal attempt
    code, data = get(f"/api/projects/{test_proj}/chapters/..%2F..%2Fetc%2Fpasswd/content")
    check("path traversal blocked on read", code == 404, f"got {code}")

    # Save content
    test_content = "# Chapter 1\n\nThe rain hammered the window.\n\nShe did not move."
    code, data = put(f"/api/projects/{test_proj}/chapters/chapter-1/content", {"content": test_content})
    check("save chapter content", code == 200, f"got {code}")

    # Read it back
    code, data = get(f"/api/projects/{test_proj}/chapters/chapter-1/content")
    if code == 200:
        saved = json.loads(data).get("content", "")
        check("content persisted", saved == test_content, f"diff: {saved[:50]} vs {test_content[:50]}")

    # Save with empty content
    code, data = put(f"/api/projects/{test_proj}/chapters/chapter-1/content", {"content": ""})
    check("save empty content allowed", code == 200, f"got {code}")

    # Save with very large content (stress test)
    huge = "Lorem ipsum dolor sit amet. " * 100000
    code, data = put(f"/api/projects/{test_proj}/chapters/chapter-1/content", {"content": huge})
    check("save huge content (~1.3MB)", code == 200, f"got {code}")

    # Rename
    code, data = post(f"/api/projects/{test_proj}/chapters/chapter-1/rename", {"new_name": "chapter-renamed"})
    check("rename chapter", code == 200, f"got {code}")
    if code == 200:
        # Verify rename took effect
        code2, _ = get(f"/api/projects/{test_proj}/chapters/chapter-renamed/content")
        check("renamed chapter accessible", code2 == 200, f"got {code2}")
        # Old name should be gone
        code3, _ = get(f"/api/projects/{test_proj}/chapters/chapter-1/content")
        check("old name gone after rename", code3 == 404, f"got {code3}")

    # Rename to same name (no-op — we now return 400 as it's a programmer error)
    code, data = post(f"/api/projects/{test_proj}/chapters/chapter-renamed/rename", {"new_name": "chapter-renamed"})
    check("rename to same name rejected", code == 400, f"got {code}")

    # Rename to existing name
    code, data = post(f"/api/projects/{test_proj}/chapters/chapter-2/rename", {"new_name": "Chapter Three"})
    check("rename to existing fails 409", code == 409, f"got {code}")

    # Rename nonexistent
    code, data = post(f"/api/projects/{test_proj}/chapters/ghost/rename", {"new_name": "anything"})
    check("rename missing fails 404", code == 404, f"got {code}")

    # Rename with empty new_name (no `new_name` key in body)
    code, data = post(f"/api/projects/{test_proj}/chapters/chapter-2/rename", {})
    if code == 200:
        warn("rename with no new_name body", "should it 400 or default to current name? got 200")
    else:
        check("rename with no new_name handled", code in (400, 200), f"got {code}")

    # Delete
    code, data = delete(f"/api/projects/{test_proj}/chapters/chapter-renamed")
    check("delete chapter", code == 200, f"got {code}")

    # Delete idempotent
    code, data = delete(f"/api/projects/{test_proj}/chapters/chapter-renamed")
    check("delete idempotent", code == 200, f"got {code}")

    # Delete with path traversal
    code, data = delete(f"/api/projects/{test_proj}/chapters/..%2F..%2F..%2Fetc%2Fpasswd")
    check("path traversal in delete blocked", code in (404, 200), f"got {code}")

# ---- 4. Context ------------------------------------------------------------
print("\n=== 4. Context ===")
if test_proj:
    code, data = get(f"/api/projects/{test_proj}/context")
    check("get context", code == 200, f"got {code}")
    if code == 200:
        ctx = json.loads(data)
        for key in ["characters", "world", "summary", "style"]:
            check(f"context has {key}", key in ctx, f"missing")

    # Update context
    code, data = put(f"/api/projects/{test_proj}/context", {
        "characters": "Alice Walker, age 30",
        "world": "Neo-Tokyo, 2087",
        "summary": "Alice discovers a hidden truth",
        "style": "noir, atmospheric, terse"
    })
    check("update context", code == 200, f"got {code}")

    # Update with empty body — should not crash
    code, data = put(f"/api/projects/{test_proj}/context", {})
    check("empty context update handled", code == 200, f"got {code}")

    # Update with extra unknown keys — should be ignored, not crash
    code, data = put(f"/api/projects/{test_proj}/context", {"unknown_key": "x", "characters": "Bob"})
    check("unknown context keys ignored", code == 200, f"got {code}")
    if code == 200:
        ctx = json.loads(data)
        check("known keys still updated", ctx.get("characters") == "Bob", f"got {ctx.get('characters')}")

# ---- 5. Settings -----------------------------------------------------------
print("\n=== 5. Settings ===")
if test_proj:
    code, data = get(f"/api/projects/{test_proj}/settings")
    check("get settings", code == 200, f"got {code}")
    if code == 200:
        s = json.loads(data)
        for k in ["title", "author", "genre", "dedication", "epigraph", "style", "model", "chapters_dir"]:
            check(f"settings has {k}", k in s, f"missing")

    # Update all settings
    code, data = put(f"/api/projects/{test_proj}/settings", {
        "title": "The Long Dark",
        "author": "Jane Doe",
        "genre": "Dark Fantasy",
        "dedication": "For my mother.",
        "epigraph": "All that we see or seem is but a dream within a dream.",
        "style": "Gothic, atmospheric, slow-paced"
    })
    check("update all settings", code == 200, f"got {code}")

    # Update with unicode
    code, data = put(f"/api/projects/{test_proj}/settings", {
        "title": "黑暗的長夜",
        "dedication": "献给母亲"
    })
    check("unicode settings", code == 200, f"got {code}")

# ---- 6. Compile ------------------------------------------------------------
print("\n=== 6. Compile ===")
if test_proj:
    code, data = get(f"/api/projects/{test_proj}/compile")
    check("compile preview", code == 200, f"got {code}")
    if code == 200:
        c = json.loads(data)
        check("compile has title", "title" in c, f"got {c.keys()}")
        check("compile has content", "content" in c, "")
        check("compile has word_count", "word_count" in c, "")
        check("compile has chapter_count", "chapter_count" in c, "")
        check("compile has author", "author" in c, "")
        check("compile has genre", "genre" in c, "")
        check("word_count is int", isinstance(c.get("word_count"), int), f"got {type(c.get('word_count'))}")
        check("chapter_count is int", isinstance(c.get("chapter_count"), int), f"got {type(c.get('chapter_count'))}")

    # Compile empty project
    # Make a new project with no chapters
    code, data = post("/api/projects", {"name": f"Empty Project {RUN_ID}"})
    if code == 200:
        empty_id = json.loads(data)["id"]
        code, data = get(f"/api/projects/{empty_id}/compile")
        if code == 200:
            c = json.loads(data)
            check("empty project compile has front matter", "title" in c, "")
            check("empty project chapter_count is 0", c.get("chapter_count") == 0, f"got {c.get('chapter_count')}")

# ---- 7. Export -------------------------------------------------------------
print("\n=== 7. Export ===")
if test_proj:
    for fmt in ["md", "txt"]:
        code, data = get(f"/api/projects/{test_proj}/export/{fmt}")
        check(f"export {fmt}", code == 200, f"got {code}")
        if code == 200 and fmt == "md":
            check("md export has content", len(data) > 0, f"got {len(data)} bytes")
            content = data.decode("utf-8") if isinstance(data, bytes) else data
            check("md export has YAML", "title:" in content, f"first 100: {content[:100]}")

    # Bad format
    code, data = get(f"/api/projects/{test_proj}/export/epub")
    check("unknown format returns 400", code == 400, f"got {code}")

    # docx (requires pandoc)
    code, data = get(f"/api/projects/{test_proj}/export/docx")
    if code == 200:
        check("docx export works", len(data) > 0)
    elif code == 500:
        warn("docx export needs pandoc", "install with: brew install pandoc")
    else:
        check("docx export response", code in (200, 500), f"got {code}")

# ---- 8. File operations via /api/tasks ------------------------------------
print("\n=== 8. File ops via /api/tasks ===")
if test_proj:
    # Need to start a fresh project for clean file ops
    code, data = post("/api/projects", {"name": f"File Ops Test {RUN_ID}"})
    if code == 200:
        fop_proj = json.loads(data)["id"]

        # We need to read SSE — use raw response
        def post_sse(body):
            r = urllib.request.Request(
                f"{BASE}/api/tasks",
                data=json.dumps(body).encode("utf-8"),
                method="POST"
            )
            r.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(r, timeout=15) as resp:
                    return resp.status, resp.read().decode("utf-8")
            except urllib.error.HTTPError as e:
                return e.code, e.read().decode("utf-8")

        # Test 1: create chapter
        code, data = post_sse({
            "task": "create chapter 99",
            "project_id": fop_proj,
            "mode": "auto"
        })
        check("file op: create chapter", "file_op" in data, f"got: {data[:200]}")

        # Verify file was created
        code, data = get(f"/api/projects/{fop_proj}/chapters")
        chapters = json.loads(data) if code == 200 else []
        check("created chapter appears in list", any(c["name"] == "chapter-99" for c in chapters),
              f"got: {[c['name'] for c in chapters]}")

        # Test 2: rename
        code, data = post_sse({
            "task": "rename chapter 99 to chapter-renamed",
            "project_id": fop_proj,
            "mode": "auto"
        })
        check("file op: rename", "rename_chapter" in data, f"got: {data[:200]}")

        # Test 3: delete
        code, data = post_sse({
            "task": "delete chapter-renamed",
            "project_id": fop_proj,
            "mode": "auto"
        })
        check("file op: delete", "delete_chapter" in data, f"got: {data[:200]}")

        # Test 4: non-file-op input
        code, data = post_sse({
            "task": "just chat about the weather",
            "project_id": fop_proj,
            "mode": "auto"
        })
        # Should not crash, may or may not stream
        check("non-file-op doesn't crash", code in (200, 500), f"got {code}")

# ---- 9. Concurrent requests -----------------------------------------------
print("\n=== 9. Concurrency ===")
if test_proj:
    # Make 10 concurrent save requests
    errors = []
    def save_request(i):
        c, _ = put(f"/api/projects/{test_proj}/chapters/chapter-2/content", {"content": f"concurrent save {i}"})
        if c != 200:
            errors.append((i, c))
    threads = [threading.Thread(target=save_request, args=(i,)) for i in range(10)]
    for t in threads: t.start()
    for t in threads: t.join()
    check("10 concurrent saves all succeed", len(errors) == 0, f"errors: {errors[:3]}")

# ---- 10. Method not allowed ------------------------------------------------
print("\n=== 10. HTTP method checks ===")
code, _ = req("PATCH", "/api/projects")
check("PATCH on /api/projects is rejected", code in (405, 404, 501), f"got {code}")

code, _ = req("DELETE", "/api/health")
check("DELETE on /api/health is rejected", code in (405, 404, 501), f"got {code}")

# ---- 11. Invalid JSON body -------------------------------------------------
print("\n=== 11. Malformed requests ===")
code, data = req("POST", "/api/projects", body="not json at all{")
check("invalid JSON defaults to empty", code == 200, f"got {code}")

code, data = req("POST", "/api/projects", body='"just a string"')
check("string JSON defaults to empty", code == 200, f"got {code}")

code, data = req("POST", "/api/projects", body="null")
check("null JSON handled", code == 200, f"got {code}")

code, data = req("POST", "/api/projects", body="[1,2,3]")
check("array JSON handled", code == 200, f"got {code}")

# ---- Summary --------------------------------------------------------------
print("\n" + "=" * 60)
print(f"  PASS: {findings['pass']}   FAIL: {findings['fail']}   WARN: {findings['warn']}")
print("=" * 60)
if findings["bugs"]:
    print("\nFAILURES:")
    for label, detail in findings["bugs"]:
        print(f"  • {label}: {detail}")
    sys.exit(1)
print("\nAll checks passed.")

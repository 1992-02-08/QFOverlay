#!/usr/bin/env python3
import os, sys, json, urllib.request, urllib.error

TOKEN = os.environ.get("GH", "")
if not TOKEN:
    print("NO_TOKEN"); sys.exit(2)

proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy") or ""
handlers = []
if proxy:
    handlers.append(urllib.request.ProxyHandler({"https": proxy, "http": proxy}))
opener = urllib.request.build_opener(*handlers)

url = "https://api.github.com/user/repos"
data = json.dumps({
    "name": "QFOverlay",
    "private": False,
    "description": "iOS 常驻浮窗模块：全局拖动 + 常驻显示（移植自 QFSpeed 2.1.6）",
    "auto_init": False,
    "has_issues": True,
    "has_wiki": False,
}).encode("utf-8")

req = urllib.request.Request(url, data=data, method="POST")
req.add_header("Authorization", "Bearer " + TOKEN)
req.add_header("Accept", "application/vnd.github+json")
req.add_header("Content-Type", "application/json")
req.add_header("User-Agent", "QFOverlay-Build/1.0")

try:
    with opener.open(req, timeout=25) as r:
        body = r.read().decode("utf-8", "replace")
        print("HTTP_STATUS=%d" % r.status)
        try:
            j = json.loads(body)
            print("HTML_URL=%s" % j.get("html_url", ""))
            print("CLONE_URL=%s" % j.get("clone_url", ""))
            print("SSH_URL=%s" % j.get("ssh_url", ""))
            print("FULL_NAME=%s" % j.get("full_name", ""))
        except Exception as e:
            print("PARSE_ERR=%s" % e)
            print(body[:500])
except urllib.error.HTTPError as e:
    print("HTTP_STATUS=%d" % e.code)
    print(e.read().decode("utf-8", "replace")[:800])
except Exception as e:
    print("ERR=%s" % e)

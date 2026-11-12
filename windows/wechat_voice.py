# -*- coding: utf-8 -*-
"""
微信语音播报 · Windows 版

原理：只读取 Windows 自己的通知数据库
  %LOCALAPPDATA%\\Microsoft\\Windows\\Notifications\\wpndatabase.db
微信弹出系统通知时会记录在这里，本程序发现新的微信通知后用系统语音朗读。
不碰微信本身（不注入、不 hook、不读聊天记录），没有封号风险。

运行：  python wechat_voice.py            托盘程序
调试：  python wechat_voice.py --dump 40  打印最近的系统通知
        python wechat_voice.py --selftest 测试播报句子
        python wechat_voice.py --say 你好  试音
"""
import json
import os
import queue
import re
import sqlite3
import sys
import threading
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta

APP_NAME = "微信语音播报"
APP_DIR = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "WeChatVoice")
CONFIG_PATH = os.path.join(APP_DIR, "config.json")
LOG_PATH = os.path.join(APP_DIR, "log.txt")
DB_PATH = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Microsoft", "Windows", "Notifications", "wpndatabase.db")

os.makedirs(APP_DIR, exist_ok=True)


def log(s):
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} {s}\n")
    except Exception:
        pass


# ---------------------------------------------------------------- 设置

DEFAULTS = {
    "enabled": True,
    "readContent": True,
    "readGroups": True,
    "maxChars": 40,
    "voice": "",            # 留空自动选中文声音；可填 Huihui / Yaoyao / Kangkang / Xiaoxiao 等名字里的一段
    "rate": 1,              # -10 ~ 10，0 是正常语速
    "volume": 100,
    "chime": True,
    "mergeSeconds": 2.5,
    "pollSeconds": 1.0,
    "quietStart": "",
    "quietEnd": "",
    "vip": [],
    "vipOnly": False,
    "ignore": [],
    "vipPrefix": "重要联系人",
    "appMatch": ["wechat", "weixin", "tencent.wechat", "微信"],
}
HELP = [
    "改完保存即可生效，不用重启。true=开 false=关。",
    "vip / ignore 写名字，例如 [\"王总\", \"客户群\"]，名字里包含这些字就算。",
    "voice 留空自动选中文声音；rate 是语速 -10~10。",
    "quietStart / quietEnd 例如 \"22:30\" 和 \"08:00\"，免打扰期间只有 vip 和电话会播报。",
]


class Config:
    def __init__(self):
        self.d = dict(DEFAULTS)
        self.mtime = None
        self.load()

    def load(self):
        self.d = dict(DEFAULTS)
        try:
            with open(CONFIG_PATH, encoding="utf-8") as f:
                j = json.load(f)
            for k, v in j.items():
                if not k.startswith("_"):
                    self.d[k] = v
        except FileNotFoundError:
            self.save()
        except Exception as e:
            log(f"设置文件格式有误，使用默认值：{e}")
        try:
            self.mtime = os.path.getmtime(CONFIG_PATH)
        except OSError:
            self.mtime = None

    def reload_if_changed(self):
        try:
            m = os.path.getmtime(CONFIG_PATH)
        except OSError:
            m = None
        if m != self.mtime:
            self.load()
            log("设置已重新加载")

    def save(self):
        out = dict(self.d)
        out["_说明"] = HELP
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=2, sort_keys=True)
        self.mtime = os.path.getmtime(CONFIG_PATH)

    def __getitem__(self, k):
        return self.d.get(k, DEFAULTS.get(k))

    def set(self, k, v):
        self.d[k] = v
        self.save()

    def names(self, k):
        return [x for x in (self.d.get(k) or []) if isinstance(x, str) and x]


# ---------------------------------------------------------------- 通知数据库

class NotifDB:
    def __init__(self, path=DB_PATH):
        self.path = path
        self.conn = None

    def open(self):
        self.close()
        if not os.path.exists(self.path):
            return "找不到系统通知数据库"
        try:
            uri = "file:" + self.path.replace("\\", "/") + "?mode=ro"
            self.conn = sqlite3.connect(uri, uri=True, timeout=3, check_same_thread=False)
            self.max_id()
            log(f"已打开通知数据库：{self.path}")
            return None
        except Exception as e:
            self.close()
            return f"打不开通知数据库：{e}"

    def close(self):
        if self.conn:
            try:
                self.conn.close()
            except Exception:
                pass
        self.conn = None

    def max_id(self):
        return self.conn.execute("SELECT IFNULL(MAX(Id),0) FROM Notification").fetchone()[0]

    def fetch(self, after, limit=300):
        sql = ("SELECT n.Id, IFNULL(h.PrimaryId,''), n.Payload, n.Type FROM Notification n "
               "LEFT JOIN NotificationHandler h ON h.RecordId = n.HandlerId "
               "WHERE n.Id > ? ORDER BY n.Id LIMIT ?")
        return self.conn.execute(sql, (after, limit)).fetchall()

    def recent(self, n):
        m = self.max_id()
        rows = self.fetch(max(0, m - n * 20), 100000)
        return rows[-n:]


def is_wechat(app_id, cfg):
    a = (app_id or "").lower()
    return any(k.lower() in a for k in cfg["appMatch"])


def parse_payload(payload):
    """toast XML → (标题, 副标题, 正文)"""
    if payload is None:
        return None
    if isinstance(payload, bytes):
        for enc in ("utf-8", "utf-16"):
            try:
                payload = payload.decode(enc)
                break
            except UnicodeDecodeError:
                continue
        else:
            return None
    try:
        root = ET.fromstring(payload.strip().lstrip("﻿"))
    except ET.ParseError:
        texts = re.findall(r"<text[^>]*>(.*?)</text>", payload, re.S)
    else:
        texts = [(t.text or "") for t in root.iter("text")]
    texts = [t.strip() for t in texts if t and t.strip()]
    if not texts:
        return None
    title = texts[0]
    body = "\n".join(texts[1:]) if len(texts) > 1 else ""
    return title, "", body


# ---------------------------------------------------------------- 文本 & 分类（与 Mac 版一致）

PLACEHOLDERS = [
    ("[图片]", "一张图片"), ("[语音]", "一条语音"), ("[视频]", "一段视频"), ("[文件]", "一个文件"),
    ("[链接]", "一个链接"), ("[动画表情]", "一个表情"), ("[表情]", "一个表情"), ("[位置]", "一个位置"),
    ("[微信红包]", "一个红包"), ("[红包]", "一个红包"), ("[转账]", "一笔转账"), ("[名片]", "一张名片"),
    ("[小程序]", "一个小程序"), ("[聊天记录]", "一段聊天记录"), ("[音乐]", "一首音乐"), ("[视频号]", "一个视频号"),
    ("[Photo]", "一张图片"), ("[Image]", "一张图片"), ("[Voice]", "一条语音"), ("[Video]", "一段视频"),
    ("[File]", "一个文件"), ("[Link]", "一个链接"), ("[Sticker]", "一个表情"), ("[Location]", "一个位置"),
]
EMOJI_RE = re.compile("[\U0001F000-\U0001FAFF☀-➿️]")


def clean_for_speech(s):
    t = (s or "").strip()
    is_media = re.fullmatch(r"\[[^\[\]]{1,8}\]", t) is not None
    for k, v in PLACEHOLDERS:
        t = t.replace(k, v)
    t = re.sub(r"https?://\S+", "一个链接", t)
    t = re.sub(r"\[[^\[\]]{1,6}\]", "", t)
    t = EMOJI_RE.sub("", t)
    t = re.sub(r"\s*\n+\s*", "，", t)
    t = re.sub(r"\s{2,}", " ", t).strip()
    if not t and s:
        return "一个表情", True
    return t, is_media


def truncate(s, n):
    return s if n <= 0 or len(s) <= n else s[:n] + "，等等"


FRIEND_KEYS = ["请求添加你为朋友", "请求添加你为好友", "添加你为朋友", "加你为朋友", "好友申请", "新的朋友", "朋友验证", "朋友推荐",
               "wants to add you", "friend request"]
CALL_KEYS = ["邀请你进行视频通话", "邀请你进行语音通话", "邀请你视频通话", "邀请你语音通话", "视频通话邀请", "语音通话邀请",
             "invites you to a video call", "invites you to a voice call", "video call", "voice call"]
APP_NAMES = {"微信", "WeChat", "Weixin", ""}


class Event:
    def __init__(self, kind, chat, sender, content):
        self.kind, self.chat, self.sender, self.content = kind, chat, sender, content
        self.vip = False
        self.call_type = "语音"


def classify(title, sub, body):
    title, sub = (title or "").strip(), (sub or "").strip()
    body = re.sub(r"^\s*\[\d+条\]\s*", "", (body or "").strip())
    allt = f"{title} {sub} {body}"
    low = allt.lower()
    if any(k.lower() in low for k in FRIEND_KEYS):
        name = ""
        m = re.match(r"^(.{1,30}?)\s*(请求添加|想添加|申请添加|wants to add)", body)
        if m:
            name = m.group(1)
        if not name and title not in APP_NAMES and not any(k in title for k in FRIEND_KEYS):
            name = title
        return Event("friend", name, None, body)
    if any(k.lower() in low for k in CALL_KEYS) and len(body) < 40:
        e = Event("call", "" if title in APP_NAMES else title, None, body)
        e.call_type = "视频" if ("视频" in allt or "video" in low) else "语音"
        return e
    if title in APP_NAMES and (not body or ("收到" in body and "消息" in body and len(body) < 20)):
        return Event("generic", "", None, body)
    if sub and sub != title:
        return Event("message", title, sub, body)
    m = re.match(r"^([^:：\n]{1,24})[:：]\s*(.*)$", body, re.S)
    if m:
        who = m.group(1).strip()
        if who == title:
            return Event("message", title, None, m.group(2))
        if len(who) <= 12:
            return Event("message", title, who, m.group(2))
    return Event("message", title, None, body)


def build_phrases(events, cfg):
    read_content, read_groups = cfg["readContent"], cfg["readGroups"]
    max_chars, vp = int(cfg["maxChars"]), cfg["vipPrefix"] or ""
    pre = lambda yes: (vp + "，") if (yes and vp) else ""
    out = []
    for e in events:
        if e.kind == "call":
            out.append(pre(e.vip) + (e.chat or "有人") + f"给你打微信{e.call_type}电话")
    for e in events:
        if e.kind == "friend":
            out.append(f"{e.chat}申请加你为微信好友" if e.chat else "有新的微信好友申请")
    if any(e.kind == "generic" for e in events) and not any(e.kind == "message" for e in events):
        out.append("微信有新消息")

    order, by = [], {}
    for e in events:
        if e.kind != "message":
            continue
        if e.chat not in by:
            order.append(e.chat)
            by[e.chat] = []
        by[e.chat].append(e)
    order.sort(key=lambda c: 0 if any(x.vip for x in by[c]) else 1)
    detailed, summarized = (order[:3], order[3:]) if len(order) > 4 else (order, [])

    for chat in detailed:
        lst = by[chat]
        last, k = lst[-1], len(lst)
        is_group = any(x.sender for x in lst)
        name = chat or "有人"
        gname = name if name.endswith("群") else name + "群"
        text, media = clean_for_speech(last.content)
        content = truncate(text, max_chars)
        p = pre(any(x.vip for x in lst))
        if is_group:
            who = last.sender or "有人"
            if not read_content or not read_groups or not content:
                out.append(p + (f"{gname}里有{k}条新消息" if k > 1 else f"{gname}里有新消息"))
            else:
                head = f"{gname}里有{k}条新消息，最新是{who}" if k > 1 else f"{gname}里，{who}"
                out.append(p + head + (f"发了{content}" if media else f"说：{content}"))
        else:
            if not read_content or not content:
                out.append(p + (f"{name}发来{k}条微信" if k > 1 else f"{name}发来微信"))
            elif k > 1:
                out.append(p + f"{name}发来{k}条消息，最新一条" + (f"是{content}" if media else f"：{content}"))
            else:
                out.append(p + name + (f"发来{content}" if media else f"说：{content}"))
    if summarized:
        n = sum(len(by[c]) for c in summarized)
        names = "、".join((c or "未知") for c in summarized[:3])
        out.append(f"另外还有{n}条消息，来自{names}" + (f"等{len(summarized)}个聊天" if len(summarized) > 3 else ""))
    return out


# ---------------------------------------------------------------- 朗读

class Speaker:
    """单独线程里用 Windows 自带的 SAPI 语音朗读"""

    def __init__(self, cfg):
        self.cfg = cfg
        self.q = queue.Queue()
        self.stop_flag = threading.Event()
        threading.Thread(target=self._run, daemon=True).start()

    def speak(self, lines, chime=False):
        self.q.put((list(lines), chime))

    def stop(self):
        self.stop_flag.set()
        while not self.q.empty():
            try:
                self.q.get_nowait()
            except queue.Empty:
                break

    def voices(self):
        try:
            import win32com.client
            v = win32com.client.Dispatch("SAPI.SpVoice")
            return [v.GetVoices().Item(i).GetDescription() for i in range(v.GetVoices().Count)]
        except Exception:
            return []

    def _pick_voice(self, sp):
        want = (self.cfg["voice"] or "").lower()
        vs = sp.GetVoices()
        best = None
        for i in range(vs.Count):
            tok = vs.Item(i)
            desc = tok.GetDescription()
            lang = ""
            try:
                lang = tok.GetAttribute("Language") or ""
            except Exception:
                pass
            if want and want in desc.lower():
                return tok
            # 804 = 简体中文，404 = 繁体中文
            if best is None and ("804" in lang or "Chinese" in desc or "中文" in desc or "Huihui" in desc):
                best = tok
        return best

    def _run(self):
        try:
            import pythoncom
            import win32com.client
            pythoncom.CoInitialize()
            sp = win32com.client.Dispatch("SAPI.SpVoice")
            v = self._pick_voice(sp)
            if v is not None:
                sp.Voice = v
        except Exception as e:
            log(f"语音初始化失败：{e}")
            sp = None
        last_voice = self.cfg["voice"]
        while True:
            lines, chime = self.q.get()
            self.stop_flag.clear()
            if sp is None:
                continue
            try:
                if self.cfg["voice"] != last_voice:
                    last_voice = self.cfg["voice"]
                    v = self._pick_voice(sp)
                    if v is not None:
                        sp.Voice = v
                sp.Rate = int(self.cfg["rate"])
                sp.Volume = int(self.cfg["volume"])
                if chime:
                    try:
                        import winsound
                        winsound.PlaySound("SystemNotification", winsound.SND_ALIAS)
                    except Exception:
                        pass
                for line in lines:
                    if self.stop_flag.is_set():
                        break
                    sp.Speak(line, 1)  # 1 = 异步
                    while not sp.WaitUntilDone(100):
                        if self.stop_flag.is_set():
                            sp.Speak("", 2)  # 2 = 打断
                            break
            except Exception as e:
                log(f"朗读失败：{e}")


# ---------------------------------------------------------------- 监听

def hm(s):
    try:
        h, m = s.split(":")
        return int(h) * 60 + int(m)
    except Exception:
        return None


class Watcher:
    def __init__(self, cfg, speaker):
        self.cfg, self.speaker = cfg, speaker
        self.db = NotifDB()
        self.last_id = 0
        self.error = "正在启动…"
        self.pending, self.first_at, self.last_at = [], 0, 0
        self.paused_until = None
        self.recent = []
        self.today, self.today_count = "", 0
        self.on_change = lambda: None
        self._reopen_at = 0

    def try_open(self):
        err = self.db.open()
        if err:
            self.error = err
        else:
            self.error = None
            m = self.db.max_id()
            if self.last_id == 0 or self.last_id > m:
                self.last_id = m
        self.on_change()

    def in_quiet(self):
        s, e = hm(self.cfg["quietStart"] or ""), hm(self.cfg["quietEnd"] or "")
        if s is None or e is None or s == e:
            return False
        now = datetime.now().hour * 60 + datetime.now().minute
        return (s <= now < e) if s < e else (now >= s or now < e)

    def paused(self):
        return self.paused_until is not None and self.paused_until > datetime.now()

    def muted(self):
        return (not self.cfg["enabled"]) or self.paused() or self.in_quiet()

    def tick(self):
        self.cfg.reload_if_changed()
        if self.error:
            if time.time() > self._reopen_at:
                self._reopen_at = time.time() + 5
                self.try_open()
            return
        try:
            rows = self.db.fetch(self.last_id)
        except Exception as e:
            log(f"读取失败，准备重连：{e}")
            self.error = "读取通知数据库失败"
            self.db.close()
            self.on_change()
            return
        for rid, app, payload, typ in rows:
            self.last_id = max(self.last_id, rid)
            if not is_wechat(app, self.cfg):
                continue
            p = parse_payload(payload)
            if not p:
                continue
            e = classify(*p)
            names = [x for x in (e.chat, e.sender or "") if x]
            e.vip = any(v in n for v in self.cfg.names("vip") for n in names)
            ignored = any(v in n for v in self.cfg.names("ignore") for n in names)
            log(f"微信通知 #{rid} 类型={e.kind} 聊天={e.chat}{' (已忽略)' if ignored else ''}")
            if e.kind == "message" and ignored and not e.vip:
                continue
            if self.cfg["vipOnly"] and not e.vip and e.kind != "friend":
                continue
            if not self.pending:
                self.first_at = time.time()
            self.pending.append(e)
            self.last_at = time.time()
        if self.pending and (time.time() - self.last_at >= float(self.cfg["mergeSeconds"]) or time.time() - self.first_at >= 8):
            self.flush()

    def flush(self):
        evs, self.pending = self.pending, []
        if not self.cfg["enabled"] or self.paused():
            return
        if self.in_quiet():
            evs = [e for e in evs if e.vip or e.kind == "call"]
        lines = build_phrases(evs, self.cfg)
        if lines:
            self.say(lines)

    def say(self, lines):
        d = datetime.now().strftime("%Y-%m-%d")
        if d != self.today:
            self.today, self.today_count = d, 0
        self.today_count += len(lines)
        for l in lines:
            self.recent.insert(0, (datetime.now(), l))
        del self.recent[15:]
        self.speaker.speak(lines, chime=bool(self.cfg["chime"]))
        self.on_change()

    def loop(self):
        self.try_open()
        while True:
            try:
                self.tick()
            except Exception as e:
                log(f"出错：{e}")
            time.sleep(max(0.3, float(self.cfg["pollSeconds"])))


# ---------------------------------------------------------------- 开机启动

RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"


def startup_cmd():
    if getattr(sys, "frozen", False):
        return f'"{sys.executable}"'
    pyw = sys.executable.replace("python.exe", "pythonw.exe")
    return f'"{pyw}" "{os.path.abspath(__file__)}"'


def autostart_enabled():
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as k:
            winreg.QueryValueEx(k, "WeChatVoice")
            return True
    except Exception:
        return False


def set_autostart(on):
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as k:
        if on:
            winreg.SetValueEx(k, "WeChatVoice", 0, winreg.REG_SZ, startup_cmd())
        else:
            try:
                winreg.DeleteValue(k, "WeChatVoice")
            except FileNotFoundError:
                pass


# ---------------------------------------------------------------- 托盘

def make_icon(state):
    from PIL import Image, ImageDraw
    S = 64
    color = {"ok": (7, 193, 96), "muted": (140, 140, 140), "error": (230, 150, 0)}[state]
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([2, 2, S - 2, S - 2], radius=14, fill=color + (255,))
    d.ellipse([10, 14, 42, 42], fill="white")
    d.polygon([(16, 38), (12, 50), (24, 41)], fill="white")
    for cx in (19, 26, 33):
        d.ellipse([cx - 2, 26, cx + 2, 30], fill=color + (255,))
    for r in (6, 11, 16):
        d.arc([44 - r, 28 - r, 44 + r, 28 + r], -50, 50, fill="white", width=3)
    if state == "muted":
        d.line([8, 56, 56, 8], fill="white", width=5)
    return im


def run_tray():
    import pystray
    from pystray import Menu, MenuItem as Item

    cfg = Config()
    speaker = Speaker(cfg)
    w = Watcher(cfg, speaker)

    def state():
        return "error" if w.error else ("muted" if w.muted() else "ok")

    def status_text(_=None):
        if w.error:
            return "⚠ " + w.error
        if w.paused():
            return f"已暂停，到 {w.paused_until:%H:%M} 自动恢复"
        if w.in_quiet():
            return "免打扰时段中（只报重要联系人）"
        if not cfg["enabled"]:
            return "播报已关闭"
        return f"正在帮你盯着微信 · 今天已播报 {w.today_count} 条"

    def toggle(key):
        def f(icon, item):
            cfg.set(key, not cfg[key])
            refresh()
        return f

    def checked(key):
        return lambda item: bool(cfg[key])

    def pause(minutes):
        def f(icon, item):
            if minutes < 0:
                t = datetime.now().replace(hour=7, minute=0, second=0, microsecond=0) + timedelta(days=1)
            else:
                t = datetime.now() + timedelta(minutes=minutes)
            w.paused_until = t
            speaker.stop()
            refresh()
        return f

    def resume(icon, item):
        w.paused_until = None
        refresh()

    def recent_items():
        if not w.recent:
            yield Item("（还没有）", None, enabled=False)
            return
        for d, t in w.recent:
            yield Item(f"{d:%H:%M}  {t}"[:60], (lambda text: lambda icon, item: speaker.speak([text]))(t))

    def test(icon, item):
        evs = [Event("message", "王总", None, "方案我看了，下午三点前能改好吗？"),
               Event("friend", "李小姐", None, "李小姐请求添加你为朋友")]
        speaker.speak(build_phrases(evs, cfg), chime=bool(cfg["chime"]))

    def open_config(icon, item):
        cfg.save()
        os.startfile(CONFIG_PATH) if hasattr(os, "startfile") else None

    def open_log(icon, item):
        if os.path.exists(LOG_PATH) and hasattr(os, "startfile"):
            os.startfile(LOG_PATH)

    def toggle_autostart(icon, item):
        try:
            set_autostart(not autostart_enabled())
        except Exception as e:
            log(f"开机启动设置失败：{e}")

    def quit_(icon, item):
        icon.stop()
        os._exit(0)

    menu = Menu(
        Item(status_text, None, enabled=False),
        Menu.SEPARATOR,
        Item("开启语音播报", toggle("enabled"), checked=checked("enabled")),
        Item("朗读消息内容", toggle("readContent"), checked=checked("readContent")),
        Item("朗读群消息内容", toggle("readGroups"), checked=checked("readGroups")),
        Item("只报重要联系人", toggle("vipOnly"), checked=checked("vipOnly")),
        Item("播报前提示音", toggle("chime"), checked=checked("chime")),
        Item("暂停一会儿", Menu(
            Item("30 分钟", pause(30)), Item("1 小时", pause(60)), Item("2 小时", pause(120)),
            Item("今天不再播报", pause(-1)), Menu.SEPARATOR, Item("马上恢复", resume),
        )),
        Item("最近播报", Menu(recent_items)),
        Menu.SEPARATOR,
        Item("试听一下", test),
        Item("停止朗读", lambda i, it: speaker.stop()),
        Item("重要联系人 / 屏蔽 / 声音等设置…", open_config),
        Item("开机自动启动", toggle_autostart, checked=lambda item: autostart_enabled()),
        Item("查看运行日志", open_log),
        Menu.SEPARATOR,
        Item("退出微信语音播报", quit_),
    )
    icon = pystray.Icon("WeChatVoice", make_icon("ok"), APP_NAME, menu)

    def refresh():
        try:
            icon.icon = make_icon(state())
            icon.title = APP_NAME + " - " + status_text()
            icon.update_menu()
        except Exception:
            pass

    w.on_change = refresh

    def setup(ic):
        ic.visible = True
        threading.Thread(target=w.loop, daemon=True).start()
        # 每 30 秒刷新一次图标（暂停到期、免打扰时段切换）
        def periodic():
            while True:
                time.sleep(30)
                refresh()
        threading.Thread(target=periodic, daemon=True).start()
        first = os.path.join(APP_DIR, ".welcomed")
        if not os.path.exists(first):
            open(first, "w").close()
            speaker.speak(["微信语音播报已启动"])
        if not autostart_enabled() and not os.path.exists(os.path.join(APP_DIR, ".autostart-asked")):
            open(os.path.join(APP_DIR, ".autostart-asked"), "w").close()
            try:
                set_autostart(True)  # 默认开机启动，可在菜单里关掉
            except Exception:
                pass

    log("启动 Windows v1.0")
    icon.run(setup)


# ---------------------------------------------------------------- 命令行

def cli(argv):
    if len(argv) < 2:
        return False
    cmd = argv[1]
    if cmd == "--dump":
        n = int(argv[2]) if len(argv) > 2 else 30
        db = NotifDB()
        err = db.open()
        out = []
        if err:
            out.append("错误：" + err)
        else:
            cfg = Config()
            out.append(f"数据库：{db.path}")
            for rid, app, payload, typ in db.recent(n):
                p = parse_payload(payload)
                mark = "【微信】" if is_wechat(app, cfg) else ""
                out.append(f"#{rid} {mark}{app} [{typ}] | " + (" | ".join(p) if p else "(无文字)"))
                if mark and p:
                    out.append("   → 会播报：" + " / ".join(build_phrases([classify(*p)], cfg)))
        text = "\n".join(out)
        with open(os.path.join(APP_DIR, "dump.txt"), "w", encoding="utf-8") as f:
            f.write(text + "\n")
        print(text)
        return True
    if cmd == "--selftest":
        cfg = Config()
        cases = [("王总", "", "方案我看了，下午三点前能改好吗？"), ("王总", "", "[图片]"),
                 ("项目群", "", "[3条]张三: 明天几点开会[微笑] https://a.com/x"), ("微信", "", "李小姐请求添加你为朋友"),
                 ("王总", "", "邀请你进行视频通话"), ("微信", "", "你收到了一条消息")]
        for c in cases:
            print(c[0], "|", c[2], "\n   →", " / ".join(build_phrases([classify(*c)], cfg)))
        print("合并：", " / ".join(build_phrases([classify(*c) for c in cases[:3]], cfg)))
        return True
    if cmd == "--say":
        sp = Speaker(Config())
        sp.speak([" ".join(argv[2:]) or "你好，我是微信语音播报"])
        time.sleep(6)
        return True
    if cmd == "--voices":
        print("\n".join(Speaker(Config()).voices()))
        return True
    return False


if __name__ == "__main__":
    if sys.stdout is None:  # 打包成无窗口 exe 时没有控制台
        sys.stdout = open(os.devnull, "w", encoding="utf-8")
    elif hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if not cli(sys.argv):
        # 防止重复启动
        try:
            import ctypes
            k32 = ctypes.WinDLL("kernel32", use_last_error=True)
            _mutex = k32.CreateMutexW(None, False, "WeChatVoiceSingleton")
            if ctypes.get_last_error() == 183:
                sys.exit(0)
        except Exception:
            pass
        run_tray()

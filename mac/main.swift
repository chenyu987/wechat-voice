// 微信语音播报 (WeChatVoice) — macOS 菜单栏小程序
// 原理：只读取 macOS 自己的“通知中心”数据库（微信弹出的通知会存在这里），
// 发现微信的新通知后，用系统自带的语音朗读出来。
// 不碰微信本身：不注入、不 hook、不读微信聊天记录，所以不会有封号风险。

import Cocoa
import SQLite3
import ServiceManagement

// MARK: - 路径 & 日志

let appSupport = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/WeChatVoice")
let configPath = appSupport + "/config.json"
let logPath = appSupport + "/log.txt"

func log(_ s: String) {
    try? FileManager.default.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - 设置

final class Config {
    static let defaults: [String: Any] = [
        "enabled": true,            // 总开关
        "readContent": true,        // 是否朗读消息内容（关掉只报“谁发来消息”）
        "readGroups": true,         // 是否朗读群消息内容（关掉群消息只报“某某群有新消息”）
        "maxChars": 40,             // 每条最多读多少个字
        "voice": "Tingting",        // 声音：Tingting(普通话) / Meijia(台湾) / Sinji(粤语)，留空用系统默认
        "rate": 210,                // 语速，每分钟字数，180~260 比较自然
        "chime": true,              // 播报前先“叮”一声
        "chimeSound": "Glass",      // 提示音：Glass / Ping / Pop / Tink / Hero ...
        "mergeSeconds": 2.5,        // 连续消息合并等待秒数（防止一句一句刷屏）
        "pollSeconds": 1.0,         // 多久检查一次新通知
        "quietStart": "",           // 免打扰开始，如 "22:30"（留空不启用）
        "quietEnd": "",             // 免打扰结束，如 "08:00"
        "vip": [String](),          // 重要联系人/群（名字包含即可），会加“重要”前缀，免打扰时也照样报
        "vipOnly": false,           // 只播报重要联系人
        "ignore": [String](),       // 不想听的联系人/群（名字包含即可）
        "vipPrefix": "重要联系人",
    ]
    var d: [String: Any] = Config.defaults
    var mtime: Date?

    init() { load() }

    func load() {
        d = Config.defaults
        if let data = FileManager.default.contents(atPath: configPath),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in j where !k.hasPrefix("_") { d[k] = v }
        } else {
            save()
        }
        mtime = (try? FileManager.default.attributesOfItem(atPath: configPath))?[.modificationDate] as? Date
    }

    func reloadIfChanged() {
        let m = (try? FileManager.default.attributesOfItem(atPath: configPath))?[.modificationDate] as? Date
        if m != mtime { load(); log("设置已重新加载") }
    }

    func save() {
        try? FileManager.default.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
        var out = d
        out["_说明"] = [
            "改完保存即可生效，不用重启。true=开 false=关。",
            "vip / ignore 写名字，例如 [\"王总\", \"客户群\"]，名字里包含这些字就算。",
            "voice 可选：Tingting(普通话女声) Meijia(台湾女声) Sinji(粤语)；想要更自然的声音可在 系统设置→辅助功能→朗读内容→系统声音 里下载“增强版”。",
            "quietStart / quietEnd 例如 \"22:30\" 和 \"08:00\"，免打扰期间只有 vip 会播报。",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
        mtime = (try? FileManager.default.attributesOfItem(atPath: configPath))?[.modificationDate] as? Date
    }

    func bool(_ k: String) -> Bool { (d[k] as? Bool) ?? (Config.defaults[k] as? Bool) ?? false }
    func num(_ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? (Config.defaults[k] as? NSNumber)?.doubleValue ?? 0 }
    func str(_ k: String) -> String { (d[k] as? String) ?? (Config.defaults[k] as? String) ?? "" }
    func list(_ k: String) -> [String] { ((d[k] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty } }
    func set(_ k: String, _ v: Any) { d[k] = v; save() }
}

// MARK: - 通知数据库

func darwinUserDir() -> String? {
    var buf = [CChar](repeating: 0, count: 1024)
    let n = confstr(_CS_DARWIN_USER_DIR, &buf, 1024)
    return n > 0 ? String(cString: buf) : nil
}

func notificationDBCandidates() -> [String] {
    var c = [(NSHomeDirectory() as NSString).appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")]
    if let u = darwinUserDir() { c.append((u as NSString).appendingPathComponent("com.apple.notificationcenter/db2/db")) }
    return c
}

final class NotifDB {
    private var db: OpaquePointer?
    private var idCol = "identifier"
    var path: String?

    func close() { if db != nil { sqlite3_close(db); db = nil } }

    /// 返回 nil 表示成功，否则返回错误原因
    func open() -> String? {
        close()
        var lastErr = "找不到系统通知数据库"
        for p in notificationDBCandidates() {
            var h: OpaquePointer?
            let rc = sqlite3_open_v2(p, &h, SQLITE_OPEN_READONLY, nil)
            if rc != SQLITE_OK { sqlite3_close(h); lastErr = "打不开通知数据库（\(rc)）"; continue }
            db = h
            sqlite3_busy_timeout(h, 2000)
            if maxId() == nil {
                lastErr = "没有权限读取通知数据库"
                close(); continue
            }
            idCol = hasColumn("app", "identifier") ? "identifier" : (hasColumn("app", "bundleid") ? "bundleid" : "identifier")
            path = p
            log("已打开通知数据库：\(p)（列 \(idCol)）")
            return nil
        }
        return lastErr
    }

    private func hasColumn(_ table: String, _ col: String) -> Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW {
            if let t = sqlite3_column_text(st, 1), String(cString: t) == col { return true }
        }
        return false
    }

    func maxId() -> Int64? {
        guard db != nil else { return nil }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT IFNULL(MAX(rec_id),0) FROM record", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(st, 0)
    }

    struct Row { let id: Int64; let bundle: String; let data: Data }

    func fetch(after: Int64, limit: Int = 300) -> [Row]? {
        guard db != nil else { return nil }
        let sql = "SELECT r.rec_id, IFNULL(a.\(idCol),''), r.data FROM record r LEFT JOIN app a ON a.app_id = r.app_id WHERE r.rec_id > ? ORDER BY r.rec_id LIMIT \(limit)"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, after)
        var out: [Row] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW {
                let id = sqlite3_column_int64(st, 0)
                let bid = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
                var data = Data()
                if let b = sqlite3_column_blob(st, 2) { data = Data(bytes: b, count: Int(sqlite3_column_bytes(st, 2))) }
                out.append(Row(id: id, bundle: bid, data: data))
            } else if rc == SQLITE_DONE { break } else { return nil }
        }
        return out
    }

    /// 最近 n 条（调试用）
    func recent(_ n: Int) -> [Row] {
        guard let m = maxId() else { return [] }
        return (fetch(after: max(0, m - Int64(n * 20)), limit: 100000) ?? []).suffix(n).map { $0 }
    }
}

func isWeChat(_ bundle: String) -> Bool {
    let b = bundle.lowercased()
    return b.contains("wechat") || b.contains("xinwechat") || b.contains("com.tencent.xin")
}

struct RawNotif { let title: String; let subtitle: String; let body: String }

func parseNotif(_ data: Data) -> RawNotif? {
    guard let pl = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
    let req = pl["req"] as? [String: Any] ?? [:]
    return RawNotif(title: (req["titl"] as? String) ?? "",
                    subtitle: (req["subt"] as? String) ?? "",
                    body: (req["body"] as? String) ?? "")
}

// MARK: - 文本处理

func rxReplace(_ s: String, _ pattern: String, _ tmpl: String) -> String {
    guard let r = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return s }
    return r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: tmpl)
}

func rxGroups(_ s: String, _ pattern: String) -> [String]? {
    guard let r = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
          let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
        guard let rg = Range(m.range(at: i), in: s) else { return "" }
        return String(s[rg])
    }
}

let placeholders: [(String, String)] = [
    ("[图片]", "一张图片"), ("[语音]", "一条语音"), ("[视频]", "一段视频"), ("[文件]", "一个文件"),
    ("[链接]", "一个链接"), ("[动画表情]", "一个表情"), ("[表情]", "一个表情"), ("[位置]", "一个位置"),
    ("[微信红包]", "一个红包"), ("[红包]", "一个红包"), ("[转账]", "一笔转账"), ("[名片]", "一张名片"),
    ("[小程序]", "一个小程序"), ("[聊天记录]", "一段聊天记录"), ("[音乐]", "一首音乐"), ("[视频号]", "一个视频号"),
    ("[Photo]", "一张图片"), ("[Image]", "一张图片"), ("[Voice]", "一条语音"), ("[Video]", "一段视频"),
    ("[File]", "一个文件"), ("[Link]", "一个链接"), ("[Sticker]", "一个表情"), ("[Location]", "一个位置"),
]

/// 把微信的占位符、表情、网址等转成适合朗读的文字
func cleanForSpeech(_ s: String) -> (text: String, isMedia: Bool) {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    let isMedia = rxGroups(t, "^\\[[^\\[\\]]{1,8}\\]$") != nil
    for (k, v) in placeholders { t = t.replacingOccurrences(of: k, with: v) }
    t = rxReplace(t, "https?://\\S+", "一个链接")
    t = rxReplace(t, "\\[[^\\[\\]]{1,6}\\]", "")             // [微笑] [Smile] 这类表情
    t = rxReplace(t, "[\\x{1F000}-\\x{1FAFF}\\x{2600}-\\x{27BF}\\x{FE0F}]", "") // emoji
    t = rxReplace(t, "\\s*\\n+\\s*", "，")
    t = rxReplace(t, "\\s{2,}", " ")
    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty && !s.isEmpty { return ("一个表情", true) }
    return (t, isMedia)
}

func truncate(_ s: String, _ n: Int) -> String {
    guard n > 0, s.count > n else { return s }
    return String(s.prefix(n)) + "，等等"
}

// MARK: - 事件

enum Kind { case message, friend, call, generic }

struct Event {
    let kind: Kind
    let chat: String          // 聊天名（联系人名 或 群名）
    let sender: String?       // 群里发言人；私聊为 nil
    let content: String       // 原始内容
    var isVip = false
    var callType = "语音"
}

let friendKeys = ["请求添加你为朋友", "请求添加你为好友", "添加你为朋友", "加你为朋友", "好友申请", "新的朋友", "朋友验证", "朋友推荐",
                  "wants to add you", "friend request", "Friend Request"]
let callKeys = ["邀请你进行视频通话", "邀请你进行语音通话", "邀请你视频通话", "邀请你语音通话", "视频通话邀请", "语音通话邀请",
                "invites you to a video call", "invites you to a voice call", "video call", "voice call"]
let appNames: Set<String> = ["微信", "WeChat", "Weixin", ""]

func classify(_ n: RawNotif) -> Event {
    let title = n.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let sub = n.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
    var body = n.body.trimmingCharacters(in: .whitespacesAndNewlines)
    body = rxReplace(body, "^\\[\\d+条\\]\\s*", "")
    let all = title + " " + sub + " " + body

    if friendKeys.contains(where: { all.contains($0) }) {
        var name = ""
        if let g = rxGroups(body, "^(.{1,30}?)\\s*(请求添加|想添加|申请添加|wants to add)") { name = g[1] }
        if name.isEmpty, !appNames.contains(title), !friendKeys.contains(where: { title.contains($0) }) { name = title }
        return Event(kind: .friend, chat: name, sender: nil, content: body)
    }
    if callKeys.contains(where: { all.lowercased().contains($0.lowercased()) }) && body.count < 40 {
        var e = Event(kind: .call, chat: appNames.contains(title) ? "" : title, sender: nil, content: body)
        e.callType = all.contains("视频") || all.lowercased().contains("video") ? "视频" : "语音"
        return e
    }
    if appNames.contains(title) && (body.isEmpty || body.contains("收到") && body.contains("消息") && body.count < 20) {
        return Event(kind: .generic, chat: "", sender: nil, content: body)
    }
    // 群消息：正文形如 “张三: 内容”
    if !sub.isEmpty && sub != title {
        return Event(kind: .message, chat: title, sender: sub, content: body)
    }
    if let g = rxGroups(body, "^([^:：\\n]{1,24})[:：]\\s*(.*)$") {
        let who = g[1].trimmingCharacters(in: .whitespaces)
        if who == title { return Event(kind: .message, chat: title, sender: nil, content: g[2]) }
        if !who.contains("http") && !who.contains(" ") || who.count <= 12 {
            return Event(kind: .message, chat: title, sender: who, content: g[2])
        }
    }
    return Event(kind: .message, chat: title, sender: nil, content: body)
}

// MARK: - 生成播报语句

func buildPhrases(_ events: [Event], cfg: Config) -> [String] {
    let readContent = cfg.bool("readContent")
    let readGroups = cfg.bool("readGroups")
    let maxChars = Int(cfg.num("maxChars"))
    let vipPrefix = cfg.str("vipPrefix")
    var out: [String] = []

    func vp(_ e: Event) -> String { e.isVip && !vipPrefix.isEmpty ? vipPrefix + "，" : "" }

    for e in events where e.kind == .call {
        out.append(vp(e) + (e.chat.isEmpty ? "有人" : e.chat) + "给你打微信\(e.callType)电话")
    }
    for e in events where e.kind == .friend {
        out.append(e.chat.isEmpty ? "有新的微信好友申请" : "\(e.chat)申请加你为微信好友")
    }
    if events.contains(where: { $0.kind == .generic }) && !events.contains(where: { $0.kind == .message }) {
        out.append("微信有新消息")
    }

    // 按聊天分组，保持先后顺序
    var order: [String] = []
    var byChat: [String: [Event]] = [:]
    for e in events where e.kind == .message {
        if byChat[e.chat] == nil { order.append(e.chat) }
        byChat[e.chat, default: []].append(e)
    }
    // VIP 排前面
    order.sort { (byChat[$0]!.contains { $0.isVip } ? 0 : 1) < (byChat[$1]!.contains { $0.isVip } ? 0 : 1) }

    var detailed = order
    var summarized: [String] = []
    if order.count > 4 {                     // 同时来了很多个聊天：前 3 个详细报，其余汇总
        detailed = Array(order.prefix(3))
        summarized = Array(order.dropFirst(3))
    }

    for chat in detailed {
        let list = byChat[chat]!
        let last = list.last!
        let k = list.count
        let isGroup = list.contains { $0.sender != nil }
        let name = chat.isEmpty ? "有人" : chat
        let gname = name.hasSuffix("群") ? name : name + "群"
        let (text, isMedia) = cleanForSpeech(last.content)
        let content = truncate(text, maxChars)
        let pre = list.contains { $0.isVip } ? (vipPrefix.isEmpty ? "" : vipPrefix + "，") : ""

        if isGroup {
            let who = last.sender ?? "有人"
            if !readContent || !readGroups || content.isEmpty {
                out.append(pre + (k > 1 ? "\(gname)里有\(k)条新消息" : "\(gname)里有新消息"))
            } else {
                let head = k > 1 ? "\(gname)里有\(k)条新消息，最新是\(who)" : "\(gname)里，\(who)"
                out.append(pre + head + (isMedia ? "发了\(content)" : "说：\(content)"))
            }
        } else {
            if !readContent || content.isEmpty {
                out.append(pre + (k > 1 ? "\(name)发来\(k)条微信" : "\(name)发来微信"))
            } else if k > 1 {
                out.append(pre + "\(name)发来\(k)条消息，最新一条" + (isMedia ? "是\(content)" : "：\(content)"))
            } else {
                out.append(pre + name + (isMedia ? "发来\(content)" : "说：\(content)"))
            }
        }
    }
    if !summarized.isEmpty {
        let n = summarized.reduce(0) { $0 + byChat[$1]!.count }
        let names = summarized.prefix(3).map { $0.isEmpty ? "未知" : $0 }.joined(separator: "、")
        out.append("另外还有\(n)条消息，来自\(names)" + (summarized.count > 3 ? "等\(summarized.count)个聊天" : ""))
    }
    return out
}

// MARK: - 朗读

final class Speaker {
    private let q = DispatchQueue(label: "speaker")
    private var current: Process?
    private let lock = NSLock()

    func speak(_ lines: [String], voice: String, rate: Int, chime: String?) {
        q.async {
            if let c = chime { self.run("/usr/bin/afplay", ["/System/Library/Sounds/\(c).aiff"]) }
            for line in lines {
                var args = ["-r", "\(rate)"]
                if !voice.isEmpty { args += ["-v", voice] }
                args.append(line)
                if self.run("/usr/bin/say", args) != 0 && !voice.isEmpty {
                    self.run("/usr/bin/say", ["-r", "\(rate)", line])   // 声音不存在时退回系统默认
                }
            }
        }
    }

    func stop() {
        lock.lock(); let p = current; lock.unlock()
        p?.terminate()
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        lock.lock(); current = p; lock.unlock()
        p.waitUntilExit()
        lock.lock(); current = nil; lock.unlock()
        return p.terminationStatus
    }
}

// MARK: - 主程序

func hm(_ s: String) -> Int? {
    let p = s.split(separator: ":").compactMap { Int($0) }
    return p.count == 2 ? p[0] * 60 + p[1] : nil
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let cfg = Config()
    let db = NotifDB()
    let speaker = Speaker()
    var status: NSStatusItem!
    var lastId: Int64 = 0
    var timer: Timer?
    var pending: [Event] = []
    var lastArrival = Date.distantPast
    var firstArrival = Date.distantPast
    var dbError: String? = "正在启动…"
    var pausedUntil: Date?
    var recent: [(Date, String)] = []
    var todayCount = 0
    var todayKey = ""
    var alertedPermission = false
    var reopenAt = Date.distantPast

    func applicationDidFinishLaunching(_ n: Notification) {
        log("启动 v1.0")
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self
        status.menu = menu
        tryOpenDB()
        refreshIcon()
        scheduleTimer()
        if dbError != nil { showPermissionHelp() }
        else if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            speaker.speak(["微信语音播报已启动"], voice: cfg.str("voice"), rate: Int(cfg.num("rate")), chime: nil)
        }
    }

    func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(0.3, cfg.num("pollSeconds")), repeats: true) { [weak self] _ in self?.tick() }
    }

    func tryOpenDB() {
        if let err = db.open() {
            dbError = err
        } else {
            dbError = nil
            let m = db.maxId() ?? 0
            if lastId == 0 || lastId > m { lastId = m }   // 只播报启动以后的新消息
        }
    }

    // 每秒执行
    func tick() {
        cfg.reloadIfChanged()
        if dbError != nil {
            if Date() > reopenAt { reopenAt = Date().addingTimeInterval(5); tryOpenDB(); refreshIcon() }
            return
        }
        guard let rows = db.fetch(after: lastId) else {
            log("读取失败，准备重连"); dbError = "读取通知数据库失败"; db.close(); refreshIcon(); return
        }
        for r in rows {
            lastId = max(lastId, r.id)
            guard isWeChat(r.bundle), let n = parseNotif(r.data) else { continue }
            var e = classify(n)
            let names = [e.chat, e.sender ?? ""].filter { !$0.isEmpty }
            e.isVip = cfg.list("vip").contains { v in names.contains { $0.contains(v) } }
            let ignored = cfg.list("ignore").contains { v in names.contains { $0.contains(v) } }
            log("微信通知 #\(r.id) 类型=\(e.kind) 聊天=\(e.chat)\(ignored ? " (已忽略)" : "")")
            if e.kind == .message && ignored && !e.isVip { continue }
            if cfg.bool("vipOnly") && !e.isVip && e.kind != .friend { continue }
            if pending.isEmpty { firstArrival = Date() }
            pending.append(e)
            lastArrival = Date()
        }
        if !pending.isEmpty {
            let quiet = Date().timeIntervalSince(lastArrival) >= cfg.num("mergeSeconds")
            let tooLong = Date().timeIntervalSince(firstArrival) >= 8
            if quiet || tooLong { flush() }
        }
    }

    func isMutedNow() -> Bool {
        if !cfg.bool("enabled") { return true }
        if let p = pausedUntil, p > Date() { return true }
        return inQuietHours()
    }

    func inQuietHours() -> Bool {
        guard let s = hm(cfg.str("quietStart")), let e = hm(cfg.str("quietEnd")), s != e else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return s < e ? (now >= s && now < e) : (now >= s || now < e)
    }

    func flush() {
        var evs = pending; pending = []
        let manualMuted = !cfg.bool("enabled") || (pausedUntil.map { $0 > Date() } ?? false)
        if manualMuted { return }
        if inQuietHours() { evs = evs.filter { $0.isVip || $0.kind == .call } }
        let lines = buildPhrases(evs, cfg: cfg)
        guard !lines.isEmpty else { return }
        say(lines)
    }

    func say(_ lines: [String]) {
        let key = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        if key != todayKey { todayKey = key; todayCount = 0 }
        todayCount += lines.count
        for l in lines { recent.insert((Date(), l), at: 0) }
        if recent.count > 15 { recent.removeLast(recent.count - 15) }
        let chime = cfg.bool("chime") ? cfg.str("chimeSound") : nil
        speaker.speak(lines, voice: cfg.str("voice"), rate: Int(cfg.num("rate")), chime: chime)
    }

    // MARK: 菜单栏

    func refreshIcon() {
        guard let b = status.button else { return }
        let sym: String
        if dbError != nil { sym = "exclamationmark.triangle" }
        else if isMutedNow() { sym = "speaker.slash" }
        else { sym = "speaker.wave.2" }
        let img = NSImage(systemSymbolName: sym, accessibilityDescription: "微信语音播报")
        img?.isTemplate = true
        b.image = img
        b.toolTip = "微信语音播报"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ t: String, _ a: Selector?, _ key: String = "", on: Bool? = nil, rep: Any? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: key)
            i.target = self
            if let o = on { i.state = o ? .on : .off }
            i.representedObject = rep
            if a == nil { i.isEnabled = false }
            menu.addItem(i); return i
        }
        if let err = dbError {
            item("⚠️ " + err, nil)
            item("去开启“完全磁盘访问权限”…", #selector(openFDA))
            item("我已开启，重新检测", #selector(recheck))
        } else if let p = pausedUntil, p > Date() {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            item("已暂停，到 \(f.string(from: p)) 自动恢复", nil)
        } else if inQuietHours() {
            item("免打扰时段中（只报重要联系人）", nil)
        } else if !cfg.bool("enabled") {
            item("播报已关闭", nil)
        } else {
            item("正在帮你盯着微信 · 今天已播报 \(todayCount) 条", nil)
        }
        menu.addItem(.separator())
        item("开启语音播报", #selector(toggle(_:)), on: cfg.bool("enabled"), rep: "enabled")
        item("朗读消息内容", #selector(toggle(_:)), on: cfg.bool("readContent"), rep: "readContent")
        item("朗读群消息内容", #selector(toggle(_:)), on: cfg.bool("readGroups"), rep: "readGroups")
        item("只报重要联系人", #selector(toggle(_:)), on: cfg.bool("vipOnly"), rep: "vipOnly")
        item("播报前“叮”一声", #selector(toggle(_:)), on: cfg.bool("chime"), rep: "chime")

        let pause = NSMenuItem(title: "暂停一会儿", action: nil, keyEquivalent: "")
        let pm = NSMenu()
        for (t, m) in [("30 分钟", 30), ("1 小时", 60), ("2 小时", 120), ("今天不再播报", -1)] {
            let i = NSMenuItem(title: t, action: #selector(pauseFor(_:)), keyEquivalent: ""); i.target = self; i.tag = m; pm.addItem(i)
        }
        if pausedUntil != nil {
            pm.addItem(.separator())
            let i = NSMenuItem(title: "马上恢复", action: #selector(resume), keyEquivalent: ""); i.target = self; pm.addItem(i)
        }
        pause.submenu = pm; menu.addItem(pause)

        let rec = NSMenuItem(title: "最近播报", action: nil, keyEquivalent: "")
        let rm = NSMenu()
        if recent.isEmpty { let i = NSMenuItem(title: "（还没有）", action: nil, keyEquivalent: ""); rm.addItem(i) }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        for (d, t) in recent {
            let i = NSMenuItem(title: "\(f.string(from: d))  \(t)", action: #selector(replay(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = t; rm.addItem(i)
        }
        rec.submenu = rm; menu.addItem(rec)

        menu.addItem(.separator())
        item("试听一下", #selector(test))
        item("停止朗读", #selector(stopSpeaking))
        item("重要联系人 / 屏蔽 / 声音等设置…", #selector(openConfig))
        item("开机自动启动", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        item("查看运行日志", #selector(openLog))
        menu.addItem(.separator())
        item("退出微信语音播报", #selector(quit), "q")
    }

    @objc func toggle(_ s: NSMenuItem) {
        guard let k = s.representedObject as? String else { return }
        cfg.set(k, !cfg.bool(k)); refreshIcon()
    }
    @objc func pauseFor(_ s: NSMenuItem) {
        if s.tag < 0 {
            pausedUntil = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400 + 7 * 3600) // 明早 7 点
        } else {
            pausedUntil = Date().addingTimeInterval(Double(s.tag) * 60)
        }
        speaker.stop(); refreshIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + (pausedUntil!.timeIntervalSinceNow + 1)) { [weak self] in self?.refreshIcon() }
    }
    @objc func resume() { pausedUntil = nil; refreshIcon() }
    @objc func replay(_ s: NSMenuItem) {
        if let t = s.representedObject as? String { speaker.speak([t], voice: cfg.str("voice"), rate: Int(cfg.num("rate")), chime: nil) }
    }
    @objc func test() {
        let samples = [
            Event(kind: .message, chat: "王总", sender: nil, content: "方案我看了，下午三点前能改好吗？"),
            Event(kind: .friend, chat: "李小姐", sender: nil, content: "李小姐请求添加你为朋友"),
        ]
        let chime = cfg.bool("chime") ? cfg.str("chimeSound") : nil
        speaker.speak(buildPhrases(samples, cfg: cfg), voice: cfg.str("voice"), rate: Int(cfg.num("rate")), chime: chime)
    }
    @objc func stopSpeaking() { speaker.stop() }
    @objc func openConfig() {
        cfg.save()
        NSWorkspace.shared.open([URL(fileURLWithPath: configPath)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
    @objc func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { log("开机启动设置失败：\(error)") }
    }
    @objc func openFDA() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        // 同时在访达里选中本程序，方便拖进列表
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    @objc func recheck() {
        tryOpenDB(); refreshIcon()
        if dbError != nil {
            // 权限通常要重启程序后才生效
            let a = NSAlert()
            a.messageText = "还读不到通知"
            a.informativeText = "如果你刚刚打开了权限，需要重启一下本程序才会生效。现在重启吗？"
            a.addButton(withTitle: "重启"); a.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { relaunch() }
        } else {
            speaker.speak(["好了，开始帮你盯着微信"], voice: cfg.str("voice"), rate: Int(cfg.num("rate")), chime: nil)
        }
    }
    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
    func showPermissionHelp() {
        guard !alertedPermission else { return }
        alertedPermission = true
        let a = NSAlert()
        a.messageText = "还差一步：开启“完全磁盘访问权限”"
        a.informativeText = """
        微信语音播报需要读取 Mac 的“通知中心”记录，才能知道微信来了什么消息（它不会碰微信本身）。

        1. 点“去设置”，会打开“隐私与安全性 → 完全磁盘访问权限”
        2. 点列表下面的“+”，选“应用程序”里的“微信语音播报”（或直接把弹出的访达窗口里的图标拖进列表）
        3. 打开它旁边的开关，然后回到这里点菜单栏图标 →“我已开启，重新检测”
        """
        a.addButton(withTitle: "去设置"); a.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { openFDA() }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - 命令行调试模式

func runCLI(_ args: [String]) -> Bool {
    guard let cmd = args.dropFirst().first else { return false }
    switch cmd {
    case "--dump":   // 打印最近的通知（看格式用）
        let db = NotifDB()
        if let e = db.open() {
            try? FileManager.default.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
            try? "错误：\(e)\n".write(toFile: appSupport + "/dump.txt", atomically: true, encoding: .utf8)
            print("错误：\(e)"); exit(1)
        }
        // 同时写到 dump.txt：用 open 启动时（拥有本程序的磁盘权限）也能看到结果
        var out = "数据库：\(db.path ?? "")\n"
        for r in db.recent(Int(args.dropFirst(2).first ?? "30") ?? 30) {
            let n = parseNotif(r.data)
            let mark = isWeChat(r.bundle) ? "【微信】" : ""
            out += "#\(r.id) \(mark)\(r.bundle) | 标题=\(n?.title ?? "?") | 副标题=\(n?.subtitle ?? "") | 正文=\(n?.body ?? "?")\n"
            if isWeChat(r.bundle), let n = n { out += "   → 会播报：\(buildPhrases([classify(n)], cfg: Config()).joined(separator: " / "))\n" }
        }
        print(out, terminator: "")
        try? out.write(toFile: appSupport + "/dump.txt", atomically: true, encoding: .utf8)
        exit(0)
    case "--selftest":
        let cases: [RawNotif] = [
            RawNotif(title: "王总", subtitle: "", body: "方案我看了，下午三点前能改好吗？"),
            RawNotif(title: "王总", subtitle: "", body: "[图片]"),
            RawNotif(title: "项目群", subtitle: "", body: "[3条]张三: 明天几点开会[微笑] https://a.com/x"),
            RawNotif(title: "微信", subtitle: "", body: "李小姐请求添加你为朋友"),
            RawNotif(title: "新的朋友", subtitle: "", body: "Tom 请求添加你为朋友"),
            RawNotif(title: "王总", subtitle: "", body: "邀请你进行视频通话"),
            RawNotif(title: "微信", subtitle: "", body: "你收到了一条消息"),
        ]
        let cfg = Config()
        for c in cases { print("\(c.title) | \(c.body)\n   → \(buildPhrases([classify(c)], cfg: cfg).joined(separator: " / "))") }
        let burst = [classify(cases[0]), classify(cases[1]), classify(cases[2])]
        print("合并：\(buildPhrases(burst, cfg: cfg).joined(separator: " / "))")
        exit(0)
    case "--say":
        let s = Speaker(); let cfg = Config()
        s.speak([args.dropFirst(2).joined(separator: " ")], voice: cfg.str("voice"), rate: Int(cfg.num("rate")), chime: nil)
        Thread.sleep(forTimeInterval: 0.2)
        DispatchQueue(label: "speaker").sync {}
        sleep(6); exit(0)
    default:
        return false
    }
}

if !runCLI(CommandLine.arguments) {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

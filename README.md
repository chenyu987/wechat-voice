# 微信语音播报 · WeChat Voice

忙的时候不用盯着微信：来了新消息、好友申请或微信电话，电脑会“叮”一声，然后用中文念出来。

> 王总说：方案我看了，下午三点前能改好吗？
> 李小姐申请加你为微信好友
> 项目群里有 3 条新消息，最新是张三说：明天几点开会

## 安全吗？会不会封号？

不会碰微信本身。它只读取电脑**自己的通知记录**（微信弹出的横幅通知会被系统记下来），然后用系统自带的语音朗读。
没有注入、没有 hook、不读聊天数据库、不模拟点击，和你自己看一眼通知是一样的。

## Mac 版

要求：macOS 13 以上，装了“命令行开发工具”（终端里运行 `xcode-select --install` 即可）。

```bash
git clone https://github.com/chenyu987/wechat-voice.git
cd wechat-voice/mac
bash build.sh          # 编译并安装到 /Applications/微信语音播报.app，然后自动打开
```

第一次打开后还差一步：
**系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 点“+”加入「微信语音播报」并打开开关**，再点菜单栏小喇叭里的“我已开启，重新检测”。

> 注意：每次重新编译后，需要在这个列表里把它删掉再重新加一次（自签名的程序换了版本，系统会当成新程序）。

### 微信这边要打开

- 微信 → 设置 → 通知：打开“新消息通知”，并勾选“通知显示消息详情”（不勾的话只能报“微信有新消息”，报不出是谁、说了什么）
- 系统设置 → 通知 → 微信：允许通知，样式选“横幅”或“提醒”
- 被你设为“消息免打扰”的群不会弹通知，所以也不会播报
- 微信窗口正好在最前面时，微信自己不弹通知，也就不会播报（你正看着呢）

### 菜单栏功能

点右上角的小喇叭：

| 功能 | 说明 |
| --- | --- |
| 开启语音播报 | 总开关 |
| 朗读消息内容 | 关掉后只报“王总发来微信”，适合旁边有人的时候 |
| 朗读群消息内容 | 关掉后群消息只报“某某群有新消息” |
| 只报重要联系人 | 只报 `vip` 名单里的人和群（好友申请照报） |
| 暂停一会儿 | 30 分钟 / 1 小时 / 2 小时 / 今天不再播报 |
| 最近播报 | 最近 15 条，点一下重听 |
| 试听一下 | 听听效果 |
| 设置… | 打开设置文件（见下） |
| 开机自动启动 | 打开后开机就在后台帮你盯着 |

### 设置文件

`~/Library/Application Support/WeChatVoice/config.json`，改完保存立刻生效（下面 `//` 后面是说明，真实文件里不要写）：

```json
{
  "vip": ["王总", "客户"],          // 重要联系人/群：加“重要联系人”前缀，免打扰时段也照报
  "ignore": ["吃喝群", "公众号"],    // 不想听的
  "quietStart": "22:30",            // 免打扰时段（只报 vip 和电话）
  "quietEnd": "08:00",
  "voice": "Tingting",              // Tingting 普通话 / Meijia 台湾腔 / Sinji 粤语
  "rate": 210,                      // 语速
  "maxChars": 40,                   // 每条最多念多少字
  "mergeSeconds": 2.5,              // 连发几条会合并成一句
  "chimeSound": "Glass"             // 提示音
}
```

想要更自然的声音：系统设置 → 辅助功能 → 朗读内容 → 系统声音 → 管理声音，下载“婷婷（增强版/高品质）”。

### 调试

```bash
# 自测播报句子
/Applications/微信语音播报.app/Contents/MacOS/WeChatVoice --selftest
# 查看最近的系统通知（结果也写到 ~/Library/Application Support/WeChatVoice/dump.txt）
open -W -n /Applications/微信语音播报.app --args --dump 40
# 运行日志
cat ~/Library/Application\ Support/WeChatVoice/log.txt
```

## Windows 版

**下载：** [WeChatVoice.exe](https://github.com/chenyu987/wechat-voice/releases/download/windows-latest/WeChatVoice.exe)（每次更新代码会自动重新打包）

1. 下载后双击运行。第一次可能弹出“Windows 已保护你的电脑”，点“更多信息 → 仍要运行”（因为这个小程序没有花钱买签名证书）。
2. 运行后会念“微信语音播报已启动”，右下角托盘（可能在 ^ 小箭头里）出现绿色气泡图标，右键它就是菜单，功能和 Mac 版一样。
3. 默认会设置成开机自动启动，不想要可以在菜单里取消。

前提：**Windows 版微信要会弹出 Windows 系统通知**（屏幕右下角的通知横幅，或者在通知中心里能看到微信的通知）。
如果微信来消息时只是任务栏图标闪、没有系统通知，这个版本就报不出来。可以检查：
- 微信 → 设置 → 通知：打开新消息通知
- Windows 设置 → 系统 → 通知：打开通知总开关，列表里的“微信 / Weixin”也要打开；关掉“请勿打扰”和专注模式

### 测试反馈（请帮忙）

收到几条微信后，在命令行（Win+R 输入 cmd）运行：

```
%USERPROFILE%\Downloads\WeChatVoice.exe --dump 40
```

然后把 `%APPDATA%\WeChatVoice\dump.txt` 和 `%APPDATA%\WeChatVoice\log.txt` 发回来（里面有通知内容，介意的话可以把文字打码，保留格式就行）。
dump.txt 里带【微信】标记的行越多越好；如果一行都没有，说明这台电脑上的微信没有走 Windows 系统通知。

设置文件在 `%APPDATA%\WeChatVoice\config.json`，选项和 Mac 版一样（`rate` 是 -10 到 10，`voice` 留空自动用中文声音）。

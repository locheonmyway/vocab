# Vocab 安装指南 · macOS

适用于 Apple Silicon Mac、macOS 14 或更高版本。无需复制 ENG、维护者的词表、Pi 配置或私人学习记录。

## 1. 安装一次开发工具与本机签名

打开终端运行 `xcode-select --install`（如果已经安装则跳过），完成系统弹出的安装流程。确认 `xcrun swiftc --version` 和 `python3 --version` 可用。

Vocab 目前从源码本机编译，而非提供经过公证的预编译应用。
在「钥匙串访问」→「证书助理」→「创建证书」创建自己的 **Vocab Local Code Signing** 证书：
身份类型为自签名根证书，证书类型为代码签名，保存于登录钥匙串。
已有适用代码签名证书也可使用，设置环境变量 `VOCAB_SIGN_IDENTITY` 为证书名称或指纹。
后续升级应始终使用同一证书，不要删除它或复制他人的私钥。
如 macOS 询问是否允许使用私钥，核对是本机 Vocab 签名后允许。
无需关闭 Gatekeeper，也无需重置全局权限。

## 2. 安装

```sh
git clone https://github.com/locheonmyway/vocab.git
cd vocab
zsh tools/install-local.sh
```

运行结束后，Vocab 出现在菜单栏，并随登录启动。安装至
`~/Applications/Vocab.app`；既有数据不会被覆盖，升级时保留回滚备份。

## 3. 首次配置

- **权限：** 菜单栏 → Vocab 设置 → 辅助功能、屏幕捕获；首次使用话筒时允许麦克风。使用鼠标前侧键或 Control-Option-V 查词；取词失败可手输或由局部 OCR 获取。若授权提示重新打开 App，按系统提示操作。
- **Oxford：** 打开 macOS「词典」→ 设置，选择并等待下载 Oxford Dictionary of English、Oxford American Writer’s Thesaurus；需要中文时启用 Oxford Chinese Dictionary（可用名称取决于系统区域/版本）。分别查 `imperative` 和 `get` 确认词书就绪。词典由 Apple 提供；Vocab 不分发词库。
- **AI：** 自行安装并登录 Pi，在终端确认自己的模型可以正常回答。进入 Vocab 设置填入准确的 Pi provider 和 model、思考档位（默认 qoder-cn / DeepSeek-Flash / high）。Qoder 需已安装并配置相应 Pi 扩展。点击「测试 AI 连接」。其他供应商须是 Pi 的内置可用 provider；账户、额度及登录由 Pi 管理。
- **语音：** 运行兼容的本机 OMLXVoice / Whisper 服务（默认 `http://127.0.0.1:8977/inference`）；若地址不同可在设置修改。点话筒说一句并确认转写；没有服务也能正常键入。只有回环地址受支持。
- **可选 Codex：** 在自己的 Codex 中准备语言助手聊天，填写其 UUID 并保存连接；未绑定不影响词典或练习。

## 4. 学习及后续更新

打开学习空间或知识地图会自动检查正式知识发行；也可在地图总览底部点「检查更新」。
更新失败或断网继续使用原目录，不会覆盖学习记录；练习期间新目录延后应用。
初始知识包 112 个点、314 个情境，与你个人进度无关。

App 源码更新（不是知识更新）只需在自己的 clone 中运行：

```sh
git pull --ff-only
zsh tools/install-local.sh
```

本地个人记录位于 `~/Library/Application Support/Vocab/V2`，设置另存于 macOS 用户偏好。不要共享这些目录或把它们提交 Git。如果需要备份，先退出 Vocab，再复制本地数据目录及个人配置；不要交换数据库。

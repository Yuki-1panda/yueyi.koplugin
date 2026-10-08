# 月译（双译）

轻量的 KOReader 整书 / 逐章双语翻译插件，为 EPUB 建立独立的译文覆盖层，**不修改原书**。

本项目最初是**为了自己在 Kindle 上阅读外文书籍**而做的改造：在满足个人阅读需求的过程中逐步打磨出当前形态，开源发布仅供有同样需求的读者参考使用。项目直接基于上游 [**DualTranslate**（双译）](https://github.com/enneaa/dualtranslate.koplugin)（GPL-3.0）改造而来；DualTranslate 本身由 **KoTranslate**（v1.2.11，GPL-3.0）改造而来，移除 Kindle 专属依赖（shell/unzip/awk）、去掉辅助阅读与词典功能、改用纯 Lua 实现，可在 KOReader 支持的全平台（Kindle / Android / iOS / Linux / macOS / Windows）运行。

> 注意：当前代码仓库与历史交付版本为**非破坏式 overlay 方案**（译文注入排版，不生成双语 EPUB 文件），与旧版 KoTranslate 的"生成双语 EPUB"行为不同。

## 翻译引擎

在本机原版（免 API 双引擎）基础上，新增 **自定义大模型 API** 与 **内置提示词** 能力，共支持三种引擎：

| 引擎 | 说明 | 默认 |
| --- | --- | --- |
| microsoft_free（Microsoft Edge 免费） | `edge.microsoft.com/translate/translatetext`，批量 ≤12 条 / ≤4000 字节，批量失败自动降级逐条重试 | ✓ 默认 |
| system（系统翻译） | 调用 KOReader 内置 `ui/translator`，逐段请求 | |
| custom_api（自定义 API） | OpenAI 兼容 `/v1/chat/completions`，填入 base_url + API Key 即可使用（OpenAI / DeepSeek / 通义千问 / Kimi / 本地 Ollama 等） | |

**大模型翻译特性：**
- **内置提示词预设**：整书翻译提供多种 prompt 风格预设，可按需切换。
- **术语表注入**：支持整份术语表智能注入（截断/汇总策略控制 prompt 膨胀）。
- **模型思维模式适配**：自动识别 DeepSeek-R1 / V4、Qwen- Thinking、OpenAI o 系等推理模型，适配 `thinking` / `reasoning_effort` 参数，避免与推理模式冲突。

目标语言归一化：`zh-Hans → zh`、`zh-Hant → zh-TW`，与 KOReader 内置翻译一致。

## 功能

- **整书翻译**：后台队列逐章翻译，可断点续跑（意外退出后再次翻译会合并已有结果）。
- **逐章翻译**：从当前章节开始翻译，翻到新章节时自动续译，可随时停止。
- **译文覆盖层**：通过 CSS `::after` 注入排版，原 EPUB 永不被改写；译文随设置显示/隐藏。
- **翻译队列**：查看进度、**取消**任务（取消保留已翻译部分）。
- **进度显示**：整书/逐章翻译均有进度条；点开队列可弹进度条，点进度条弹操作窗口（取消），点外部收起。
- **译文样式**：字号（原生 SpinWidget 增减控件 8–40）、字体、颜色独立设置，不受全局排版影响。
- **按书缓存**：译文存 SQLite（WAL），`book_translations` 表按书隔离；覆盖层按「书 + 目标语言」独立目录。
- **清除本书译文**：同时删除覆盖层、缓存与遗留翻译任务，原书不受影响。

## 安装

KOReader 的插件目录是安装根目录下的 `plugins/` 文件夹，目录名匹配 `*.koplugin` 即被识别为插件。各平台常见位置：

| 平台 | plugins/ 目录 |
| --- | --- |
| Kindle | `/mnt/us/koreader/plugins/` |
| Android | 内部存储 `/storage/emulated/0/koreader/plugins/`（即 `sdcard/koreader/plugins/`） |
| Linux / macOS / Windows | 发行包解压目录 `koreader/plugins/`（与 `koreader` 可执行文件同级） |
| 其他平台 | KOReader 安装根目录下的 `plugins/` |

### 安装步骤

1. 从 [Releases](https://github.com/Yuki-1panda/yueyi.koplugin/releases) 下载 `yueyi.koplugin.zip`。
2. **删除** KOReader `plugins/` 中旧的 `yueyi.koplugin`（或 `kotranslate.koplugin`）目录（如有）。
3. 将 zip 内容解压到 `plugins/yueyi.koplugin/`，最终目录结构应为：
   ```
   plugins/yueyi.koplugin/
   ├── main.lua
   ├── yueyi_reader.lua
   ├── ...（其余 .lua）
   └── _meta.lua
   ```
   > 注意不要多套一层目录（`plugins/yueyi.koplugin/yueyi.koplugin/…` 不会被加载）。
4. **完全退出并重启 KOReader**（不是返回书架，是彻底退出进程）。

### 验证安装

重启后打开任意 EPUB，菜单栏出现 **月译** 菜单即安装成功；菜单项显示「翻译服务：Microsoft Edge（免费）」为默认状态。

### 升级注意事项

- 升级只替换 `plugins/yueyi.koplugin/` 目录即可；译文、缓存、队列与设置保存在 KOReader 数据目录，**不会丢失**。
- 若从旧版 KoTranslate 升级：旧配置 `yueyi_configuration.lua` 会自动迁移；旧译文数据不会被读取，需重新翻译（overlay 方案与旧版不兼容）。

## 使用

打开 EPUB 后，菜单栏出现 **月译** 菜单：

- 第一项为插件开关（复选框）；停用不会删除译文、缓存、队列或设置。
- 选择「翻译服务」「源语言」「目标语言」。
- 「翻译本书」开始整书翻译；勾选「逐章模式」则只翻译当前章节并随翻页自动续译后续章节。
- 「翻译队列」查看进度与取消任务。
- 「显示译文」切换译文可见性；「译文字号/字体/颜色」调整译文样式。
- 「清除本书译文」彻底删除本书翻译数据。

## 数据位置

- 译文覆盖层：KOReader 数据目录 `cache/yueyi/books/<hash>/overlay.json`
- 译文数据库：KOReader 数据目录 `yueyi_cache.sqlite3`（WAL 模式）
- 进度文件：`cache/yueyi/progress_*.txt`
- 配置：KOReader 原生 `settings/yueyi.lua`（`yueyi_` 前缀键），旧版 `yueyi_configuration.lua` 自动迁移

## 从源码构建 / 测试

```sh
# 语法检查
luac -p *.lua

# 单元测试（无需 KOReader 环境，纯 Lua 5.1/5.3 均可）
lua tests/loadtest.lua
lua tests/fulltest.lua
lua tests/epub_test.lua
lua tests/state2_test.lua
lua tests/cache_test.lua
lua tests/langmenu_test.lua
lua tests/callcheck.lua
lua tests/queueui_test.lua
lua tests/clear_test.lua

# 打包（排除 tests 与迁移配置）
zip -q -r ../yueyi.koplugin.zip . -x "./.*" -x "./tests/*" \
    -x "./yueyi_configuration.lua" -x "./yueyi_configuration_sample.lua"
```

## 许可

GPL-3.0，与上游 KoTranslate 一致。详见 [LICENSE](LICENSE)。

完整版本变更记录见 [XPLATFORM.md](XPLATFORM.md)。

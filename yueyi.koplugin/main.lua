
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Cache = require("yueyi_cache")
local Providers = require("yueyi_providers")
local TranslationUI = require("yueyi_ui")
local Languages = require("yueyi_languages")
local State = require("yueyi_state")
local Reader = require("yueyi_reader")
local PageTrans = require("yueyi_pagetrans")
local InputDialog = require("ui/widget/inputdialog")
local Updater = require("yueyi_updater")

local yueyi = WidgetContainer:extend{
    name = "yueyi",
    is_doc_only = false,
}

-- 启动即清理上次 OTA 更新留下的旧版目录/临时文件（失败静默，不影响使用）。
pcall(function() Updater.cleanupOld() end)

-- 插件改名 dualtranslate -> yueyi 后，设置键前缀随之改变。把旧前缀下的
-- 设置（API 地址 / Key / 模型 / 提示词风格 / 语言等）迁移到新前缀，
-- 避免用户重新填写一遍 API 配置。只做一次，之后写入迁移标记。
function yueyi:migrateLegacySettings()
    if not G_reader_settings then return end
    if G_reader_settings:readSetting("yueyi_settings_migrated") == true then return end
    local legacy = {
        "mode", "source_lang", "target_lang", "api_base_url", "api_key",
        "api_model", "api_prompt_style", "glossary_enabled", "bypass_cache",
        "enable_cache", "inline_color", "inline_color_enabled",
        "translation_visible", "plugin_enabled", "inline_font_size",
        "inline_line_spacing", "inline_indent", "translation_enabled",
        "page_translation_enabled",
    }
    local moved = 0
    for _, key in ipairs(legacy) do
        local old_value = G_reader_settings:readSetting("dualtranslate_" .. key)
        if old_value ~= nil then
            if G_reader_settings:readSetting("yueyi_" .. key) == nil then
                G_reader_settings:saveSetting("yueyi_" .. key, old_value)
                moved = moved + 1
            end
            if G_reader_settings.delSetting then
                G_reader_settings:delSetting("dualtranslate_" .. key)
            end
        end
    end
    G_reader_settings:saveSetting("yueyi_settings_migrated", true)
end

function yueyi:init()
    State.attach(self)
    Reader.attach(self)
    PageTrans.attach(self)
    -- 改名后的旧设置迁移，必须在读取任何设置之前完成。
    self:migrateLegacySettings()
    -- One-time migration of older standalone config files into KOReader's
    -- native G_reader_settings (see State.loadConfig).  All settings are then
    -- read and written through the standard KOReader settings API.
    self:loadConfig()
    self.cache = Cache:new()
    self._translation_queue = self:loadTranslationQueue()
    -- Persist cleanup of completed entries immediately after startup.
    self:saveTranslationQueue()

    -- Load the EPUB engine defensively.  Prefer require(), but fall back to
    -- an absolute-path dofile from our own plugin directory so the engine
    -- can never resolve to another plugin's file or to a non-table value.
    self.epub = self:loadEpubModule()
    if not self.epub then
        logger.warn("yueyi: EPUB engine failed to load (no module, no dofile)")
    end

    -- Translation requests may need Wi-Fi, but connection retries must stay
    -- in the background.  Keep an explicit user's "ignore" choice intact;
    -- only replace KOReader's default prompt behavior.
    if G_reader_settings then
        if not G_reader_settings:readSetting("yueyi_silent_network") then
            G_reader_settings:saveSetting("yueyi_silent_network", true)
        end
        -- Never overwrite KOReader's global Wi-Fi policy.  The reader's own
        -- NetworkMgr handles prompts and restoration; the plugin only reports
        -- provider errors to the user.
    end

    self.ui.menu:registerToMainMenu(self)

    -- The reader hooks open the companion after document-ready. Keep the
    -- queue startup here, but do not replace a document during init.
    self:startNextQueuedTranslation()
end

-- Load the EPUB engine module.
--
-- KOReader appends every installed plugin directory to package.path (in
-- path-sorted order).  A bare module name could therefore resolve to a
-- file belonging to another plugin; require() can even come back with a
-- non-table value.  We therefore try require() first, then fall back to
-- loading the file straight from our own directory via self.path (set by
-- PluginLoader), which is immune to any package.path pollution.
function yueyi:loadEpubModule()
    local ok, mod = pcall(require, "yueyi_epub")
    if ok and type(mod) == "table" then
        return mod
    end
    logger.warn("yueyi: require(\"yueyi_epub\") failed:", tostring(mod))
    if self.path then
        local ok2, mod2 = pcall(dofile, self.path .. "/yueyi_epub.lua")
        if ok2 and type(mod2) == "table" then
            logger.warn("yueyi: loaded yueyi_epub.lua via dofile")
            return mod2
        end
        logger.warn("yueyi: dofile yueyi_epub.lua failed:", tostring(mod2))
    end
    return nil
end

-- Persistent configuration and translation-queue state lives in yueyi_state.lua.

------------------------------------------------------------------------
-- Settings helpers
------------------------------------------------------------------------
-- All plugin settings are stored through KOReader's native G_reader_settings
-- (settings.reader.lua), keyed with the yueyi_ prefix.
function yueyi:getSetting(key, default)
    local prefixed = "yueyi_" .. key
    local value = G_reader_settings and G_reader_settings:readSetting(prefixed)
    if value == nil then
        return default
    end
    return value
end

function yueyi:saveSetting(key, value)
    if G_reader_settings then
        G_reader_settings:saveSetting("yueyi_" .. key, value)
    end
end

function yueyi:isPluginEnabled()
    return self:getSetting("plugin_enabled", true) == true
end

function yueyi:togglePluginEnabled(menu)
    local enabled = not self:isPluginEnabled()
    self:saveSetting("plugin_enabled", enabled)
    self:refreshDocumentStyles()
    if enabled then
        self:startNextQueuedTranslation()
    else
        UIManager:setDirty("all", "ui")
    end
    if menu and menu.updateItems then menu:updateItems() end
end

function yueyi:queueStats()
    local active, queued = 0, 0
    for _, item in ipairs(self._translation_queue or {}) do
        if type(item) == "table" then
            if item.status == "queued" then queued = queued + 1
            elseif item.status == "active" then active = active + 1 end
        end
    end
    return active, queued
end

function yueyi:getMode()
    local mode = self:getSetting("mode", "microsoft_free")
    local valid = { system = true, microsoft_free = true, custom_api = true }
    if not valid[mode] then
        return "microsoft_free"
    end
    return mode
end

function yueyi:getSourceLang()
    return self:getSetting("source_lang", "auto")
end

function yueyi:getTargetLang()
    return self:getSetting("target_lang", "zh-Hans")
end

-- Keep requests below the common free web-engine request limit.
function yueyi:getTranslationChunkLimit()
    local limits = {
        microsoft_free = 4500,
        custom_api = 4000,
    }
    return limits[self:getMode()] or 4500
end

------------------------------------------------------------------------
-- 自定义 API（OpenAI 兼容）配置
------------------------------------------------------------------------
function yueyi:getApiBaseUrl()
    return self:getSetting("api_base_url", "https://api.openai.com/v1")
end

function yueyi:getApiKey()
    return self:getSetting("api_key", "")
end

function yueyi:getApiModel()
    return self:getSetting("api_model", "gpt-4o-mini")
end

function yueyi:getApiPromptStyle()
    return self:getSetting("api_prompt_style", "general")
end

-- 通用文本输入弹窗，用于填写 API 地址 / Key / 模型。
function yueyi:showApiFieldDialog(key, title, hint)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = self:getSetting(key, ""),
        input_hint = hint,
        buttons = {{
            {
                text = "取消",
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = "保存",
                is_enter_default = true,
                callback = function()
                    local value = dialog:getInputText()
                    if value then self:saveSetting(key, value) end
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- 选择内置提示词风格（书籍翻译）。
function yueyi:buildPromptStyleMenu()
    local items = {}
    for __, preset in ipairs(Providers.bookPromptPresets) do
        local pid, pname = preset.id, preset.name
        table.insert(items, {
            text = pname,
            radio = true,
            checked_func = function() return self:getApiPromptStyle() == pid end,
            callback = function()
                self:saveSetting("api_prompt_style", pid)
            end,
        })
    end
    return items
end

-- 计时器：优先用 LuaSocket 的毫秒时钟，取不到就退回 os.time（秒级）。
function yueyi:getClock()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.gettime then return socket.gettime end
    return function() return os.time() end
end

-- 每批合并段数（2 / 4 / 6 / 8 / 12）。
function yueyi:buildBatchSizeMenu()
    local items = {}
    for __, n in ipairs({ 2, 4, 6, 8, 12 }) do
        local value = n
        table.insert(items, {
            text = tostring(value) .. " 段",
            radio = true,
            checked_func = function()
                return (tonumber(self:getSetting("api_batch_size", 6)) or 6) == value
            end,
            callback = function()
                self:saveSetting("api_batch_size", value)
                -- 字节上限跟着段数走，避免大批次把输出顶到长度上限。
                self:saveSetting("api_batch_bytes", 600 * value)
            end,
        })
    end
    return items
end

-- API 设置子菜单。
function yueyi:buildApiSettingsMenu()
    local items = {
        {
            text_func = function() return "API 地址：" .. self:getApiBaseUrl() end,
            callback = function()
                self:showApiFieldDialog("api_base_url", "API 地址",
                    "如 https://api.openai.com/v1 或 https://api.deepseek.com/v1")
            end,
        },
        {
            text_func = function()
                local k = self:getApiKey()
                if k == "" then return "API Key：（未设置）" end
                if #k <= 8 then return "API Key：已设置" end
                return "API Key：" .. k:sub(1, 4) .. "****" .. k:sub(-4)
            end,
            callback = function()
                self:showApiFieldDialog("api_key", "API Key",
                    "你的 API 密钥（明文保存在本机 settings 中，请注意设备安全）")
            end,
        },
        {
            text_func = function() return "模型名称：" .. self:getApiModel() end,
            callback = function()
                self:showApiFieldDialog("api_model", "模型名称",
                    "如 gpt-4o-mini / deepseek-chat / qwen-max")
            end,
        },
        {
            text_func = function()
                local p = Providers.getPromptPreset(self:getApiPromptStyle())
                return "提示词风格：" .. p.name
            end,
            sub_item_table_func = function() return self:buildPromptStyleMenu() end,
        },
        {
            -- 推理型模型（GLM-4.5 / DeepSeek-R1 / Qwen3-Thinking 等）每段都要先"思考"
            -- 再输出，逐段翻译会慢到不可用。开启后自动识别推理型模型并发送关闭参数；
            -- 非推理模型（DeepSeek-V3.2、Qwen3.5-Instruct 等）不会多传任何字段。
            text = "关闭模型推理（大幅提速）",
            checkbox = true,
            checked_func = function() return self:getSetting("api_disable_thinking", true) == true end,
            callback = function(menu)
                self:saveSetting("api_disable_thinking",
                    not (self:getSetting("api_disable_thinking", true) == true))
                if menu and menu.updateItems then menu:updateItems() end
            end,
        },
        {
            -- 合并多段为一次请求：翻译整本书的耗时 ≈ 段落数 × 单次往返耗时，
            -- 合并后请求次数降到 1/N，是目前最有效的提速手段。
            text = "批量合并翻译（大幅提速）",
            checkbox = true,
            checked_func = function() return self:getSetting("api_batch_enabled", true) == true end,
            callback = function(menu)
                self:saveSetting("api_batch_enabled",
                    not (self:getSetting("api_batch_enabled", true) == true))
                if menu and menu.updateItems then menu:updateItems() end
            end,
        },
        {
            -- 每批合并几段。越大越快，但过大可能触发输出长度上限或让模型漏段。
            text_func = function()
                -- 直接读设置：main.lua 单独加载时（如菜单测试）不依赖 reader 的方法。
                local n = tonumber(self:getSetting("api_batch_size", 6)) or 6
                return string.format("每批合并段数：%d", n)
            end,
            sub_item_table_func = function() return self:buildBatchSizeMenu() end,
        },
        {
            text = "术语表一致性（跨章统一译名）",
            checked_func = function() return self:isGlossaryEnabled() end,
            callback = function(menu) self:toggleGlossaryEnabled(menu) end,
        },
        {
            -- 诊断用：确认设备上跑的确实是新版插件（提示词含专有名词硬规则），
            -- 并核对术语表抽到了多少条。译文改不动时先看这里。
            text = "查看当前提示词与术语表（诊断）",
            callback = function()
                local preset = Providers.getPromptPreset(self:getApiPromptStyle())
                local has_rule = preset.system:find("专有名词", 1, true) ~= nil
                local glossary = ""
                local book = self.ui and self.ui.document and self.ui.document.file
                if book then glossary = self:loadGlossaryText(book) end
                local terms = 0
                if glossary ~= "" then
                    for _ in glossary:gmatch("[^\r\n]+") do terms = terms + 1 end
                end
                local head = glossary ~= "" and glossary:sub(1, 120) or "（无）"
                TranslationUI.showInfo(string.format(
                    "风格：%s\n专有名词规则：%s\n术语表：%d 条\n术语示例：%s\n\n提示词开头：\n%s",
                    preset.name,
                    has_rule and "已生效" or "未生效（插件未更新！）",
                    terms, head, preset.system:sub(1, 150)))
            end,
        },
        {
            text_func = function()
                local book = self.ui and self.ui.document and self.ui.document.file
                if not book then return "清除术语表（需先打开一本书）" end
                return "清除术语表（本书）"
            end,
            callback = function()
                local book = self.ui and self.ui.document and self.ui.document.file
                if not book then
                    TranslationUI.showInfo("请先打开要操作的 EPUB 书籍。")
                    return
                end
                self:clearGlossary(book)
                TranslationUI.showInfo("已清除本书术语表，下次翻译本书时将自动重新抽取。")
            end,
        },
        {
            text = "测试 API 连接",
            callback = function()
                local gettime = self:getClock()
                local t0 = gettime()
                local ok, res = pcall(function()
                    return Providers.translate_custom_api("Hello, world.", "auto", self:getTargetLang())
                end)
                local elapsed = gettime() - t0
                if ok and res and res.translated_text then
                    TranslationUI.showInfo(string.format("连接成功（耗时 %.1fs）：\n%s",
                        elapsed, res.translated_text))
                else
                    local msg = (not ok) and tostring(res) or (res and res.message or "未知错误")
                    TranslationUI.showInfo(string.format("连接失败（耗时 %.1fs）：\n%s", elapsed, msg))
                end
            end,
        },
        {
            -- 直接量出「一次请求翻 6 段」的耗时：整本书耗时 ≈ 段数/6 × 这个数。
            text = "测速：一次翻译 6 段",
            callback = function()
                local gettime = self:getClock()
                local sample = {}
                for i = 1, 6 do
                    sample[i] = string.format(
                        "This is sample sentence number %d, used only to measure translation speed.", i)
                end
                local t0 = gettime()
                local ok, res, err = pcall(Providers.translate_batch_custom_api,
                    Providers, sample, "auto", self:getTargetLang(), "")
                local elapsed = gettime() - t0
                if ok and res then
                    TranslationUI.showInfo(string.format(
                        "批量 6 段成功，耗时 %.1fs\n首段译文：%s", elapsed, res[1] or ""))
                else
                    local msg = (not ok) and tostring(res) or (err and err.message or "未知错误")
                    TranslationUI.showInfo(string.format(
                        "批量失败（耗时 %.1fs）：%s\n翻译时会自动回退逐段，不影响出结果。",
                        elapsed, tostring(msg)))
                end
            end,
        },
        {
            -- 排错用：直接列出账号下真实可用的模型 id。
            -- 同一模型常有免费档 / Pro 档两套 id（硅基流动是 Pro/ 前缀），
            -- 名字写错时接口只会回一句含糊的报错。
            text = "获取可用模型列表（排错用）",
            callback = function()
                local ok, list, err = pcall(Providers.fetch_models)
                if not ok or not list then
                    local msg = (not ok) and tostring(list)
                        or (err and err.message or "未知错误")
                    TranslationUI.showInfo("获取失败：\n" .. tostring(msg))
                    return
                end
                -- 优先显示与当前填写的模型同族的条目，避免上千行看不完。
                local current = self:getApiModel() or ""
                local family = current:match("([%w%.%-]+)$") or ""
                local keyword = family:lower()
                local preferred = {}
                for _, id in ipairs(list) do
                    if keyword ~= "" and id:lower():find(keyword, 1, true) then
                        preferred[#preferred + 1] = id
                    end
                end
                local shown = (#preferred > 0) and preferred or list
                local lines = {}
                local maxn = math.min(#shown, 40)
                for i = 1, maxn do lines[i] = shown[i] end
                local text = string.format("账号可用模型共 %d 个，以下显示 %d 个：\n\n%s",
                    #list, maxn, table.concat(lines, "\n"))
                if #shown > maxn then
                    text = text .. string.format("\n\n（还有 %d 个未显示）", #shown - maxn)
                end
                self:showTextPanel("可用模型", text)
            end,
        },
    }
    return items
end

-- 长文本面板：优先用可滚动的 TextViewer，取不到就退回普通提示框。
function yueyi:showTextPanel(title, text)
    local ok, TextViewer = pcall(require, "ui/widget/textviewer")
    if ok and TextViewer then
        UIManager:show(TextViewer:new{ title = title, text = text })
        return
    end
    TranslationUI.showInfo(text)
end

function yueyi:addToMainMenu(menu_items)
    -- Single top-level entry. The enable/disable checkbox lives as the first
    -- item of the submenu (see buildMenuTable) so it can be toggled by a
    -- plain tap; KOReader would otherwise swallow taps on any item that also
    -- carries a sub_item_table and the checkbox would be display-only.
    menu_items.yueyi = {
        text = _("月译"),
        sorting_hint = "tools",
        sub_item_table = self:buildMenuTable(),
    }
end

function yueyi:buildMenuTable()
    local menu = {
        {
            text = _("检查更新…"),
            callback = function() Updater.checkForUpdate() end,
        },
        -- Master switch as a plain tap-to-toggle checkbox inside the submenu.
        {
            text = "启用插件",
            checkbox = true,
            checked_func = function() return self:isPluginEnabled() end,
            callback = function(menu) self:togglePluginEnabled(menu) end,
        },
        {
            text = "翻译本书",
            enabled_func = function()
                return self:isEpub() and not self:isLegacyBilingualEpub(self.ui.document.file)
            end,
            callback = function()
                self:translateBook(true)
            end,
        },
        {
            -- "逐章模式" preference.  Checked: tapping "翻译本书" starts from
            -- the current chapter and follows the reading position (page
            -- turns silently translate newly reached chapters).  Unchecked:
            -- "翻译本书" translates the whole book.
            text_func = function()
                return self:isPageTranslationEnabled() and "逐章模式（从当前章开始）" or "逐章模式"
            end,
            checkbox = true,
            checked_func = function() return self:isPageTranslationEnabled() end,
            enabled_func = function()
                return self:isEpub() and not self:isLegacyBilingualEpub(self.ui.document.file)
            end,
            callback = function(menu) self:togglePageTranslation(menu) end,
        },
        {
            -- Queue as a native sub-menu: items expand inline instead of
            -- popping a separate window.
            text_func = function()
                local active, queued = self:queueStats()
                if active + queued == 0 then return "翻译队列（空）" end
                return string.format("翻译队列（进行中%d，排队%d）", active, queued)
            end,
            enabled_func = function()
                local active, queued = self:queueStats()
                return active + queued > 0
            end,
            sub_item_table_func = function()
                return self:buildTranslationQueueMenu()
            end,
        },
        {
            -- 译文可见性开关：勾选 = 在正文中显示译文（不勾 = 隐藏）。
            text = "显示译文",
            checked_func = function()
                local path = self.ui and self.ui.document and self.ui.document.file
                return path and self:hasTranslationOverlay(path)
                    and self:getSetting("translation_visible", true) == true or false
            end,
            enabled_func = function()
                local path = self.ui and self.ui.document and self.ui.document.file
                return self:isEpub() and self:hasTranslationOverlay(path)
            end,
            callback = function() self:toggleTranslationVisible() end,
        },
        -- Provider / Mode selector
        {
            text_func = function()
                return "翻译服务：" .. Providers.getProviderName(self:getMode())
            end,
            sub_item_table = self:buildProviderSelector(),
        },
        -- 自定义 API（OpenAI 兼容）设置：仅当翻译服务选为"自定义 API"时生效。
        {
            text = "API 接入设置",
            sub_item_table_func = function()
                return self:buildApiSettingsMenu()
            end,
        },
        -- Language settings: plain sub-menus with radio items (the same
        -- structure the translator_switch plugin uses), no pop-up dialog.
        {
            text_func = function()
                local sl = self:getSourceLang()
                local name = sl == "auto" and "自动识别" or Languages.getNameByCode(sl)
                return "源语言：" .. name
            end,
            sub_item_table = self:buildLanguageMenu("source"),
        },
        {
            text_func = function()
                return "目标语言：" .. Languages.getNameByCode(self:getTargetLang())
            end,
            sub_item_table = self:buildLanguageMenu("target"),
        },
        {
            text_func = function()
                return "译文字号：" .. self:getInlineFontSize()
            end,
            callback = function() self:showInlineFontSpin() end,
        },
        {
            text_func = function()
                return "译文字体：" .. self:getInlineFontFamilyLabel()
            end,
            sub_item_table_func = function()
                return self:buildFontFamilyMenu()
            end,
        },
        {
            -- 彩色译文开关：彩屏设备开启以用色相区分译文与原文；黑白屏关闭，
            -- 选了彩色也会回退中性灰，避免灰阶下看不清。
            text = "彩色译文（仅彩屏）",
            checkbox = true,
            checked_func = function() return self:isColorTranslationEnabled() end,
            callback = function(menu) self:toggleColorTranslation(menu) end,
        },
        self:inlineStyleMenu("inline_color", "译文颜色…", {
            { value = "#e6e6e6", label = "10% 灰" },
            { value = "#cccccc", label = "20% 灰" },
            { value = "#b3b3b3", label = "30% 灰" },
            { value = "#999999", label = "40% 灰" },
            { value = "#808080", label = "50% 灰" },
            { value = "#666666", label = "60% 灰" },
            { value = "#4d4d4d", label = "70% 灰" },
            { value = "#333333", label = "80% 灰" },
            { value = "#1a1a1a", label = "90% 灰" },
            -- 彩色：在彩屏设备上用色相把译文与黑色原文明显区分开。
            { value = "#1a3a8f", label = "深蓝（彩屏）" },
        }),
        {
            -- 换模型 / 改提示词后用：让每段都重新请求翻译服务，不读已有译文缓存。
            text = "强制重翻（忽略已有译文）",
            checkbox = true,
            checked_func = function() return self:isCacheBypassEnabled() end,
            callback = function(menu) self:toggleCacheBypass(menu) end,
        },
        {
            -- 翻译卡住（进度长时间不动、清除被拒绝）时的救急项：
            -- 停止进行中的任务并清空队列，之后可以重新翻译或清除译文。
            text = "停止并重置翻译任务",
            callback = function()
                if self.resetTranslationQueue then
                    self:resetTranslationQueue()
                end
                TranslationUI.showInfo("已停止翻译任务并重置队列。")
            end,
        },
        {
            text = "清除本书译文",
            enabled_func = function()
                return self:isEpub()
            end,
            callback = function()
                self:confirmClearCache()
            end,
        },
    }

    return menu
end

function yueyi:buildProviderSelector()
    local items = {}
    for i, provider in ipairs(Providers.list) do
        -- Lua 5.1: loop variables are shared by every closure created inside
        -- the loop.  Capture the per-iteration values (id and name) so each
        -- row shows its own provider and toggles its own mode.
        local pid, pname = provider.id, provider.name

        table.insert(items, {
            text_func = function()
                return pname
            end,
            checked_func = function()
                return self:getMode() == pid
            end,
            radio = true,
            callback = function()
                self:saveSetting("mode", pid)
                TranslationUI.showInfo(T(_("Provider: %1"), pname))
            end,
        })
    end
    return items
end

------------------------------------------------------------------------
-- Language sub-menus (source / target)
------------------------------------------------------------------------
-- Generic radio sub-menu like translator_switch's genLanguagesMenu: no
-- pop-up dialog, selection is applied immediately, and the parent menu item
-- reflects the new value on the next rebuild.
function yueyi:buildLanguageMenu(which)
    local items = {}

    if which == "source" then
        table.insert(items, {
            text = "自动识别 (auto)",
            radio = true,
            checked_func = function() return self:getSourceLang() == "auto" end,
            callback = function()
                self:saveSetting("source_lang", "auto")
            end,
        })
    end

    local is_target = which == "target"
    for __, lang in ipairs(Languages.list) do
        -- Lua 5.1: capture the per-iteration values; otherwise every row's
        -- closures would use the last language in the list.
        local code, name = lang.code, lang.name
        table.insert(items, {
            text = string.format("%s (%s)", _(name), code),
            radio = true,
            checked_func = function()
                local current = is_target and self:getTargetLang() or self:getSourceLang()
                return current == code
            end,
            callback = function()
                self:saveSetting(is_target and "target_lang" or "source_lang", code)
            end,
        })
    end
    return items
end

------------------------------------------------------------------------
-- Clear cache
------------------------------------------------------------------------
function yueyi:confirmClearCache()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        -- ButtonDialog has no separate info field; the body text lives in
        -- the title (TextBoxWidget, wraps).
        title = "清除本书译文\n彻底删除当前书的全部译文数据？原 EPUB 不会被修改。",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Clear"),
                    callback = function()
                        local book_path = self.ui and self.ui.document and self.ui.document.file
                        if not self:clearTranslationQueueForBook(book_path) then
                            -- 有任务卡在 active 状态（例如卡在网络请求上）时，
                            -- 直接拒绝会让这本书永远清不掉、重翻永远命中旧译文。
                            -- 先强制停止任务，再继续清除。
                            if self.resetTranslationQueue then
                                pcall(function() self:resetTranslationQueue() end)
                            end
                            pcall(function()
                                self:clearTranslationQueueForBook(book_path)
                            end)
                        end
                        -- removeTranslationFilesForBook 的第二个返回值是本书的缓存
                        -- *目录* 路径，不是书籍文件路径。缓存表的 book_path 列存的是
                        -- 书籍文件路径，误传目录会让 DELETE 匹配 0 行、缓存整份残留，
                        -- 重新翻译时每段都命中旧译文（改提示词 / 换模型后看起来像没生效）。
                        local before = self.cache:countForBook(book_path)
                        local removed = self:removeTranslationFilesForBook(book_path)
                        self.cache:clearForBook(book_path)
                        local after = self.cache:countForBook(book_path)
                        -- 目录已被删除，术语表文件随之消失；同步清掉内存缓存，
                        -- 否则下次翻译会直接用内存里的旧术语表而不重新抽取。
                        self:clearGlossary(book_path)
                        self:saveSetting("translation_visible", false)
                        -- Stop follow-mode after a clear: the page-turn
                        -- scheduler must not immediately re-translate the
                        -- chapter the user just wiped.
                        self._page_translation_follow_active = nil
                        self._page_translation_last_fragment = nil
                        self._page_translation_overlay_state = nil
                        self._chapter_index_cache = nil
                        UIManager:close(dialog)
                        if self.ui and self.ui.document then
                            self.ui.document._yueyi_extra_css = nil
                        end
                        self:refreshDocumentStyles()
                        -- 报告缓存条数变化，便于确认缓存确实被清掉
                        -- （旧版本曾因误传目录路径导致一条都没删）。
                        TranslationUI.showInfo(string.format(
                            "已清除本书译文\n缓存记录 %d → %d 条%s",
                            before, after,
                            (removed > 0) and "，译文文件已删除" or ""))
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function yueyi:onCloseDocument()
    -- Follow-mode session state is per book: closing the book must not let
    -- the next opened book inherit an armed follow session (which would
    -- auto-translate it on the first page turn).
    self._page_translation_overlay_state = nil
    self._page_translation_follow_active = nil
    self._page_translation_last_fragment = nil
    self._chapter_index_cache = nil
    self._style_refresh_scheduled = nil
    self.cache:close()
end

function yueyi:onReaderReady()
    UIManager:nextTick(function()
        self:refreshDocumentStyles()
    end)
end

-- Restore the saved translation layer while CREngine is still loading its
-- document settings. Applying the same CSS after ReaderReady makes the built
-- DOM stale and triggers KOReader's full-reload prompt; at this stage it is
-- part of the initial render and appears immediately without a toggle cycle.
function yueyi:onReadSettings()
    local path = self.ui and self.ui.document and self.ui.document.file
    if path and self:hasTranslationOverlay(path)
        and self:getSetting("translation_visible", true) == true then
        self:refreshDocumentStyles(true)
    end
end

function yueyi:onPageUpdate()
    if self.maybeSchedulePageTranslation then
        -- Auto-continue for chapter-by-chapter translation shows the same
        -- progress dialog as a manual start, so the user can watch the
        -- newly reached chapter being translated.
        self:maybeSchedulePageTranslation(false)
    end
end

function yueyi:onPosUpdate()
    if self.maybeSchedulePageTranslation then
        self:maybeSchedulePageTranslation(false)
    end
end

function yueyi:onDocumentRerendered()
    if self.maybeSchedulePageTranslation then
        self:maybeSchedulePageTranslation(false)
    end
end

yueyi.onDocumentPartiallyRerendered = yueyi.onDocumentRerendered

return yueyi

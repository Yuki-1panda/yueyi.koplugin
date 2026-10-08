-- The small, keyless provider core used by 月译.
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local socketutil = require("socketutil")
local _ = require("gettext")

local Providers = {}

Providers.list = {
    { id = "system", name = "KOReader 内置翻译（跟随系统设置）", requires_api_key = false,
      description = _("Use KOReader's built-in translator engine (configured in KOReader -> Translation)") },
    { id = "microsoft_free", name = "Microsoft Edge（免费）", requires_api_key = false,
      description = _("Microsoft Edge web endpoint (no API key)") },
    { id = "custom_api", name = "自定义 API（OpenAI 兼容）", requires_api_key = true,
      description = _("使用你自己的 OpenAI 兼容大模型 API（OpenAI / DeepSeek / 通义千问 / 本地 Ollama 等）翻译书籍") },
}

-- 读取自定义 API 相关配置（base_url / key / model / 提示词风格）。
-- 必须在任何引用它的函数（术语表抽取、翻译）之前定义，因为其作用域覆盖整个文件。
local function getApiSetting(key, default)
    if not G_reader_settings then return default end
    local value = G_reader_settings:readSetting("yueyi_" .. key)
    if value == nil or value == "" then return default end
    return value
end

-- 统一的 HTTP POST 辅助：阻塞请求 OpenAI 兼容的 chat/completions（或 Edge 端点）。
-- 必须在任何引用它的函数（翻译、术语表抽取）之前定义，作用域覆盖整个文件。
local function httpRequest(method, url, body, headers)
    local response_body = {}
    headers = headers or {}
    headers["Accept"] = headers["Accept"] or "application/json"
    if body and not headers["Content-Length"] then
        headers["Content-Length"] = tostring(#body)
    end
    socketutil:set_timeout(15, 15)
    local code, resp_headers, status = http.request{
        url = url, method = method, headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(response_body),
    }
    socketutil:reset_timeout()
    local raw = table.concat(response_body)
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" then
        logger.warn("yueyi: provider HTTP error", code, status, raw:sub(1, 160))
        return nil, { code = code,
            message = (not code or code == 1)
                and "翻译服务连接失败，请检查网络"
                or string.format("翻译服务返回 HTTP %s：%s", tostring(code), raw:sub(1, 120)) }
    end

    -- 提取平台给的真实错误原因。注意各家格式不同：
    --   OpenAI 风格：{"error": {"message": "..."}}
    --   国产平台（硅基流动等）：{"code":20012,"message":"Model does not exist.","data":null}
    --     —— 没有 error 字段，且 HTTP 状态可能是 400 / 403 / 429。
    -- 以前只认 data.error，国产平台的报错会被吞掉，界面上只剩一句"连接失败"，
    -- 用户根本看不到是模型名错了、没实名还是欠费。
    local api_message
    if type(data.error) == "table" then
        api_message = data.error.message
    elseif type(data.error) == "string" then
        api_message = data.error
    end
    local status_num = tonumber(code) or tonumber(status)
    if not api_message and data.message and not data.choices then
        api_message = data.message
    end
    if api_message and (not data.choices or (status_num and status_num >= 400)) then
        local prefix = (status_num and status_num >= 400)
            and string.format("HTTP %d：", status_num) or ""
        return nil, { code = code, message = prefix .. tostring(api_message) }
    end
    if status_num and status_num >= 400 then
        return nil, { code = code, message = string.format("HTTP %d：%s",
            status_num, raw:sub(1, 160)) }
    end
    return data
end

-- ---------------------------------------------------------------------------
-- 内置提示词（书籍翻译）。用户可在 API 设置中选择风格；系统提示词引导
-- 大模型以更贴合书籍 / 长文的方式翻译（保留语气、风格、格式，只输出译文）。
-- 如需自定义，可在此新增条目或在界面外直接改 yueyi_api_prompt_style。
-- ---------------------------------------------------------------------------
-- 专有名词硬规则（三种风格共用）：杜绝「卒塔婆（そとば）」被音译成
-- "sotoba" 这类假名转罗马音的问题——必须用目标语言通行译名。
Providers.NOUN_RULE = "专有名词的处理（必须遵守）：人名、地名、宗教、民俗、器物等专有名词，一律使用目标语言中通行的译名或约定俗成的写法；原文中的汉字词优先按汉字含义与该词在目标语言中的通行译法翻译，绝不要把假名注音转写成罗马音，也不要把罗马音、原文假名或外文残留在译文中。例如日语「卒塔婆（そとば）」必须译为「卒塔婆」，而不是 sotoba。确实没有通行译名时，按词义意译，保持译文自然可读。"

-- 用户侧再强调一次的短句。system 里的规则有时会被忽略，专有名词音译就是这么踩的坑，
-- 破折号同理，所以在 user 侧也压一句（很短，几乎不增加 token）。
Providers.USER_STYLE_HINT = "专有名词一律用中文通行译名，不要音译成罗马音；" ..
    "不要添加原文没有的标点或符号（尤其不要新增破折号——）。"

-- 标点 / 符号硬规则（三种风格共用）：大模型在翻日语、英语时普遍爱「自作主张」加破折号
-- （把补充说明、插入语用 —— 连起来），原文没有的绝对不能出现。
Providers.PUNCT_RULE = "标点与符号的处理（必须遵守）：严格沿用原文的标点体系，只在语言转换确实需要时做等价替换（例如日文的「」改为中文引号、句末标点改为中文标点）。除这类等价替换外，严禁添加任何原文中并不存在的符号——尤其是破折号、连接号（——、—、-）和省略号（……），也不要自行添加感叹号、问号、括号或冒号。判断标准很简单：原文没有破折号的地方，译文里绝对不许出现破折号；只有原文确实使用了破折号时才予以保留。同理，不要为了补充解释而自行插入原文没有的语句。"

Providers.bookPromptPresets = {
    { id = "general", name = "通用翻译",
      system = "你是一名专业翻译。请将用户提供的文本准确、流畅地翻译成目标语言，保持原意、语气与格式（含换行与标点）。" .. Providers.NOUN_RULE .. Providers.PUNCT_RULE .. "只输出译文，不要任何解释、注释或额外内容。" },
    { id = "literary", name = "文学 / 小说",
      system = "你是一名经验丰富的文学翻译家。请在准确传达原意的基础上，注重译文的可读性与文学美感，保留原文的叙事节奏、人物语气与风格，避免逐字死译与生硬表达。" .. Providers.NOUN_RULE .. Providers.PUNCT_RULE .. "只输出译文本身，不要解释或注释。" },
    { id = "academic", name = "学术 / 技术",
      system = "你是一名严谨的学术与技术文档翻译。请确保术语准确、表达专业、逻辑清晰，并保留原有的段落结构与编号。" .. Providers.NOUN_RULE .. Providers.PUNCT_RULE .. "只输出译文，不要解释或注释。" },
}

function Providers.getPromptPreset(id)
    for _, preset in ipairs(Providers.bookPromptPresets) do
        if preset.id == id then return preset end
    end
    return Providers.bookPromptPresets[1]
end

-- ---------------------------------------------------------------------------
-- 术语表（glossary）一致性支持。
-- 逐段翻译时每段都是无状态请求，模型对前文译名没有记忆，因此同一专有名词
-- 在不同段落可能译法不一。为解决跨章 / 跨段一致性，翻译整本书前先抽取一份
-- 「原文 → 中文译名」术语表，之后每段翻译时把它拼进系统提示词强制沿用。
-- 抽取与注入仅对 custom_api 生效（其它后端不接受 system 提示词）。
-- ---------------------------------------------------------------------------

-- 术语抽取提示词：让模型从原文片段中识别人名 / 地名 / 专有名词并给出标准译名，
-- 每行一条，格式为「原文=中文译名」，便于后续直接拼入翻译提示词。
Providers.GLOSSARY_EXTRACT_SYSTEM = "你是翻译术语提取助手。以下是待翻译书籍的若干原文片段。" ..
    "请识别其中的人名、地名、组织机构名，以及重要专有名词（如特殊物品、称号、宗教或民俗词汇等），" ..
    "并给出它们在目标语言中的标准译名。每行输出一条，格式为：原文=中文译名（例如 田中=田中）。" ..
    "只输出术语行，不要序号，不要解释或任何额外内容。"

-- 把抽取到的术语表拼进翻译 system 提示词时使用的引导语。
Providers.GLOSSARY_INJECT_PREFIX = "【全书术语统一】下面给出的术语必须在译文中严格沿用其指定中文译名，" ..
    "不得改用其它译法，也不得将汉字词转写为罗马音或假名。若原文出现的词不在表中，再按常规翻译："

-- 将模型返回的术语文本规整为「原文=译名」行，去除序号与空白，并按上限截断。
-- 返回可直接拼入提示词的纯文本（每行一条），无有效条目时返回空串。
function Providers.normalize_glossary(content)
    if not content or content == "" then return "" end
    local lines = {}
    local limit = 300
    -- 支持的译名分隔符（半角与全角、箭头、波浪号均兼容）。
    -- 用 plain find 逐字符定位，避免 Lua 模式按字节处理多字节字符时出错。
    local seps = { "=", "＝", "→", "〜", "~", ":", "：" }
    for raw_line in content:gmatch("[^\r\n]+") do
        local line = raw_line:match("^%s*(.-)%s*$")
        if line ~= "" then
            -- 去掉可能的序号前缀，如 "1. "、"1、"、"1) "、"- "、"• "。
            line = line:gsub("^%d+%s*[%.、%)%]】]%s*", "")
            line = line:gsub("^[%-•·*]%s*", "")
            -- 找出最靠前的分隔符。
            local sep, pos
            for _, sc in ipairs(seps) do
                local p = line:find(sc, 1, true)
                if p and (not pos or p < pos) then sep = sc; pos = p end
            end
            if sep then
                local src = line:sub(1, pos - 1)
                local tgt = line:sub(pos + #sep)
                src = src:match("^%s*(.-)%s*$")
                tgt = tgt:match("^%s*(.-)%s*$")
                if src ~= "" and tgt ~= "" then
                    lines[#lines + 1] = src .. "=" .. tgt
                end
            end
        end
        if #lines >= limit then break end
    end
    return table.concat(lines, "\n")
end

-- 只保留「当前段落原文里真实出现过」的术语。
-- 整份术语表可能有上百条，若无条件注入每一段请求，每段 prompt 会膨胀十几倍，
-- 既浪费 token 又会触发 API 的每分钟 token 限流（表现为翻译进度长时间停滞）。
-- 一致性不受影响：一条术语只需要约束它真正出现的那些段落。
-- 用 plain find（第四参 true）做字节级匹配，避免多字节字符被 Lua 模式按字节切开。
function Providers.filter_glossary(glossary_text, text)
    if not glossary_text or glossary_text == "" then return "" end
    if not text or text == "" then return "" end
    local kept = {}
    local limit = 40
    for line in glossary_text:gmatch("[^\r\n]+") do
        local src = line:match("^(.-)=")
        if src and src ~= "" and text:find(src, 1, true) then
            kept[#kept + 1] = line
            if #kept >= limit then break end
        end
    end
    return table.concat(kept, "\n")
end

-- 根据若干原文片段抽取术语表（纯文本，每行「原文=译名」）。
-- 失败或无有效条目时返回 nil（调用方应静默降级，不阻断翻译）。
function Providers.extract_glossary(sample_text)
    if not sample_text or sample_text == "" then return nil end
    local base_url = getApiSetting("api_base_url", "https://api.openai.com/v1")
    local api_key = getApiSetting("api_key", "")
    if not api_key or api_key == "" then return nil end
    base_url = base_url:gsub("/+$", "")
    local url = base_url .. "/chat/completions"

    local payload = {
        model = getApiSetting("api_model", "gpt-4o-mini"),
        messages = {
            { role = "system", content = Providers.GLOSSARY_EXTRACT_SYSTEM },
            { role = "user", content = "待翻译书籍原文片段：\n\n" .. sample_text },
        },
        temperature = 0.2,
    }

    local body = json.encode(payload)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
    }
    local data, err = httpRequest("POST", url, body, headers)
    if not data then return nil end
    local choice = data.choices and data.choices[1]
    local content = choice and choice.message and choice.message.content
    if not content or content == "" then return nil end
    local normalized = Providers.normalize_glossary(content)
    if normalized == "" then return nil end
    return normalized
end

-- ---------------------------------------------------------------------------
-- KOReader built-in translator (frontend/ui/translator.lua).
-- Uses whatever engine the user picked in KOReader -> Translation settings
-- (the built-in only ships Google, but users may point trans_server at a
-- mirror/custom endpoint).  It exposes single-text translate() only, so the
-- batch path below loops over it.
-- ---------------------------------------------------------------------------
local function getSystemTranslator()
    local ok, Translator = pcall(require, "ui/translator")
    if ok and Translator then return Translator end
    return nil
end

-- Map 月译's BCP-47 codes onto the codes the built-in translator
-- expects (its SUPPORTED_LANGUAGES table uses "zh"/"zh-TW"; Google accepts
-- the plain forms too).  Anything unknown passes through untouched.
local function normalizeLangForSystem(lang)
    if lang == "zh-Hans" then return "zh" end
    if lang == "zh-Hant" then return "zh-TW" end
    return lang
end

function Providers.translate_system(text, source_lang, target_lang)
    local Translator = getSystemTranslator()
    if not Translator then
        return nil, { message = _("KOReader 内置翻译器不可用（ui/translator 加载失败）") }
    end
    -- The built-in translator manages its own target/source language from
    -- G_reader_settings.  We still forward explicit langs when provided, so
    -- 月译's per-book settings win when set.
    local ok, translated = pcall(Translator.translate, Translator, text,
        normalizeLangForSystem(target_lang), normalizeLangForSystem(source_lang))
    if not ok or not translated or translated == "" then
        logger.warn("yueyi: system translator failed:", translated)
        return nil, { message = _("KOReader 内置翻译失败，请检查 KOReader 翻译设置与网络") }
    end
    return { translated_text = translated, source_lang = source_lang,
        target_lang = target_lang, provider = "system" }
end

-- Batch loop over the built-in translator.  The built-in translator exposes
-- only a single-text translate(), so system mode always loops one request per
-- paragraph; it never uses a native batch endpoint.  (The separately
-- selectable Microsoft Edge provider has its own native batch path.)
function Providers.translate_system_batch(texts, source_lang, target_lang)
    local result = {}
    for i, text in ipairs(texts) do
        local translated, err = Providers.translate_system(text, source_lang, target_lang)
        if not translated then
            return nil, err
        end
        result[i] = translated.translated_text
    end
    return result
end

local function urlEncode(value)
    return require("socket.url").escape(tostring(value or ""))
end

local function jsonPost(url, payload)
    return httpRequest("POST", url, json.encode(payload), {
        ["Content-Type"] = "application/json",
    })
end

function Providers.translate_microsoft_free(text, source_lang, target_lang)
    local url = "https://edge.microsoft.com/translate/translatetext?isEnterpriseClient=false&to="
        .. urlEncode(target_lang)
    if source_lang and source_lang ~= "auto" then
        url = url .. "&from=" .. urlEncode(source_lang)
    end
    local data, err = jsonPost(url, { text })
    if not data then return nil, err end
    if data[1] and data[1].translations and data[1].translations[1] then
        return { translated_text = data[1].translations[1].text,
            source_lang = source_lang, target_lang = target_lang,
            provider = "microsoft_free" }
    end
    return nil, { message = _("Microsoft Edge returned no translation") }
end

function Providers.translate_microsoft_free_batch(texts, source_lang, target_lang)
    local url = "https://edge.microsoft.com/translate/translatetext?isEnterpriseClient=false&to="
        .. urlEncode(target_lang)
    if source_lang and source_lang ~= "auto" then
        url = url .. "&from=" .. urlEncode(source_lang)
    end
    local data, err = jsonPost(url, texts)
    if not data then return nil, err end
    local result = {}
    for index, item in ipairs(data) do
        if not item.translations or not item.translations[1]
            or not item.translations[1].text then
            return nil, { message = _("Microsoft Edge returned an incomplete batch") }
        end
        result[index] = item.translations[1].text
    end
    if #result ~= #texts then
        return nil, { message = _("Microsoft Edge returned an incomplete batch") }
    end
    return result
end

-- ---------------------------------------------------------------------------
-- 自定义 API（OpenAI 兼容的 /v1/chat/completions）。
-- 配置（API 地址 / Key / 模型 / 提示词风格）直接读取 G_reader_settings，
-- 与插件其它设置共用 yueyi_ 前缀，避免额外序列化。
-- ---------------------------------------------------------------------------
local function languageName(code)
    local ok, Languages = pcall(require, "yueyi_languages")
    if ok and Languages and Languages.getNameByCode then
        local name = Languages.getNameByCode(code)
        if name and name ~= "" then return name end
    end
    return code or ""
end

-- 中文字形约束：只说「简体中文」这个名称时，部分模型仍会输出繁体。
-- 按目标语言代码给出硬性字形要求，并同时写入 system 与 user 两侧。
function Providers.scriptHint(code)
    local c = tostring(code or ""):lower()
    if c == "zh-hans" or c == "zh-cn" or c == "zh-hans-cn" or c == "zh" then
        return "必须输出简体中文（Simplified Chinese）：全文使用简体字形，严禁出现任何繁体字或异体字。"
    elseif c == "zh-hant" or c == "zh-tw" or c == "zh-hk" or c == "zh-hant-tw"
        or c == "zh-hant-hk" or c == "zh-mo" then
        return "必须输出繁體中文（Traditional Chinese）：全文使用繁體字形。"
    end
    return ""
end

-- 按输入字节数保守估算输出 token 上限。字节数换算到 token 是粗估（中日文 3 字节/字、
-- 英文 1 字节/字），宁可高估也不能低估——低估会直接把译文截断。封顶 8192。
local function estimateMaxTokens(total_bytes, count)
    local est = math.ceil(total_bytes / 1.2) + 128 * (count or 1)
    if est < 512 then est = 512 end
    if est > 8192 then est = 8192 end
    return est
end

-- 判断模型是否属于「推理型 / 思考型」。命中才会发送关闭推理的参数；
-- 未命中的非推理模型（DeepSeek-V3.x、Qwen3.5-Instruct、Ling-flash 等）不发任何额外字段。
-- 识别规则按小写模型名匹配，未收录的新推理模型可在菜单里手动关掉推理开关后仍由本函数兜底。
function Providers.isReasoningModel(model)
    local m = string.lower(model or "")
    if m == "" then return false end
    -- 明确非推理 / 视觉但不思考的：提前排除，避免被下面的宽松规则误伤
    if m:find("glm%-4%.5v") then return false end
    if m:find("deepseek%-v3") and not m:find("r1") then return false end
    local patterns = {
        "r1",                       -- DeepSeek-R1 / R1 系
        "reasoner",                 -- deepseek-reasoner
        "thinking",                 -- Qwen3-*-Thinking / 带 Thinking 后缀
        "qwq",                      -- QwQ 推理模型
        "glm%-4%.5",                -- GLM-4.5（Air 等）默认思考
        "glm%-4%.6", "glm%-z1",     -- 智谱其他推理系
        -- DeepSeek-V4 系列（Flash / Pro）：思维模式**默认开启且默认 high 档**，
        -- 不显式关闭的话每段都要先想一遍，翻译会慢到不可用。
        -- 别名 deepseek-flash / deepseek-pro 同样命中。
        "deepseek%-v4", "v4%-flash", "v4%-pro", "deepseek%-flash",
    }
    for _, p in ipairs(patterns) do
        if m:find(p) then return true end
    end
    -- OpenAI 推理系（o1 / o3 / o4-mini）：只在开头或路径分隔后出现时才算命中，
    -- 避免误伤名称中间含 "o1"/"o3" 的普通模型。
    for _, p in ipairs({ "^o1", "/o1", "^o3", "/o3", "^o4%-mini", "/o4%-mini" }) do
        if m:find(p) then return true end
    end
    return false
end

-- 各模型族「关闭思考」所需的下发字段。
-- 关键：DeepSeek-V4 系列一旦同时收到 thinking=disabled 与 reasoning_effort，
-- 接口会直接报 "thinking options type cannot be disabled when reasoning_effort is set"，
-- 所以这里按族返回，绝不同时下发两者；且 V4 的 reasoning_effort 只有 high/max 两档
-- （low 会被归一到 high），调低档位没用，只能整体关掉思维模式。
function Providers.reasoningOffParams(model)
    local m = string.lower(model or "")
    if m:find("deepseek") and (m:find("v4") or m:find("flash") or m:find("pro")) then
        return { thinking = { type = "disabled" } }
    end
    if m:find("kimi") or m:find("moonshot") then
        return { thinking = { type = "disabled" } }
    end
    if m:find("qwen") or m:find("qwq") then
        return { enable_thinking = false, thinking_budget = 0 }
    end
    if m:find("glm") or m:find("zhipu") then
        return { thinking = { type = "disabled" }, thinking_budget = 0 }
    end
    -- 兜底：OpenAI 兼容接口里最通用的一字段写法；不认识的接口会直接忽略。
    return { thinking = { type = "disabled" } }
end

function Providers.translate_custom_api(text, source_lang, target_lang, glossary_text)
    local base_url = getApiSetting("api_base_url", "https://api.openai.com/v1")
    local api_key = getApiSetting("api_key", "")
    local model = getApiSetting("api_model", "gpt-4o-mini")
    local prompt_style = getApiSetting("api_prompt_style", "general")

    if not api_key or api_key == "" then
        return nil, { message = _("请先在 月译 → API 设置中填写 API Key") }
    end

    base_url = base_url:gsub("/+$", "")
    local url = base_url .. "/chat/completions"

    local preset = Providers.getPromptPreset(prompt_style)
    local target_name = languageName(target_lang)
    local script_hint = Providers.scriptHint(target_lang)
    -- 专有名词要求在 system 与 user 两侧同时强调：只写在 system 里时，
    -- 部分模型仍会把「卒塔婆（そとば）」这类词音译成罗马音。
    local user_content = string.format(
        "请将以下文本翻译成%s。%s%s\n\n%s",
        target_name, script_hint, Providers.USER_STYLE_HINT, text)

    -- 跨章 / 跨段一致性：只把本段真实出现的术语拼进系统提示词，强制沿用已定译名。
    -- 未命中任何术语时不追加引导语，保持请求体积接近无术语表时的水平。
    local system = preset.system
    if script_hint ~= "" then system = system .. "\n" .. script_hint end
    local relevant = Providers.filter_glossary(glossary_text, text)
    if relevant ~= "" then
        system = system .. "\n\n" .. Providers.GLOSSARY_INJECT_PREFIX .. "\n" .. relevant
    end

    local payload = {
        model = model,
        messages = {
            { role = "system", content = system },
            { role = "user", content = user_content },
        },
        -- 偏低温度：同一专有名词在不同段落更可能得到完全一致的译名。
        temperature = 0.2,
        -- 显式限制输出长度：既省时间，也杜绝模型在译文前后加解释、加"译文："之类的废话。
        max_tokens = estimateMaxTokens(#text, 1),
    }
    -- 推理型模型（GLM-4.5 / DeepSeek-R1 / Qwen3-Thinking 等）默认会先生成大段
    -- 思考再输出译文，单段等待可达数十秒，逐段翻译会慢到不可用。这里显式关闭推理。
    -- 只对识别为「推理型」的模型发送这些字段：DeepSeek-V3.2 / Qwen3.5-Instruct
    -- 这类非推理模型本来就不思考，多发字段反而可能被严格校验的接口判为非法参数。
    if getApiSetting("api_disable_thinking", true) == true
        and Providers.isReasoningModel(model) then
        for k, v in pairs(Providers.reasoningOffParams(model)) do
            payload[k] = v
        end
    end

    local body = json.encode(payload)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
    }

    local data, err = httpRequest("POST", url, body, headers)
    if not data then return nil, err end

    local choice = data.choices and data.choices[1]
    local content = choice and choice.message and choice.message.content
    if not content or content == "" then
        return nil, { message = _("自定义 API 未返回译文（请检查模型与提示词设置）") }
    end
    content = content:match("^%s*(.-)%s*$")

    return { translated_text = content, source_lang = source_lang,
        target_lang = target_lang, provider = "custom_api" }
end

-- ---------------------------------------------------------------------------
-- 批量合并翻译（提速的关键）。
-- custom_api 原本是「一段一次 HTTP 请求」：整本书的网络往返次数 = 段落数，一本 200 段的
-- 书就是 200 次 TLS 握手 + 排队 + 生成，单次 2~3 秒也会累计成十几分钟，换更快的模型
-- 只能按比例减，改不了"次数"这个因子。这里把连续若干段合成一次请求，用 <<<序号>>>
-- 标记分隔，往返次数降到 1/6 ~ 1/12；附带好处是相邻段落同处一个上下文，译名更一致。
-- 模型不按格式输出时返回 nil，调用方自动回退逐段翻译，不会损坏结果。
-- ---------------------------------------------------------------------------

-- 组装批量请求的用户提示词：每段原文前加 <<<i>>> 标记，要求译文按同样标记分行输出。
function Providers.buildBatchPrompt(texts, target_name, script_hint)
    local parts = {}
    for i, text in ipairs(texts) do
        parts[#parts + 1] = string.format("<<<%d>>>\n%s", i, text)
    end
    local header = string.format(
        "请将下面 %d 段文本分别翻译成%s。必须严格保持段落数量与顺序：每一段译文都以单独" ..
        "一行的 <<<序号>>> 标记开头（如 <<<1>>>、<<<2>>>），序号与原文一一对应；不要合并、" ..
        "拆分或省略任何一段，也不要输出解释、前言或总结。%s%s\n\n",
        #texts, target_name, script_hint, Providers.USER_STYLE_HINT)
    return header .. table.concat(parts, "\n\n")
end

-- 解析批量译文：按 <<<i>>> 标记切分，返回长度为 count 的数组。
-- 任一段缺失或为空即返回 nil（判定为格式不合规，交给调用方回退）。
function Providers.splitBatchTranslation(content, count)
    if not content or content == "" or not count or count < 1 then return nil end
    local marks, pos = {}, 1
    while true do
        local s, e, num = content:find("<<<(%d+)>>>", pos)
        if not s then break end
        marks[#marks + 1] = { num = tonumber(num), s = s, e = e }
        pos = e + 1
    end
    if #marks == 0 then return nil end
    local found = {}
    for i, mark in ipairs(marks) do
        local stop = marks[i + 1] and (marks[i + 1].s - 1) or #content
        local seg = content:sub(mark.e + 1, stop)
        seg = seg:match("^%s*(.-)%s*$")
        if found[mark.num] == nil then found[mark.num] = seg end
    end
    local out = {}
    for i = 1, count do
        if not found[i] or found[i] == "" then return nil end
        out[i] = found[i]
    end
    return out
end

-- 一次请求翻译多段。返回译文数组（与 texts 一一对应）或 nil + 错误。
function Providers.translate_batch_custom_api(texts, source_lang, target_lang, glossary_text)
    if not texts or #texts == 0 then return {}, nil end
    -- 单段没有合并收益，直接走单段路径（也避免多余的格式解析风险）。
    if #texts == 1 then
        local res, err = Providers.translate_custom_api(texts[1], source_lang,
            target_lang, glossary_text)
        if not res then return nil, err end
        return { res.translated_text }, nil
    end

    local base_url = getApiSetting("api_base_url", "https://api.openai.com/v1")
    local api_key = getApiSetting("api_key", "")
    local model = getApiSetting("api_model", "gpt-4o-mini")
    local prompt_style = getApiSetting("api_prompt_style", "general")
    if not api_key or api_key == "" then
        return nil, { message = _("请先在 月译 → API 设置中填写 API Key") }
    end
    base_url = base_url:gsub("/+$", "")
    local url = base_url .. "/chat/completions"

    local preset = Providers.getPromptPreset(prompt_style)
    local target_name = languageName(target_lang)
    local script_hint = Providers.scriptHint(target_lang)

    local system = preset.system
    if script_hint ~= "" then system = system .. "\n" .. script_hint end
    -- 术语过滤按整批拼接后的文本做：命中本批任意一段的术语都会被带上。
    local joined = table.concat(texts, "\n")
    local relevant = Providers.filter_glossary(glossary_text, joined)
    if relevant ~= "" then
        system = system .. "\n\n" .. Providers.GLOSSARY_INJECT_PREFIX .. "\n" .. relevant
    end

    local payload = {
        model = model,
        messages = {
            { role = "system", content = system },
            { role = "user", content = Providers.buildBatchPrompt(texts, target_name, script_hint) },
        },
        temperature = 0.2,
        max_tokens = estimateMaxTokens(#joined, #texts),
    }
    if getApiSetting("api_disable_thinking", true) == true
        and Providers.isReasoningModel(model) then
        for k, v in pairs(Providers.reasoningOffParams(model)) do
            payload[k] = v
        end
    end

    local body = json.encode(payload)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
    }
    local data, err = httpRequest("POST", url, body, headers)
    if not data then return nil, err end

    local choice = data.choices and data.choices[1]
    local content = choice and choice.message and choice.message.content
    if not content or content == "" then
        return nil, { message = _("自定义 API 未返回译文（请检查模型与提示词设置）") }
    end
    local results = Providers.splitBatchTranslation(content, #texts)
    if not results then
        return nil, { message = _("批量译文格式不符，已回退逐段翻译") }
    end
    return results, nil
end

-- 拉取当前账号可用的模型列表（GET {base_url}/models），排错用。
-- 很多平台同一模型分「免费档 / Pro 档」两套 id（硅基流动就是 Pro/ 前缀），
-- 模型名写错时代码里只会看到一句含糊的报错，直接列出可用 id 最快。
function Providers.fetch_models()
    local base_url = getApiSetting("api_base_url", "")
    local api_key = getApiSetting("api_key", "")
    if base_url == "" then return nil, { message = _("请先填写 API 地址") } end
    if api_key == "" then return nil, { message = _("请先填写 API Key") } end
    base_url = base_url:gsub("/+$", "")
    local data, err = httpRequest("GET", base_url .. "/models", nil,
        { ["Authorization"] = "Bearer " .. api_key })
    if not data then return nil, err end
    local list = {}
    local source = type(data.data) == "table" and data.data or data.models
    if type(source) == "table" then
        for _, item in ipairs(source) do
            if type(item) == "table" and item.id then
                list[#list + 1] = tostring(item.id)
            elseif type(item) == "string" then
                list[#list + 1] = item
            end
        end
    end
    if #list == 0 then
        return nil, { message = _("接口没有返回模型列表，请到平台控制台核对模型名") }
    end
    table.sort(list)
    return list
end

function Providers.translate(provider_id, text, source_lang, target_lang, glossary_text)
    if provider_id == "system" then
        return Providers.translate_system(text, source_lang, target_lang)
    elseif provider_id == "microsoft_free" then
        return Providers.translate_microsoft_free(text, source_lang, target_lang)
    elseif provider_id == "custom_api" then
        return Providers.translate_custom_api(text, source_lang, target_lang, glossary_text)
    end
    return nil, { message = "未知翻译服务，请选择 KOReader 内置、Microsoft Edge 或自定义 API" }
end

function Providers.getProviderById(id)
    for _, provider in ipairs(Providers.list) do
        if provider.id == id then return provider end
    end
end

function Providers.getProviderName(id)
    local provider = Providers.getProviderById(id)
    return provider and provider.name or "未知翻译服务"
end

function Providers.isProviderEnabled(id)
    return Providers.getProviderById(id) ~= nil
end

return Providers

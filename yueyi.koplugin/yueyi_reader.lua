-- Reader-facing translation, EPUB mapping, and styling operations.
-- Menu, persistence, and provider implementations live in separate modules.
local Notification = require("ui/widget/notification")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local logger = require("logger")
local _ = require("gettext")
local util = require("util")
local Trapper = require("ui/trapper")
local DataStorage = require("datastorage")
local Cache = require("yueyi_cache")
local Providers = require("yueyi_providers")
local Overlay = require("yueyi_overlay")
local Tools = require("yueyi_tools")

local Reader = {}

function Reader.attach(plugin)
    local yueyi = plugin

function yueyi:splitTranslationText(text, limit)
    if #text <= limit then return { text } end
    local chunks = {}
    local rest = text
    -- Rewind a split point to the last byte boundary: when cut lands inside
    -- a multi-byte UTF-8 character, back up to the character's start byte
    -- and then one more byte, so neither chunk ends nor the next chunk
    -- begins with a dangling continuation byte.
    local function to_char_boundary(cut)
        while cut > 1 do
            local byte = rest:byte(cut)
            if not byte or byte < 128 or byte > 191 then
                if byte and byte >= 192 then cut = cut - 1 end
                break
            end
            cut = cut - 1
        end
        return cut
    end
    while #rest > limit do
        local cut = limit
        local search_from = math.max(1, limit - 160)
        -- Prefer whitespace or sentence punctuation near the limit, so that
        -- English words and sentences are not cut in the middle.
        for i = limit, search_from, -1 do
            local character = rest:sub(i, i)
            if character:match("[%s%.,;:%?!]" ) then
                cut = i
                break
            end
        end
        -- If there is no whitespace (for example, a CJK paragraph), avoid
        -- splitting in the middle of a UTF-8 byte sequence.
        cut = to_char_boundary(cut)
        local part = util.trim(rest:sub(1, cut))
        if part == "" then
            cut = to_char_boundary(limit)
            part = rest:sub(1, cut)
        end
        table.insert(chunks, part)
        rest = util.trim(rest:sub(cut + 1))
    end
    if rest ~= "" then table.insert(chunks, rest) end
    return chunks
end

-- 批量合并（custom_api）：默认开启，可在 API 设置里关掉。
function yueyi:isBatchEnabled()
    return self:getSetting("api_batch_enabled", true) == true
end

-- 一次请求合并多少段。段数越多越快，但太长会触发输出长度上限或让模型丢段。
function yueyi:getBatchSize()
    local n = tonumber(self:getSetting("api_batch_size", 6))
    if not n or n < 2 then return 6 end
    return n
end

-- 单批原文的字节上限，与 getBatchSize 共同决定分组。
function yueyi:getBatchByteLimit()
    local n = tonumber(self:getSetting("api_batch_bytes", 3000))
    if not n or n < 500 then return 3000 end
    return n
end

-- custom_api 的批量翻译主流程：查缓存 → 分组 → 一次请求翻一批 → 写缓存 → 报进度。
-- 任一批解析失败就回退成逐段翻译，结果不会因为提速而缺失。
function yueyi:translateBatchForCustomApi(texts, on_progress)
    local mode = self:getMode()
    local source_lang = self:getSourceLang()
    local target_lang = self:getTargetLang()
    local limit = self:getTranslationChunkLimit()
    local max_items = self:getBatchSize()
    local max_bytes = self:getBatchByteLimit()

    local glossary_text = ""
    if self:isGlossaryEnabled() then
        glossary_text = self:loadGlossaryText(self._active_translation_book)
    end

    local results, first_error, pending = {}, nil, {}
    for index, text in ipairs(texts) do
        -- 超长段落本来就要拆分，交给单段路径处理（它会递归分片）。
        if #text > limit then
            local translated, err = self:translateTextForEpub(text)
            if translated then
                results[index] = translated
            else
                results[index] = false
                first_error = first_error or err
            end
            if on_progress then pcall(on_progress) end
        else
            local cached = self:cacheLookupForBook(text)
            if cached and cached.translated_text then
                results[index] = cached.translated_text
                if on_progress then pcall(on_progress) end
            else
                table.insert(pending, { index = index, text = text })
            end
        end
    end

    local start = 1
    while start <= #pending do
        local group, group_texts, group_index = {}, {}, {}
        local bytes = 0
        while start <= #pending and #group < max_items do
            local item = pending[start]
            if #group > 0 and bytes + #item.text > max_bytes then break end
            table.insert(group, item)
            table.insert(group_texts, item.text)
            table.insert(group_index, item.index)
            bytes = bytes + #item.text
            start = start + 1
        end

        local ok, translated_list, err = pcall(Providers.translate_batch_custom_api,
            Providers, group_texts, source_lang, target_lang, glossary_text)

        if ok and translated_list and #translated_list == #group_texts then
            for i = 1, #group_texts do
                results[group_index[i]] = translated_list[i]
                if self:isCacheEnabled() then
                    self.cache:storeForBook(self._active_translation_book, source_lang,
                        target_lang, group_texts[i], translated_list[i], mode)
                end
            end
        else
            -- 合并失败（网络错误 / 模型不按标记输出）→ 这一批退回逐段，保底出结果。
            if not ok and type(translated_list) == "string" then
                err = { message = translated_list }
            end
            for i = 1, #group_texts do
                local translated, single_err = self:translateTextForEpub(group_texts[i])
                if translated then
                    results[group_index[i]] = translated
                else
                    results[group_index[i]] = false
                    first_error = first_error or single_err or err
                end
            end
        end
        -- 进度按段上报：一批 6 段只在结束时跳 6 格，看起来才像在推进。
        if on_progress then
            for _ = 1, #group_texts do pcall(on_progress) end
        end
    end

    return results, first_error
end

-- Whole-book translation uses 月译's provider registry directly and
-- stores the result in a non-destructive per-book overlay cache.
function yueyi:translateTextForEpub(text)
    local mode = self:getMode()
    local source_lang = self:getSourceLang()
    local target_lang = self:getTargetLang()
    local result, err

    -- 跨章一致性：custom_api 且开启术语表时，载入本书术语表注入翻译请求。
    local glossary_text = ""
    if mode == "custom_api" and self:isGlossaryEnabled() then
        glossary_text = self:loadGlossaryText(self._active_translation_book)
    end

    local cached = self:cacheLookupForBook(text)
    if cached and cached.translated_text then
        return cached.translated_text, nil
    end

    if mode == "default" then
        return nil, { message = "请先选择 月译 翻译服务" }
    end

    -- Keep long paragraphs below the selected provider's request limit.  The
    -- recursive calls use the same v19 one-paragraph request path, while the
    -- final result remains one continuous translation in the EPUB.
    local limit = self:getTranslationChunkLimit()
    if #text > limit then
        local translated_parts = {}
        for _, chunk in ipairs(self:splitTranslationText(text, limit)) do
            local translated, chunk_err = self:translateTextForEpub(chunk)
            if not translated then return nil, chunk_err end
            table.insert(translated_parts, translated)
        end
        local combined = table.concat(translated_parts, " ")
        if self:isCacheEnabled() then
            self.cache:storeForBook(self._active_translation_book, source_lang,
                target_lang, text, combined, mode)
        end
        return combined, nil
    end

    -- Keep the v19 request path: one paragraph, one provider request.
    -- The newer chunk/batch path was slower on-device and could turn one
    -- failed request into a failed EPUB generation.
    result, err = Providers.translate(mode, text, source_lang, target_lang, glossary_text)

    if result and result.translated_text and result.translated_text ~= "" then
        if self:isCacheEnabled() then
            self.cache:storeForBook(self._active_translation_book, source_lang,
                target_lang, text, result.translated_text, result.provider or mode)
        end
        return result.translated_text, nil
    end
    return nil, err or { message = "翻译服务没有返回译文" }
end

function yueyi:isEpub()
    return self.ui and self.ui.document and self.ui.document.file
        and self.ui.document.file:lower():match("%.epub$") ~= nil
end

function yueyi:isLegacyBilingualEpub(path)
    return path and path:lower():match("_bilingual_[^/]-%.epub$") ~= nil
end

function yueyi:getBookCacheDirectory(book_path)
    local data_dir = require("datastorage"):getDataDir()
    return data_dir .. "/cache/yueyi/books/"
        .. Tools.stable_path_hash(book_path .. "|" .. self:getTargetLang())
end

function yueyi:getTranslationOverlayPath(book_path)
    if not book_path then return nil end
    return self:getBookCacheDirectory(book_path) .. "/overlay.json"
end

function yueyi:hasTranslationOverlay(book_path)
    if not book_path then return false end
    local path = self:getTranslationOverlayPath(book_path)
    return path and Overlay.exists(path) or false
end

-- ---------------------------------------------------------------------------
-- 术语表（glossary）一致性：翻译整本书前抽取一份「原文 → 中文译名」对照，之后
-- 每段翻译都强制沿用，解决逐段无状态调用导致的跨章译名不一致问题。
-- ---------------------------------------------------------------------------
function yueyi:getGlossaryPath(book_path)
    if not book_path then return nil end
    return self:getBookCacheDirectory(book_path) .. "/glossary.json"
end

-- 读取本书术语表文本（每行「原文=译名」）。结果按 book_path 缓存在 self 上。
function yueyi:loadGlossaryText(book_path)
    if not book_path then return "" end
    if self._glossary_cache_book == book_path and self._glossary_cache_loaded then
        return self._glossary_cache_text or ""
    end
    local text = ""
    local path = self:getGlossaryPath(book_path)
    if path then
        local f = io.open(path, "rb")
        if f then
            local raw = f:read("*a")
            f:close()
            local ok, data = pcall(function() return require("json").decode(raw) end)
            if ok and data and data.raw then text = data.raw end
        end
    end
    self._glossary_cache_book = book_path
    self._glossary_cache_loaded = true
    self._glossary_cache_text = text
    return text
end

-- 清除本书术语表文件与缓存，下次翻译时自动重建。
function yueyi:clearGlossary(book_path)
    local path = self:getGlossaryPath(book_path)
    if path then pcall(os.remove, path) end
    if self._glossary_cache_book == book_path then
        self._glossary_cache_loaded = false
        self._glossary_cache_text = nil
    end
end

-- 仅在 custom_api 模式、术语表开关开启、且本书尚无术语表时，依据取样原文
-- 抽取术语表并写入 book 缓存目录。任何失败都静默降级，绝不阻断翻译流程。
function yueyi:maybeBuildGlossary(book_path, sample_text)
    if not book_path then return end
    if not self:isGlossaryEnabled() then return end
    if self:getMode() ~= "custom_api" then return end
    local path = self:getGlossaryPath(book_path)
    if path then
        local f = io.open(path, "rb")
        if f then f:close(); return end  -- 已存在，跳过
    end
    local extracted = Providers.extract_glossary(sample_text)
    if not extracted or extracted == "" then return end
    local ok, json_str = pcall(function()
        return require("json").encode({ raw = extracted, updated_at = os.time() })
    end)
    if ok and path then
        local dir = self:getBookCacheDirectory(book_path)
        Tools.mkdir_p(dir)
        local wf = io.open(path, "wb")
        if wf then wf:write(json_str); wf:close() end
    end
    self._glossary_cache_book = book_path
    self._glossary_cache_loaded = true
    self._glossary_cache_text = extracted
end

function yueyi:isGlossaryEnabled()
    return self:getSetting("glossary_enabled", true) == true
end

function yueyi:toggleGlossaryEnabled(menu)
    self:saveSetting("glossary_enabled", not self:isGlossaryEnabled())
    if menu and menu.updateItems then menu:updateItems() end
end

function yueyi:toggleTranslationVisible()
    local current = self.ui and self.ui.document and self.ui.document.file
    if not current or not self:hasTranslationOverlay(current) then return end
    self:saveSetting("translation_visible",
        self:getSetting("translation_visible", true) ~= true)
    self:refreshDocumentStyles()
end

function yueyi:toggleColorTranslation(menu)
    local enabled = not self:isColorTranslationEnabled()
    self:saveSetting("inline_color_enabled", enabled)
    self:refreshDocumentStyles()
    if menu and menu.updateItems then menu:updateItems() end
end

-- Remove every artifact this plugin owns for a book: the per-book overlay
-- cache directories (overlay.json + any legacy files), across every target
-- language the book has been translated into.  Restrict deletion to the exact
-- 月译 books root.
function yueyi:removeTranslationFilesForBook(book_path)
    if not book_path then return 0 end
    local lfs = require("libs/libkoreader-lfs")
    local data_dir = DataStorage:getDataDir()
    local books_root = data_dir .. "/cache/yueyi/books/"
    local removed = 0
    local cleared_dir
    -- 1) Fast path: the directory for the *current* target language.  This
    -- also catches legacy overlays that carry no book metadata.
    local current_dir = self:getBookCacheDirectory(book_path)
    local current_overlay = Overlay.load(current_dir .. "/overlay.json")
    if current_overlay and current_overlay.book_path == book_path then
        removed = removed + 1
    end
    if current_dir:sub(1, #books_root) == books_root
        and #current_dir > #books_root then
        if Tools.rmtree(current_dir) then cleared_dir = current_dir end
    end
    -- 2) Sweep every other language directory whose overlay belongs to this
    -- same book (metadata written since v1.2.11).  Otherwise, if the target
    -- language was changed after a finished whole-book run, the old-language
    -- overlay would survive a "clear" and later trip stale "already done"
    -- checks or resurrect old translations.
    local ok, iterator, state = pcall(lfs.dir, books_root)
    if ok and iterator then
        for name in iterator, state do
            if name ~= "." and name ~= ".." then
                local dir = books_root .. name
                if dir ~= current_dir then
                    local overlay = Overlay.load(dir .. "/overlay.json")
                    if overlay and overlay.book_path == book_path then
                        removed = removed + 1
                        Tools.rmtree(dir)
                    end
                end
            end
        end
    end
    return removed, cleared_dir or book_path
end

-- Best-effort detection of the current spine chapter index.  CREngine
-- xpointers serialize as "/body/DocFragment/body/..." without a fragment
-- index, so Epub.resolve cannot locate the current chapter from a raw
-- xpointer (it would silently fall back to chapter 1).  Probe each
-- DocFragment's first page instead: the current chapter is the last one
-- whose first page is at or before the current page.  Falls back to nil when
-- the probes are unsupported so callers keep their previous behaviour.
--
-- Probing every fragment on every page turn (a 200-chapter book = 200
-- getPageFromXPointer calls per turn) is wasteful.  The spine is monotonic:
-- chapter N+1 starts at or after chapter N.  Cache the last result and probe
-- incrementally from there — page turns forward only probe a handful of
-- chapters, page turns back probe backwards from the cached position, and
-- only a large jump degrades to a full scan (bounded at 4096, far beyond any
-- realistic EPUB spine; a probe returns "not exists" past the real end).
function yueyi:currentChapterIndex()
    local document = self.ui and self.ui.document
    if not document
        or not document.isXPointerInDocument
        or not document.getPageFromXPointer
        or not document.getCurrentPage then
        return nil
    end
    local current_page = document:getCurrentPage()
    if not current_page then return nil end
    local cache = self._chapter_index_cache
    if cache and cache.page == current_page then return cache.index end
    local function probe(index)
        local xp = "/body/DocFragment[" .. tostring(index) .. "]/body"
        local ok_in, in_doc = pcall(function()
            return document:isXPointerInDocument(xp)
        end)
        -- Returns page, exists: an empty spine item (in the document but with
        -- no layout, page <= 0) is "exists but no page" and must be skipped
        -- by the scan rather than treated as the end of the spine; only a
        -- missing fragment terminates the scan.
        if not ok_in or not in_doc then return nil, false end
        local ok_page, page = pcall(function()
            return document:getPageFromXPointer(xp)
        end)
        if not ok_page or not page then return nil, false end
        if page <= 0 then return nil, true end
        return page, true
    end
    local best
    local start = (cache and cache.index) or 1
    -- Forward scan from the cached position (page turned forward).
    local index = start
    while index <= 4096 do
        local page, exists = probe(index)
        if not exists then break end
        if page then
            if page <= current_page then
                best = index
            else
                break
            end
        end
        index = index + 1
    end
    -- Page turned back: the cached chapter starts after the current page.
    -- Walk backwards and take the nearest chapter that still starts before
    -- the current page.
    if not best and start > 1 then
        index = start - 1
        while index >= 1 do
            local page, exists = probe(index)
            if not exists then break end
            if page and page <= current_page then
                best = index
                break
            end
            index = index - 1
        end
    end
    if best then
        self._chapter_index_cache = { page = current_page, index = best }
    end
    return best
end

function yueyi:getCurrentFragment()
    local document = self.ui.document
    -- Prefer the resolved chapter index (a plain decimal string).  Epub.resolve
    -- accepts it directly; a raw xpointer cannot locate the chapter.
    local index = self:currentChapterIndex()
    if index then return tostring(index) end
    if not document.getXPointer then return nil end
    local ok, xpointer = pcall(function() return document:getXPointer() end)
    return ok and xpointer or nil
end

function yueyi:translateBook(all_chapters, silent, span, auto)
    if not self:isEpub() then return end
    local book_path = self.ui.document.file
    -- "翻译本书" entry (all_chapters == true) honors the 逐章模式 preference:
    -- checked -> translate the current chapter and arm follow mode (page
    -- turns keep scheduling newly reached chapters silently); unchecked ->
    -- translate the whole book.
    -- 逐章模式下"翻译本书"始终翻译当前章并武装跟随模式。这里不能再用
    -- overlay 的 complete 标记判断"本书已翻译"：章节翻译从不写 complete，
    -- 该标记只来自更早某次整书翻译，可能是换语言前的残留，清除缓存后也
    -- 可能指向已删除的语言目录，据此拒绝会让用户再也无法补翻/重翻当前章。
    if all_chapters and self:isPageTranslationEnabled() then
        all_chapters = false
        span = 1
        self._page_translation_follow_active = true
    end
    local fragment = all_chapters and nil or self:getCurrentFragment()
    if fragment then self._page_translation_last_fragment = fragment end
    self:enqueueTranslation(book_path, all_chapters, fragment, silent, span, auto)
end

function yueyi:_runTranslation(item)
    local book_path = item.book_path
    local all_chapters = item.all_chapters
    self._active_translation_book = book_path
    local fragment = item.fragment
    local data_dir = DataStorage:getDataDir()
    local progress_path = data_dir .. "/cache/yueyi/progress_"
        .. tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999)) .. ".txt"
    Tools.mkdir_p(data_dir .. "/cache/yueyi")
    self._translation_progress = {
        active = true,
        all_chapters = all_chapters,
        book_path = book_path,
        item = item,
        path = progress_path,
        started_at = os.time(),
    }
    item.progress_path = progress_path
    self:saveTranslationQueue()

    UIManager:scheduleIn(0.1, function()
        -- Only show a modal progress card when this is still the book the
        -- user started from. Queue workers for books that are no longer open
        -- stay completely in the background.
        local progress_dialog
        if not item.silent and self.ui and self.ui.document and self.ui.document.file == book_path then
            progress_dialog = ProgressbarDialog:new{
                title = all_chapters and "正在翻译整本书…" or "正在翻译当前章节…",
                subtitle = "准备中…\n点按进度条可取消，点按外部收起。",
                -- Drive the native progress bar with a fixed 0-100 scale;
                -- the real paragraph total is not known before the worker
                -- starts walking the spine.
                progress_max = 100,
                -- 官方组件每逢这个间隔就重绘一次进度条；它默认 3 秒，插件此前设成
                -- 0.5 秒，等于每半秒强制刷一次屏 → 墨水屏上整屏反复闪。
                refresh_time_seconds = 3,
                dismissable = true,
            }
        end
        self._translation_progress.dialog = progress_dialog
        -- Closing this status dialog must only hide it.  The worker keeps
        -- running and the queue can show the same dialog again later.
        if progress_dialog then
            -- 覆盖官方的 redrawProgressbar()：原实现是
            --   UIManager:setDirty(self, function() return "fast", self.dimen end)
            --   UIManager:forceRePaint()
            -- 而 ProgressbarDialog 的 self.dimen = 整个屏幕尺寸，于是每次进度变化都会
            -- 强制全屏重绘 —— 等待翻译时整屏一直闪就是这么来的。
            -- 改成：只刷对话框本体那一块，且不 forceRePaint，交给 UIManager 正常调度。
            function progress_dialog:redrawProgressbar()
                local region = (self[1] and self[1].dimen) or self.dimen
                UIManager:setDirty(self, function() return "ui", region end)
            end
            local progress_on_close = progress_dialog.onCloseWidget
            function progress_dialog:onCloseWidget()
                self._yueyi_hidden = true
                return progress_on_close(self)
            end
            -- Tap on the dialog body opens the cancel-actions dialog; tap
            -- anywhere outside hides the progress dialog as before.  The
            -- native ProgressbarDialog treats the whole screen as one tap
            -- zone, so the hit test happens here in the handler (ges.pos is
            -- the tap coordinate, self[1].dimen the dialog body's box).
            function progress_dialog:onTapClose(arg, ges)
                if ges and ges.pos and self[1] and self[1].dimen
                    and ges.pos:intersectWith(self[1].dimen) then
                    local action_dialog
                    action_dialog = ButtonDialog:new{
                        title = "翻译进行中，要取消吗？\n已翻译部分会保留，可随时重翻。",
                        buttons = {{
                            {
                                text = "返回",
                                id = "close",
                                callback = function() UIManager:close(action_dialog) end,
                            },
                            {
                                text = "取消翻译",
                                is_enter_default = true,
                                callback = function()
                                    UIManager:close(action_dialog)
                                    UIManager:close(progress_dialog)
                                    yueyi:cancelTranslation(item)
                                    UIManager:show(Notification:new{
                                        text = "正在停止翻译…\n（当前批次完成后停止）",
                                        timeout = 2,
                                    })
                                    UIManager:setDirty("all", "ui")
                                end,
                            },
                        }},
                    }
                    UIManager:show(action_dialog)
                    return true
                end
                -- Outside the body: keep the native hide behavior (including
                -- its home_pending handling).
                return ProgressbarDialog.onDismiss(self)
            end
            progress_dialog:show()
        end

        -- 轮询间隔 2 秒：进度数字本来就是每批（若干段）才跳一次，0.5 秒的轮询
        -- 只会带来无意义的重复刷新。数值没变化时一次都不刷屏。
        local PROGRESS_POLL_SECONDS = 2
        local progress_active = true
        local last_signature = nil
        local function update_progress()
            if not progress_active then return end
            if not progress_dialog then return end
            if progress_dialog._yueyi_hidden then return end
            local file = io.open(progress_path, "r")
            local line = file and file:read("*l") or nil
            if file then file:close() end
            if line then
                local current, total, translated, failed, chapter, chapters = line:match(
                    "^(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)$")
                current, total = tonumber(current), tonumber(total)
                if current and total then
                    translated = tonumber(translated) or 0
                    failed = tonumber(failed) or 0
                    chapter = tonumber(chapter) or 0
                    chapters = tonumber(chapters) or 0
                    item.current = current
                    item.total = total
                    item.translated = translated
                    item.failed = failed
                    -- 只有数字真的变了才动 UI：翻译等待期间绝大多数轮询都是无变化的。
                    local signature = string.format("%d|%d|%d|%d|%d|%d",
                        current, total, translated, failed, chapter, chapters)
                    if signature ~= last_signature then
                        last_signature = signature
                        local percentage = total > 0 and math.floor(current * 100 / total + 0.5) or 0
                        progress_dialog.title = string.format("%s  %d%%",
                            all_chapters and "正在翻译整本书…" or "正在翻译当前章节…", percentage)
                        progress_dialog.subtitle = string.format(
                            "段落：%d/%d\n已翻译：%d    失败：%d\n章节：%d/%d\n点按进度条可取消，点按外部收起。",
                            current, total, translated, failed, chapter, chapters)
                        pcall(function()
                            -- Update the existing TextWidgets in place instead of
                            -- rebuilding the whole dialog tree.
                            -- ProgressbarDialog:init() builds self[1] as a
                            -- FrameContainer around a VerticalGroup whose first two
                            -- children are the title and subtitle TextWidgets.
                            local frame = progress_dialog[1]
                            local group = frame and frame[1]
                            if group and group[1] and group[1].setText then
                                group[1]:setText(progress_dialog.title)
                            end
                            if group and group[2] and group[2].setText then
                                group[2]:setText(progress_dialog.subtitle)
                            end
                            progress_dialog:reportProgress(percentage)
                            -- reportProgress 内部按 refresh_time_seconds 节流，可能这次
                            -- 不刷屏；文本已经改了就得刷一次，否则标题/段数停在旧值。
                            -- 只刷对话框本体区域，不动整屏。
                            local region = (progress_dialog[1] and progress_dialog[1].dimen)
                                or progress_dialog.dimen
                            UIManager:setDirty(progress_dialog,
                                function() return "ui", region end)
                        end)
                    end
                end
            end
            UIManager:scheduleIn(PROGRESS_POLL_SECONDS, update_progress)
        end
        UIManager:scheduleIn(PROGRESS_POLL_SECONDS, update_progress)

        local resume_ok, wrapped_ok = Trapper:wrap(function()
            -- Passing a table avoids Trapper creating its default full-screen
            -- dismiss widget. Page touches remain usable and cannot cancel the
            -- background task.
            local trap_widget = {}
            -- Do not fork an already-open SQLite connection.  The child opens
            -- its own WAL connection and the reader may reopen one later.
            pcall(function() self.cache:close() end)
            local completed, result = Trapper:dismissableRunInSubprocess(function()
                -- Everything the worker touches (provider settings, language
                -- resolution, path helpers) is evaluated inside the pcall.
                -- A failure in any of them must surface as a readable error,
                -- never as a silently lost subprocess result ("无法生成本书
                -- 译文缓存" masks the real cause).
                local ok, info = pcall(function()
                    -- The EPUB engine is cached by main.lua; retry the loader
                    -- once in case init ran before self.path was available.
                    -- A missing engine must surface as a readable message,
                    -- never as an "index a boolean" crash.
                    local Epub = self.epub or self:loadEpubModule()
                    if type(Epub) ~= "table" then
                        return nil, "月译 模块加载失败：yueyi_epub.lua 缺失或损坏，请删除旧插件目录后重新安装"
                    end
                    local run_ok, run_info, run_err = pcall(Epub.translate_overlay, Epub,
                        book_path, fragment, self:getTargetLang(), self:getSourceLang(),
                        function(text)
                            return self:translateTextForEpub(text)
                        end,
                        all_chapters,
                        progress_path,
                        function(texts, on_progress)
                            return self:translateTextBatchForEpub(texts, on_progress)
                        end,
                        function(sample)
                            return self:maybeBuildGlossary(book_path, sample)
                        end,
                        self:getBookCacheDirectory(book_path),
                        item.span,
                        progress_path .. ".cancel",
                        self:isCacheBypassEnabled()
                    )
                    if not run_ok then return nil, "翻译过程异常：" .. tostring(run_info) end
                    if not run_info then return nil, run_err end
                    return run_info
                end)
                if not ok then
                    logger.warn("yueyi: translate_overlay worker error:", info)
                    return { error = tostring(info) }
                end
                return info
            end, trap_widget)

            if not completed then
                local was_hidden = progress_dialog and progress_dialog._yueyi_hidden
                progress_active = false
                self._translation_progress.active = false
                -- The cancel flag file is only meaningful while the worker is
                -- alive; drop it so a later job never sees a stale flag.
                os.remove(progress_path .. ".cancel")
                item.status = "failed"
                item.error = "翻译已中断"
                self:saveTranslationQueue()
                pcall(function() UIManager:close(progress_dialog) end)
                if was_hidden and not self._translation_retry_after_hide then
                    -- A dismissed status widget must not turn into a false
                    -- interruption.  Retry once in the background because
                    -- older KOReader builds may deliver that tap to the
                    -- subprocess trap as well.
                    self._translation_retry_after_hide = true
                    item.status = "queued"
                    item.error = nil
                    self:saveTranslationQueue()
                    UIManager:scheduleIn(0.2, function()
                        self._translation_retry_after_hide = nil
                        self:startNextQueuedTranslation()
                    end)
                elseif all_chapters then
                    -- Whole-book jobs are background jobs.  A transient
                    -- provider error or a reader restart must never cover the
                    -- page with a modal interruption message.  Keep the
                    -- resumable failed entry in the queue for an explicit
                    -- retry from the queue menu.
                    self._translation_retry_after_hide = nil
                    item.status = "queued"
                    item.error = nil
                    self:saveTranslationQueue()
                    logger.warn("yueyi: background full-book translation interrupted; queued to resume")
                    UIManager:scheduleIn(2, function() self:startNextQueuedTranslation() end)
                else
                    self._translation_retry_after_hide = nil
                    if not item.silent then
                        UIManager:show(Notification:new{ text = "翻译已中断。", timeout = 3 })
                    end
                    self:startNextQueuedTranslation()
                end
                return
            end
            if not result or not result.output then
                progress_active = false
                self._translation_progress.active = false
                -- A killed translation subprocess can return no serialized
                -- value at all (most often after a transient memory spike
                -- from a previous interrupted job). Give a whole-book job
                -- one automatic clean retry instead of turning it into a
                -- permanent false failure.
                local retry_count = tonumber(item.retry_count) or 0
                if all_chapters and retry_count < 1 then
                    item.retry_count = retry_count + 1
                    item.status = "queued"
                    item.error = nil
                    self:saveTranslationQueue()
                    pcall(function() UIManager:close(progress_dialog) end)
                    logger.warn("yueyi: full-book worker returned no result; retrying once")
                    UIManager:scheduleIn(1, function()
                        self:startNextQueuedTranslation()
                    end)
                    return
                end
                item.status = "failed"
                item.error = (result and result.error)
                    or "翻译进程未返回结果（可能内存不足或进程被终止），请查看日志后重试"
                self:saveTranslationQueue()
                pcall(function() UIManager:close(progress_dialog) end)
                if all_chapters then
                    -- Do not interrupt reading for a background full-book
                    -- failure.  The queue entry keeps the error and can be
                    -- retried later; the log is available for diagnosis.
                    logger.warn("yueyi: background full-book translation failed:", item.error)
                elseif not item.silent then
                    UIManager:show(Notification:new{
                        text = (result and result.error)
                            or "翻译进程未返回结果（可能内存不足或进程被终止）。\n请查看日志后重试。",
                        timeout = 5,
                    })
                end
                self:startNextQueuedTranslation()
                return
            end
            progress_active = false
            self._translation_progress.active = false
            if result.cancelled then
                -- The user asked the queue to cancel this job.  Keep the
                -- checkpoint already written, drop the task, and move on.
                os.remove(progress_path .. ".cancel")
                for index, queued_item in ipairs(self._translation_queue or {}) do
                    if queued_item == item then
                        table.remove(self._translation_queue, index)
                        break
                    end
                end
                self:saveTranslationQueue()
                pcall(function() UIManager:close(progress_dialog) end)
                if not item.silent then
                    UIManager:show(Notification:new{ text = "已取消翻译。", timeout = 2 })
                end
                self:startNextQueuedTranslation()
                return
            end
            local result_failed = tonumber(result.failed) or 0
            if all_chapters and result_failed > 0 then
                item.output = result.output
                item.failed = result_failed
                local partial_retry = tonumber(item.partial_retry_count) or 0
                if partial_retry < 1 then
                    item.partial_retry_count = partial_retry + 1
                    item.status = "queued"
                    item.error = "有段落翻译失败，正在自动续跑"
                    self:saveTranslationQueue()
                    pcall(function() UIManager:close(progress_dialog) end)
                    UIManager:scheduleIn(1, function()
                        self:startNextQueuedTranslation()
                    end)
                    return
                end
                item.status = "failed"
                item.error = string.format("仍有 %d 个段落未翻译，可从队列重试", result_failed)
                self:saveTranslationQueue()
                pcall(function() UIManager:close(progress_dialog) end)
                self:startNextQueuedTranslation()
                return
            end
            item.status = "done"
            item.output = result.output
            item.current = result.translated or item.current
            item.translated = result.translated or item.translated
            item.failed = result.failed or item.failed
            item.error = nil
            -- Chapter-mode follow: reaching the last spine chapter ends the
            -- session, otherwise page turns would keep re-queueing an
            -- already-complete final chapter forever.
            if not all_chapters and result.last_chapter then
                self._page_translation_follow_active = nil
            end
            self:saveTranslationQueue()
            -- Drop the finished entry from memory too; it is already
            -- excluded from disk and from the queue dialog, and keeping it
            -- would accumulate one dead entry per finished job.
            for index, queued_item in ipairs(self._translation_queue or {}) do
                if queued_item == item then
                    table.remove(self._translation_queue, index)
                    break
                end
            end
            pcall(function() UIManager:close(progress_dialog) end)
            if not item.silent and not item.auto then
                local done_text = string.format("翻译完成\n已翻译段落：%d\n失败段落：%d",
                    result.translated or 0, result.failed or 0)
                if (result.failed or 0) > 0 then
                    done_text = done_text .. "\n失败段落将在下次翻译时自动重试"
                end
                UIManager:show(Notification:new{
                    text = done_text,
                    timeout = 3,
                })
            end
            UIManager:scheduleIn(0.2, function()
                self:scheduleTranslationStyleRefresh(book_path)
                self:startNextQueuedTranslation()
            end)
        end)
        -- Trapper:wrap runs the worker in a coroutine and reports failures as
        -- resume_ok == false (coroutine error) or wrapped_ok == false (error
        -- caught by Trapper's xpcall).  On some platforms (Android in
        -- particular) a failing subprocess API would otherwise leave
        -- _translation_progress.active stuck at true, which makes every new
        -- translation queue forever without ever starting.  Recover here.
        if resume_ok == false or wrapped_ok == false then
            progress_active = false
            if self._translation_progress then
                self._translation_progress.active = false
            end
            item.status = "failed"
            item.error = "翻译进程异常退出，请查看日志后重试"
            self:saveTranslationQueue()
            pcall(function() UIManager:close(progress_dialog) end)
            logger.warn("yueyi: translation worker failed:", wrapped_ok)
            if not item.silent then
                UIManager:show(Notification:new{
                    text = "翻译进程异常退出，已从队列中移除。\n请查看日志后重试。",
                    timeout = 4,
                })
            end
            self:startNextQueuedTranslation()
        end
    end)
end

function yueyi:reopenTranslationProgress()
    local progress = self._translation_progress
    if not progress or not progress.active or not progress.dialog then return false end
    local dialog = progress.dialog
    -- Already on screen (the queue menu was merely covering it): nothing to
    -- reopen, the caller has closed the menu.
    if not dialog._yueyi_hidden then return true end
    pcall(function()
        dialog._yueyi_hidden = false
        dialog:init()
        UIManager:show(dialog)
    end)
    return true
end

function yueyi:isCacheEnabled()
    return self:getSetting("enable_cache", true)
end

-- 换模型 / 改提示词后的强制重翻开关：开启后翻译时不再读取已有译文缓存，
-- 每段必定重新请求翻译服务（新结果仍会写入缓存，方便之后关闭开关复用）。
-- 用于排查「清了译文但翻出来还是旧内容」——那几乎总是缓存命中导致的。
function yueyi:isCacheBypassEnabled()
    return self:getSetting("bypass_cache", false) == true
end

function yueyi:toggleCacheBypass(menu)
    local enabled = not self:isCacheBypassEnabled()
    self:saveSetting("bypass_cache", enabled)
    if menu and menu.updateItems then menu:updateItems() end
end

-- 强制停止进行中的翻译任务并清空队列。
-- 场景：上一次翻译卡住（例如卡在某个网络请求上）时，_translation_progress
-- 一直是 active，导致（1）新的翻译排不上、进度停在 0/0；（2）「清除本书译文」
-- 被 clearTranslationQueueForBook 拒绝，于是旧译文永远删不掉、重翻永远命中
-- 旧内容。这个方法把队列和进度文件一次性清干净。
function yueyi:resetTranslationQueue()
    local progress = self._translation_progress
    if progress and progress.active and progress.path then
        -- 写取消标记：worker 每批之间会检查它并自行退出。
        local f = io.open(progress.path .. ".cancel", "wb")
        if f then f:write("1"); f:close() end
    end
    self._translation_progress = nil
    self._active_translation_book = nil
    self._translation_queue = {}
    self._page_translation_follow_active = nil
    self._page_translation_last_fragment = nil
    if self.saveTranslationQueue then
        pcall(function() self:saveTranslationQueue() end)
    end
    -- 清掉所有残留进度 / 取消标记文件，避免下次运行读到陈旧内容。
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_ds and ok_lfs and lfs then
        local dir = DataStorage:getDataDir() .. "/cache/yueyi"
        local ok, iterator, state = pcall(lfs.dir, dir)
        if ok and iterator then
            for name in iterator, state do
                if name ~= "." and name ~= ".."
                    and name:match("^progress_") then
                    pcall(os.remove, dir .. "/" .. name)
                end
            end
        end
    end
end

-- 缓存读取的统一入口：强制重翻开关开启时一律视为未命中。
function yueyi:cacheLookupForBook(text)
    if not self:isCacheEnabled() then return nil end
    if self:isCacheBypassEnabled() then return nil end
    return self.cache:lookupForBook(self._active_translation_book,
        self:getSourceLang(), self:getTargetLang(), text)
end

function yueyi:inlineStyleMenu(key, title, choices)
    local items = {}
    for _, choice in ipairs(choices) do
        -- Lua 5.1: capture the per-iteration value; otherwise every menu
        -- entry's checked_func/callback would see the last choice.
        local value, label = choice.value, choice.label
        table.insert(items, {
            text = label,
            radio = true,
            checked_func = function() return self:getSetting(key) == value end,
            callback = function()
                self:saveSetting(key, value)
                self:refreshDocumentStyles()
            end,
        })
    end
    return {
        text = title,
        sub_item_table = items,
    }
end

-- 彩色（彩屏）色值集合。开关关闭时，若当前选中的是彩色则回退到中性灰，
-- 避免在黑白屏上把彩色当灰阶渲染得看不清。
local COLOR_TRANSLATION_VALUES = {
    ["#1a3a8f"] = true,
}

function yueyi:isColorTranslationEnabled()
    return self:getSetting("inline_color_enabled", false) == true
end

function yueyi:isColorValue(hex)
    return COLOR_TRANSLATION_VALUES[hex] == true
end

-- 计算实际生效的译文颜色：开关关闭且选中彩色时强制回退中性灰。
function yueyi:getEffectiveTranslationColor()
    local color = tostring(self:getSetting("inline_color", "#666666"))
    if not color:match("^#%x%x%x%x%x%x$") then color = "#666666" end
    if not self:isColorTranslationEnabled() and self:isColorValue(color) then
        color = "#666666"
    end
    return color
end

function yueyi:getInlineFontSize()
    local value = tostring(self:getSetting("inline_font_size", 16))
    local number = tonumber(value:match("[%d%.]+")) or 16
    if value:match("%%$") then
        number = 16 * number / 100
    elseif value:match("em$") then
        number = 16 * number
    end
    return math.floor(number + 0.5)
end

function yueyi:getInlineFontCssSize()
    -- Treat 16 as the document's 1em base, matching KOReader's numeric font
    -- setting: 20 means 125% of the body text.
    return string.format("%.4gem", self:getInlineFontSize() / 16)
end

-- Translation font family.  "" means "follow the paragraph" (no font-family
-- in the generated CSS, so the ::after node inherits the source paragraph's
-- font); anything else is a CSS font stack injected into the translation CSS.
-- Semicolons/braces are stripped so a hand-edited value can never break the
-- generated stylesheet.
function yueyi:getInlineFontFamily()
    local value = tostring(self:getSetting("inline_font_family", ""))
    return value:gsub("[;{}]", "")
end

function yueyi:getInlineFontFamilyLabel()
    local value = self:getInlineFontFamily()
    if value == "" then return "跟随段落" end
    if value == "sans-serif" then return "无衬线" end
    if value == "serif" then return "衬线" end
    if value == "monospace" then return "等宽" end
    return value
end

function yueyi:showFontFamilyDialog()
    local dialog
    dialog = InputDialog:new{
        title = "自定义译文字体",
        input = self:getInlineFontFamily(),
        input_hint = "输入 CSS 字体栈，如：Noto Serif CJK SC, serif",
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
                    if value then
                        value = value:gsub("[;{}]", "")
                        self:saveSetting("inline_font_family", value)
                        self:refreshDocumentStyles()
                    end
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function yueyi:buildFontFamilyMenu()
    local items = {
        {
            text = "跟随段落（默认）",
            radio = true,
            checked_func = function() return self:getInlineFontFamily() == "" end,
            callback = function()
                self:saveSetting("inline_font_family", "")
                self:refreshDocumentStyles()
            end,
        },
    }
    -- Use KOReader's own font registry (the same face list as the built-in
    -- font menu in 版面→字体): CREngine family names are directly usable as
    -- CSS font-family values.  A device with no CRE engine (unlikely) simply
    -- degrades to the default + custom entry.
    local ok, faces = pcall(function()
        local cre = require("document/credocument"):engineInit()
        return cre.getFontFaces()
    end)
    if ok and faces and #faces > 0 then
        local FontList = require("fontlist")
        local seen = {}
        table.sort(faces)
        for _, face in ipairs(faces) do
            -- Lua 5.1: capture the per-iteration value.
            local face_copy = face
            if not seen[face_copy] then
                seen[face_copy] = true
                local text = face_copy
                -- Prefer the localized display name when CREngine can map the
                -- face back to a font file (mirrors readerfont.lua).
                local ok_name, filename, faceindex = pcall(function()
                    return cre.getFontFaceFilenameAndFaceIndex(face_copy)
                end)
                if ok_name and filename and faceindex then
                    local localized = FontList:getLocalizedFontName(filename, faceindex)
                    if localized then text = localized end
                end
                table.insert(items, {
                    text = text,
                    radio = true,
                    checked_func = function() return self:getInlineFontFamily() == face_copy end,
                    callback = function()
                        self:saveSetting("inline_font_family", face_copy)
                        self:refreshDocumentStyles()
                    end,
                })
            end
        end
    end
    table.insert(items, {
        text = "自定义字体…",
        callback = function() self:showFontFamilyDialog() end,
    })
    return items
end

-- Microsoft Edge accepts an array of texts and returns one translation per
-- item. Batch short paragraphs to reduce network round trips while keeping
-- the original paragraph boundaries for EPUB insertion.
function yueyi:translateTextBatchForEpub(texts, on_progress)
    -- custom_api 走合并请求路径：把连续多段并进一次 HTTP 请求，往返次数降到 1/6 左右。
    if self:getMode() == "custom_api" and self:isBatchEnabled() then
        return self:translateBatchForCustomApi(texts, on_progress)
    end
    if self:getMode() ~= "microsoft_free" then
        local results = {}
        local first_error
        for index, text in ipairs(texts) do
            local translated, err = self:translateTextForEpub(text)
            if translated then
                results[index] = translated
            else
                results[index] = false
                first_error = first_error or err
            end
            -- 每完成一段就上报：custom_api 是逐段请求，一批 48 段可能要几分钟，
            -- 没有这个回调进度会一直停在批次的起点，看起来像卡死（实际在翻）。
            if on_progress then pcall(on_progress) end
        end
        return results, first_error
    end

    local results = {}
    local pending = {}
    local first_error
    local limit = self:getTranslationChunkLimit()
    for index, text in ipairs(texts) do
        if #text > limit then
            local translated, err = self:translateTextForEpub(text)
            if translated then
                results[index] = translated
            else
                results[index] = false
                first_error = first_error or err
            end
        else
            -- 缓存关闭或强制重翻开关开启时一律未命中，交给后面的请求路径。
            local cached = self:cacheLookupForBook(text)
            if cached and cached.translated_text then
                results[index] = cached.translated_text
            else
                table.insert(pending, { index = index, text = text })
            end
        end
    end

    local batch_start = 1
    while batch_start <= #pending do
        local batch, batch_texts = {}, {}
        local total_bytes = 0
        while batch_start <= #pending and #batch < 12 do
            local item = pending[batch_start]
            if #batch > 0 and total_bytes + #item.text > 4000 then break end
            table.insert(batch, item)
            table.insert(batch_texts, item.text)
            total_bytes = total_bytes + #item.text
            batch_start = batch_start + 1
        end
        local mode = self:getMode()
        local translated, err
        translated, err = Providers.translate_microsoft_free_batch(
            batch_texts, self:getSourceLang(), self:getTargetLang())
        if not translated then
            -- One immediate retry handles transient resets without falling
            -- back to a slow request for every paragraph.
            translated, err = Providers.translate_microsoft_free_batch(
                batch_texts, self:getSourceLang(), self:getTargetLang())
        end
        if not translated then
            -- A batch request can time out even though the single-text Edge
            -- endpoint is still responsive. Retry each item only after the
            -- two batch attempts failed; this keeps normal translation fast
            -- while allowing a long English book to recover from a transient
            -- batch failure instead of producing no EPUB at all.
            if err and (err.code ~= nil or err.message) then
                for _, item in ipairs(batch) do
                    local single, single_err = self:translateTextForEpub(item.text)
                    if single then
                        results[item.index] = single
                    else
                        results[item.index] = false
                        first_error = first_error or single_err or err
                    end
                end
            else
                for _, item in ipairs(batch) do results[item.index] = false end
                first_error = first_error or err or { message = "翻译服务连接失败" }
            end
        else
            for offset, item in ipairs(batch) do
                local value = translated[offset]
                if value and value ~= "" then
                    results[item.index] = value
                    if self:isCacheEnabled() then
                        self.cache:storeForBook(self._active_translation_book,
                            self:getSourceLang(), self:getTargetLang(), item.text,
                            value, mode)
                    end
                else
                    results[item.index] = false
                    first_error = first_error or { message = "翻译服务返回了空译文" }
                end
            end
        end
    end
    return results, first_error
end

-- Translation-completion style refresh, throttled: consecutive chapters that
-- finish close together are merged into a single re-render, instead of each
-- triggering a full CREngine re-layout (which shows up as a full-screen
-- flicker on e-ink devices like the Kindle).  Setting changes and manual
-- toggles still refresh immediately via refreshDocumentStyles().
function yueyi:scheduleTranslationStyleRefresh(book_path)
    if self._style_refresh_scheduled then return end
    self._style_refresh_scheduled = true
    UIManager:scheduleIn(1.5, function()
        self._style_refresh_scheduled = nil
        if self.ui and self.ui.document and self.ui.document.file == book_path then
            self:saveSetting("translation_visible", true)
            self:refreshDocumentStyles()
        end
    end)
end

-- Apply the translation layer styles (non-destructive overlay) without
-- touching the EPUB archive.  Rebuilding this CSS only changes the visible
-- layer; the reading position and the document are left alone.
function yueyi:refreshDocumentStyles()
    local document = self.ui and self.ui.document
    local typeset = self.ui and self.ui.typeset
    if not document or not typeset or not document.setStyleSheet then return false end
    local css = typeset.css or document.default_css or ""
    local tweaks = self.ui.styletweak and self.ui.styletweak:getCssText() or ""
    local color = self:getEffectiveTranslationColor()
    local font_size = self:getInlineFontCssSize()
    local font_family = self:getInlineFontFamily()
    local plugin_enabled = self:isPluginEnabled()
    local book_path = document.file
    local overlay_css = ""
    if book_path then
        -- Visibility (translation_visible + plugin_enabled) is enforced here:
        -- buildCss omits the ::after rules entirely when hidden, so the
        -- source text stays untouched and no empty layer is laid out.
        overlay_css = Overlay.buildCss(self:getTranslationOverlayPath(book_path), {
            translation_visible = plugin_enabled
                and self:getSetting("translation_visible", true) == true,
            translation_color = color,
            translation_size = font_size,
            translation_font_family = font_family,
        })
    end
    local extra_css = tweaks .. "\n" .. overlay_css
    -- Keep this marker on the document object, which survives the rerender
    -- that setStyleSheet itself initiates.  A plugin instance may be rebuilt
    -- during that rerender, so an instance-local flag cannot stop the loop.
    if document._yueyi_extra_css == extra_css then return true end
    document._yueyi_extra_css = extra_css
    local ok = pcall(function()
        document:setStyleSheet(css, extra_css)
    end)
    if not ok then
        document._yueyi_extra_css = nil
    else
        -- setStyleSheet triggers a full re-render.  The reader's pagination
        -- state (page_states in scroll mode, current_page in paging mode) is
        -- not rebuilt by that re-render, so stale page numbers can make the
        -- next page turn mis-fire EndOfBook ("end of book" dialog) while the
        -- book is still mid-way.  Re-sync the way the reader itself does
        -- after a layout change (rotation / resize): refresh the current
        -- page, recalculate the view, then rebuild the scroll page states.
        UIManager:nextTick(function()
            local ui = self.ui
            if not ui or not ui.view then return end
            pcall(function()
                local new_page = document:getCurrentPage()
                if new_page then
                    ui:handleEvent(Event:new("PageUpdate", new_page))
                end
                ui.view:recalculate()
                ui:handleEvent(Event:new("InitScrollPageStates"))
            end)
        end)
    end
    return ok
end


function yueyi:showInlineFontSpin()
    local spin
    spin = SpinWidget:new{
        title_text = "译文字号",
        info_text = "点按 - / + 调整，或点按数字直接输入（8–40）",
        value = self:getInlineFontSize(),
        value_min = 8,
        value_max = 40,
        value_step = 1,
        precision = "%d",
        callback = function()
            local size = math.floor(spin.value_widget.value + 0.5)
            size = math.max(8, math.min(40, size))
            self:saveSetting("inline_font_size", size)
            self:refreshDocumentStyles()
        end,
    }
    UIManager:show(spin)
end

end

return Reader

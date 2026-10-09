-- 月译 OTA 更新模块。
-- 原理：检查 GitHub latest release 的 tag_name，与本地 _meta.lua 版本比较；
-- 有新版本时下载对应 tag 的源码 zip（codeload.github.com，无重定向、无附件
-- 依赖），解压到临时目录，校验内含 _meta 版本一致后，把当前插件目录改名
-- 让位、新目录顶上，旧目录在下次启动时清理。全程只依赖 KOReader 自带模块。
--
-- 注意：本模块的任何代码改动都发生在"旧版本自己"的进程里，换目录动作
-- 要等 KOReader 重启后才生效——这是刻意设计，避免热替换运行中的 Lua。

local logger = require("logger")
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local https_ok, https = pcall(require, "ssl.https")
local Tools = require("yueyi_tools")

local Updater = {
    REPO_OWNER = "Yuki-1panda",
    REPO_NAME = "yueyi.koplugin",
    TIMEOUT = 30,
}

-- 本文件所在目录即插件目录（main.lua 与本文件同级加载）。
function Updater.getPluginDir()
    local src = debug.getinfo(1, "S").source
    local path = src:sub(1, 1) == "@" and src:sub(2) or src
    return path:match("^(.*)/[^/]+$")
end

-- 从 _meta.lua 文本里抠 version（不走 require，避免模块名冲突）。
function Updater.getLocalVersion()
    local f = io.open(Updater.getPluginDir() .. "/_meta.lua", "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content:match('version%s*=%s*"([^"]+)"')
end

-- 版本比较：按 数字/字母 分段，数字按数值比。返回 -1/0/1。
-- "v1.0.2" 与 "1.0.2" 视为相等；"1.0.10" > "1.0.9"。
function Updater.compareVersions(a, b)
    local function split(v)
        local parts = {}
        for tok in tostring(v):gmatch("[^%._%-vV]+") do
            parts[#parts + 1] = tok
        end
        return parts
    end
    local A, B = split(a), split(b)
    for i = 1, math.max(#A, #B) do
        local x, y = A[i], B[i]
        if x == nil then return -1 end
        if y == nil then return 1 end
        local xn, yn = tonumber(x), tonumber(y)
        if xn and yn then
            if xn ~= yn then return xn < yn and -1 or 1 end
        elseif x ~= y then
            return x < y and -1 or 1
        end
    end
    return 0
end

-- HTTPS GET，返回 body 字符串或 nil + 错误信息。手动跟随最多 5 次 30x。
function Updater.httpGet(url, headers)
    if not https_ok then
        return nil, _("缺少 ssl.https 模块（KOReader 自带，请检查安装完整性）")
    end
    for _ = 1, 5 do
        local sink_parts = {}
        local ok, code, resp_headers = pcall(https.request, {
            url = url,
            method = "GET",
            headers = headers,
            sink = ltn12.sink.table(sink_parts),
            redirect = false,
        })
        if not ok then
            return nil, _("网络请求失败（请检查设备网络后重试）")
        end
        code = tonumber(code) or 0
        local location = resp_headers and resp_headers.location or resp_headers and resp_headers["Location"]
        if code >= 300 and code < 400 and location then
            url = location
        elseif code == 200 then
            return table.concat(sink_parts)
        else
            return nil, string.format(_("GitHub 返回 HTTP %s"), tostring(code))
        end
    end
    return nil, _("重定向次数过多")
end

-- 查询最新版本：返回 tag 字符串或 nil + 错误。
function Updater.checkLatest()
    local body, err = Updater.httpGet(
        string.format("https://api.github.com/repos/%s/%s/releases/latest", Updater.REPO_OWNER, Updater.REPO_NAME),
        { ["Accept"] = "application/vnd.github+json", ["User-Agent"] = "yueyi-koplugin" })
    if not body then return nil, err end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then
        return nil, _("GitHub 响应解析失败")
    end
    if not data.tag_name then
        return nil, _("还没有任何已发布的版本")
    end
    return tostring(data.tag_name)
end

-- 递归删除目录（lfs + os.remove），用于清理临时/旧版目录。
function Updater.rmtree(path)
    local attr = lfs.attributes(path)
    if not attr then return end
    if attr.mode == "file" then
        os.remove(path)
        return
    end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            Updater.rmtree(path .. "/" .. entry)
        end
    end
    os.remove(path)
end

-- 启动清理：删掉上次更新留下的旧版目录与临时文件。
function Updater.cleanupOld()
    local dir = Updater.getPluginDir()
    local parent = dir:match("^(.*)/[^/]+$") or "."
    local base = dir:match("[^/]+$")
    for entry in lfs.dir(parent) do
        if entry ~= "." and entry ~= ".." then
            -- 旧版目录：yueyi.koplugin.old-*；未完成的下载/解压：.update-*
            if entry:match("^" .. base .. "%.old%-") or entry:match("^%..-yueyi%-update%-") then
                Updater.rmtree(parent .. "/" .. entry)
            end
        end
    end
    os.remove(parent .. "/yueyi_update.zip")
end

-- 下载并安装指定 tag 的源码 zip。返回 true 或 nil + 错误。
function Updater.downloadAndInstall(tag)
    local dir = Updater.getPluginDir()
    local parent = dir:match("^(.*)/[^/]+$") or "."
    local base = dir:match("[^/]+$")

    local zip_path = parent .. "/yueyi_update.zip"
    local tmp_dir = parent .. "/.yueyi-update-" .. tostring(os.time())

    -- 1) 下载（codeload 直连，无重定向）
    local zip_url = string.format("https://codeload.github.com/%s/%s/zip/refs/tags/%s",
        Updater.REPO_OWNER, Updater.REPO_NAME, tag)
    if not https_ok then
        return nil, _("缺少 ssl.https 模块")
    end
    -- 下载源码 zip 一般 100KB 左右，300 秒已非常宽裕。
    socketutil:set_timeout(300, 300)
    local f = io.open(zip_path, "wb")
    if not f then return nil, _("无法创建临时文件") end
    local ok, code = pcall(https.request, {
        url = zip_url,
        method = "GET",
        headers = { ["User-Agent"] = "yueyi-koplugin" },
        sink = ltn12.sink.file(f),
    })
    socketutil:reset_timeout()
    if not ok or (tonumber(code) or 0) ~= 200 then
        os.remove(zip_path)
        return nil, string.format(_("下载失败（HTTP %s），请检查网络"), tostring(code))
    end

    -- 2) 解压
    if not Tools.unzip_to(zip_path, tmp_dir) then
        Updater.rmtree(tmp_dir)
        os.remove(zip_path)
        return nil, _("解压失败")
    end

    -- 3) 定位解压出的根目录（GitHub 源码 zip 根目录带 tag 后缀），校验版本
    local new_dir, new_version
    for entry in lfs.dir(tmp_dir) do
        if entry ~= "." and entry ~= ".." then
            local mf = io.open(tmp_dir .. "/" .. entry .. "/_meta.lua", "r")
            if mf then
                local c = mf:read("*a")
                mf:close()
                new_dir = tmp_dir .. "/" .. entry
                new_version = c:match('version%s*=%s*"([^"]+)"')
                break
            end
        end
    end
    if not new_dir then
        Updater.rmtree(tmp_dir)
        os.remove(zip_path)
        return nil, _("包内未找到插件内容，放弃安装")
    end
    if Updater.compareVersions(new_version, tag) ~= 0 then
        Updater.rmtree(tmp_dir)
        os.remove(zip_path)
        return nil, _("包版本与目标版本不一致，放弃安装")
    end

    -- 4) 换目录：当前目录改名让位，新目录顶上；旧目录下次启动清理
    local old_dir = parent .. "/" .. base .. ".old-" .. tostring(os.time())
    if not os.rename(dir, old_dir) then
        Updater.rmtree(tmp_dir)
        os.remove(zip_path)
        return nil, _("无法移动当前插件目录（权限不足？）")
    end
    if not os.rename(new_dir, dir) then
        -- 回滚：把旧目录改回来，保证插件仍可用
        os.rename(old_dir, dir)
        Updater.rmtree(tmp_dir)
        os.remove(zip_path)
        return nil, _("安装失败，已还原旧版本")
    end
    os.remove(zip_path)
    return true
end

-- 菜单入口：检查更新 → 有新版则确认后自动下载安装。
function Updater.checkForUpdate()
    local local_ver = Updater.getLocalVersion() or "unknown"
    UIManager:show(InfoMessage:new{ text = T(_("当前版本 %1，正在检查更新…"), local_ver), timeout = 2 })
    UIManager:scheduleIn(0.1, function()
        local tag, err = Updater.checkLatest()
        if not tag then
            UIManager:show(InfoMessage:new{ text = _("检查更新失败：") .. tostring(err), timeout = 4 })
            return
        end
        if Updater.compareVersions(tag, local_ver) <= 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("已是最新版本（%1）"), local_ver), timeout = 3 })
            return
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("发现新版本 %1（当前 %2）。\n现在自动下载并安装吗？\n安装完成后会提示重启 KOReader。"), tag, local_ver),
            ok_text = _("安装"),
            ok_callback = function()
                UIManager:show(InfoMessage:new{ text = _("正在下载新版本…"), timeout = 60 })
                UIManager:scheduleIn(0.1, function()
                    local ok2, inst_err = Updater.downloadAndInstall(tag)
                    if ok2 then
                        UIManager:show(ConfirmBox:new{
                            text = T(_("已更新到 %1。\n需要重启 KOReader 生效，现在重启吗？"), tag),
                            ok_text = _("重启"),
                            ok_callback = function() UIManager:restartKOReader() end,
                            cancel_text = _("稍后"),
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("更新失败：") .. tostring(inst_err), timeout = 6 })
                    end
                end)
            end,
        })
    end)
end

return Updater

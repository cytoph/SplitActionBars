-- Saved custom gaps. Only this addon's database is written.
local _, ns = ...
local L = ns.L
local db, staged, stagedKey, newCopy
local EMPTY = {}
local function Number(n, lo, hi)
    return type(n) == "number" and n == n and n >= lo and n <= hi
end
local function Copy(src)
    local dst = {}
    if type(src) ~= "table" then return dst end
    for bar = 1, 8 do
        local entries, seen = {}, {}
        if type(src[bar]) == "table" then
            for _, e in ipairs(src[bar]) do
                -- v0.2 after-button seams were single-row primary seams.
                -- Normalize copies too, so migration is lossless/idempotent.
                local axis = type(e) == "table" and (e.axis or "primary")
                local id = type(e) == "table" and tostring(axis) .. ":" .. tostring(e.after)
                if (axis == "primary" or axis == "secondary") and Number(e.after, 1, 11) and e.after % 1 == 0
                    and Number(e.gap, 0, 256) and not seen[id] then
                    entries[#entries + 1] = { axis = axis, after = e.after, gap = e.gap }
                    seen[id] = true
                end
            end
        end
        table.sort(entries, function(a,b) return a.after < b.after end)
        if #entries > 0 then dst[bar] = entries end
    end
    return dst
end
local function Key(info)
    if type(info) ~= "table" or type(info.layoutName) ~= "string"
        or not Number(info.layoutType, 0, 100) then return nil end
    local scope = "account"
    if info.layoutType == Enum.EditModeLayoutType.Character then
        local name, realm = UnitFullName("player")
        realm = realm or GetRealmName()
        if not name or not realm then return nil end
        scope = "character:" .. #name .. ":" .. name .. ":" .. #realm .. ":" .. realm
    end
    return scope .. ":" .. info.layoutType .. ":" .. info.layoutName
end
local function ActiveKey()
    local m = EditModeManagerFrame
    return m and m.GetActiveLayoutInfo and Key(m:GetActiveLayoutInfo())
end
function ns.ActiveSettings()
    local key = ActiveKey()
    if staged and stagedKey == key then return staged end
    return db and key and db.layouts[key] or EMPTY
end
function ns.GetGaps(index) return ns.ActiveSettings()[index] or EMPTY end
local function Changed()
    if ns.Schedule then ns.Schedule() end
    if ns.RefreshPanel then ns.RefreshPanel() end
end
local function Discard()
    staged, stagedKey = nil, nil
    if ns.ResetPanelEdits then ns.ResetPanelEdits() end
    Changed()
end
function ns.SetGap(bar, axis, oldIndex, after, gap, oldAxis)
    local m, key = EditModeManagerFrame, ActiveKey()
    if InCombatLockdown() then return false, L.COMBAT_DEFERRED end
    if not key or not db or not m:IsEditModeActive() then return false, L.OPEN_EDIT_MODE end
    if not Number(bar,1,8) or bar % 1 ~= 0 then return false, L.UNSUPPORTED_BAR end
    if axis ~= "primary" and axis ~= "secondary" then return false, L.UNSUPPORTED_AXIS end
    oldAxis = oldAxis or axis
    if oldAxis ~= "primary" and oldAxis ~= "secondary" then return false, L.UNSUPPORTED_OLD_AXIS end
    if after ~= nil and (not Number(after,1,11) or after % 1 ~= 0 or not Number(gap,0,256)) then
        return false, string.format(L.INVALID_GAP,L.AFTER_COLUMN .. " / " .. L.AFTER_ROW,
            1,11,HUD_EDIT_MODE_SETTING_ACTION_BAR_ICON_PADDING or L.DISTANCE,0,256)
    end
    local current = ns.GetGaps(bar)
    for _, entry in ipairs(current) do
        if entry.axis == axis and after and entry.after == after
            and not (entry.axis == oldAxis and entry.after == oldIndex) then
            return false, L.DUPLICATE_GAP
        end
    end
    if not staged or stagedKey ~= key then staged, stagedKey = Copy(ns.ActiveSettings()), key end
    local entries = staged[bar] or {}
    for i = #entries, 1, -1 do
        if entries[i].axis == oldAxis and entries[i].after == oldIndex then table.remove(entries,i) end
    end
    if after then entries[#entries+1] = {axis=axis,after=after,gap=gap} end
    table.sort(entries,function(a,b) return a.after < b.after end)
    staged[bar] = #entries > 0 and entries or nil
    m:SetHasActiveChanges(true)
    Changed()
    return true
end
local managerHooked, dialogHooked
function ns.SetupManager()
    local m = EditModeManagerFrame
    if not m or not m.GetActiveLayoutInfo then return end
    if not managerHooked then
        managerHooked = true
        local Remember
        -- Native checks may clear the dirty flag because custom gaps do not
        -- change native systemInfo. Keep Save enabled for staged addon edits.
        hooksecurefunc(m,"CheckForSystemActiveChanges",function()
            if staged and stagedKey == ActiveKey() then m:SetHasActiveChanges(true) end
        end)
        hooksecurefunc(m,"SaveLayouts",function()
            if Remember then Remember() end
            if staged and stagedKey == ActiveKey() then db.layouts[stagedKey] = Copy(staged) end
            staged, stagedKey = nil, nil
            if ns.ResetPanelEdits then ns.ResetPanelEdits() end
            Changed()
        end)
        hooksecurefunc(m,"UpdateLayoutInfo",function()
            if Remember then Remember() end
            if stagedKey ~= ActiveKey() then
                staged, stagedKey = nil, nil
                if ns.ResetPanelEdits then ns.ResetPanelEdits() end
            end
            if staged then m:SetHasActiveChanges(true) end
            Changed()
        end)
        hooksecurefunc(m,"RevertAllChanges",Discard)
        hooksecurefunc(m,"ExitEditMode",function() newCopy = nil; Discard() end)
        hooksecurefunc(m,"RevertSystemChanges",function(_,bar)
            if staged and stagedKey == ActiveKey() and ns.IsBar(bar) then
                local saved = Copy(db.layouts[stagedKey])
                staged[bar.systemIndex] = saved[bar.systemIndex]
                if ns.ResetPanelEdits then ns.ResetPanelEdits(bar) end
                m:SetHasActiveChanges(true)
                Changed()
            end
        end)
        -- MakeNewLayout internally Reverts and Saves BEFORE its post-hook.
        -- Capture the preview when its native new-layout dialog opens, not
        -- after that destructive ordering. Imports deliberately start empty.
        hooksecurefunc(m,"ShowNewLayoutDialog",function(_,info)
            local source = info or m:GetActiveLayoutInfo()
            newCopy = { info = source, settings = Copy(ns.ActiveSettings()) }
        end)
        hooksecurefunc(m,"MakeNewLayout",function(_,info,layoutType,layoutName,imported)
            local key = info and Key(info)
            if key and info.layoutType == layoutType and info.layoutName == layoutName then
                local found = false
                for _, layout in ipairs(m:GetLayouts()) do if Key(layout) == key then found = true end end
                if found then
                    db.layouts[key] = not imported and newCopy and Copy(newCopy.settings) or {}
                end
            end
            newCopy = nil
            Changed()
        end)
        -- Key names follow native rename; retain previews under the new key.
        local known = setmetatable({}, {__mode="k"})
        Remember = function()
            for _,info in ipairs(m:GetLayouts() or {}) do
                local key, old = Key(info), known[info]
                if key and old and old ~= key then
                    db.layouts[key], db.layouts[old] = db.layouts[old], nil
                    if stagedKey == old then stagedKey = key end
                end
                known[info] = key
            end
        end
        Remember()
        hooksecurefunc(m,"UpdateLayoutInfo",Remember)
        hooksecurefunc(m,"RenameLayout",Remember)
    end
    local d = EditModeSystemSettingsDialog
    if d and d.AttachToSystemFrame and not dialogHooked then
        dialogHooked = true
        hooksecurefunc(d,"AttachToSystemFrame",function(_,bar)
            if ns.AttachPanel then ns.AttachPanel(ns.IsBar(bar) and bar or nil) end
        end)
        d:HookScript("OnHide",function() if ns.AttachPanel then ns.AttachPanel(nil) end end)
        m:HookScript("OnHide",function() if ns.AttachPanel then ns.AttachPanel(nil) end end)
    end
end
function ns.IsBar(bar)
    local i = bar and bar.systemIndex
    return i and ns.names[i] and _G[ns.names[i]] == bar
        and bar.system == Enum.EditModeSystem.ActionBar and bar.actionButtons
end
function ns.InitDB()
    local source = type(SplitActionBarsDB) == "table" and SplitActionBarsDB or {}
    local layouts = {}
    if type(source.layouts) == "table" then
        for key, settings in pairs(source.layouts) do
            if type(key) == "string" then layouts[key] = Copy(settings) end
        end
    end
    db = {version=2,layouts=layouts}
    SplitActionBarsDB = db
end

-- Native container geometry from the manually validated Forever prototype.
-- No native settings, bindings, visibility or whole-bar anchor writes.
local _, ns = ...
local L = ns.L
local names = { "MainActionBar", "MultiBarBottomLeft", "MultiBarBottomRight",
    "MultiBarRight", "MultiBarLeft", "MultiBar5", "MultiBar6", "MultiBar7" }
ns.names = names
local states, hooked = {}, {}
local enabled = true
local busy, queued, pending, ready = false, false, false, false
local interface = select(4, GetBuildInfo())
local supported = type(interface) == "number" and ((interface >= 16000 and interface < 20000) or interface == 120105)
local EPS = 0.05
local Refresh, Schedule
local function Say(text) DEFAULT_CHAT_FRAME:AddMessage("|cff80c0ffSplitActionBars:|r " .. text) end

local function Near(a,b) return math.abs(a-b) < EPS end
local function NativeGrid(bar,state)
    if state.applied then
        for _,item in ipairs(state.applied) do
            item.frame:ClearAllPoints()
            item.frame:SetPoint(unpack(item.point))
        end
        state.applied = nil
    end
    bar.oldGridSettings = nil
    ActionBarMixin.UpdateGridLayout(bar)
end
local function Shape(bar)
    local n, rows = bar.numButtonsShowable, bar.numRows
    return type(n) == "number" and n >= 1 and n <= 12 and n % 1 == 0
        and type(rows) == "number" and rows >= 1 and rows <= 12 and rows % 1 == 0
end
-- Physical labels are left-to-right / top-to-bottom. Saved indices follow
-- native traversal, so changing orientation does not rewrite configuration.
function ns.GridAxes(bar)
    local n, rows = bar.numButtonsShowable or 1, bar.numRows or 1
    local stride = math.ceil(n / rows)
    local tracks = math.ceil(n / math.max(1,stride))
    local right, top = bar.addButtonsToRight ~= false, bar.addButtonsToTop
    if top == nil then top = bar.isHorizontal end
    return {
        {axis=bar.isHorizontal and "primary" or "secondary", count=bar.isHorizontal and stride or tracks, reverse=not right},
        {axis=bar.isHorizontal and "secondary" or "primary", count=bar.isHorizontal and tracks or stride, reverse=top},
    }
end
function ns.VisualIndex(axis, index)
    return axis.reverse and index < axis.count and axis.count-index or index
end
local function Measure(bar)
    local n = bar.numButtonsShowable
    if not Shape(bar) then return nil,L.NEED_GRID end
    if bar:GetNumPoints() ~= 1 then return nil,L.MULTI_ANCHOR end
    if not bar.shownButtonContainers or #bar.shownButtonContainers ~= n then
        return nil,L.NEED_CONTAINERS
    end
    local bs,us = bar:GetEffectiveScale(),UIParent:GetEffectiveScale()
    local bl,bb,bw = bar:GetLeft(),bar:GetBottom(),bar:GetWidth()
    if not bs or bs <= 0 or not us or us <= 0 or not bl or not bb or not bw then
        return nil,L.NO_GEOMETRY
    end
    local members,ordered = {},{}
    for _,c in ipairs(bar.shownButtonContainers) do members[c] = true end
    for _,button in pairs(bar.actionButtons or {}) do
        if members[button.container] then
            ordered[#ordered+1] = {index=button.index,frame=button.container,button=button}
        end
    end
    table.sort(ordered,function(a,b) return (a.index or 0) < (b.index or 0) end)
    if #ordered ~= n then return nil,L.MEMBERSHIP end
    for i,item in ipairs(ordered) do
        local c,button = item.frame,item.button
        if item.index ~= i or c:GetNumPoints() ~= 1 then return nil,L.BUTTON_ORDER end
        local cs,l,bottom = c:GetEffectiveScale(),c:GetLeft(),c:GetBottom()
        if not cs or cs <= 0 or not l or not bottom then return nil,L.CONTAINER_GEOMETRY end
        local p,relative,rp,x,y = c:GetPoint(1)
        if relative ~= bar then return nil,L.CONTAINER_ANCHOR end
        item.point = {p,relative,rp,x,y}
        item.scale = cs
        item.x = (l*cs-bl*bs)/bs
        item.y = (bottom*cs-bb*bs+c:GetHeight()*cs/2)/bs
        item.width = c:GetWidth()*cs/bs
        item.height = c:GetHeight()*cs/bs
        if item.width <= 0 or item.height <= 0
            or not Near(button:GetWidth()*button:GetEffectiveScale()/bs,item.width)
            or not Near(button:GetHeight()*button:GetEffectiveScale()/bs,item.height) then
            return nil,L.BUTTON_SIZE
        end
    end
    local xs, ys = {}, {}
    local function Track(list,value)
        for _,v in ipairs(list) do if Near(v,value) then return end end
        list[#list+1] = value
    end
    local first = ordered[1]
    for _,item in ipairs(ordered) do
        if not Near(item.width,first.width) or not Near(item.height,first.height)
            or not Near(item.scale,first.scale) then return nil,L.IRREGULAR_GRID end
        Track(xs,item.x); Track(ys,item.y)
    end
    table.sort(xs); table.sort(ys)
    local axes = ns.GridAxes(bar)
    if #xs ~= axes[1].count or #ys ~= axes[2].count then return nil,L.GRID_DIMENSIONS end
    local function Padding(list,size)
        if #list == 1 then return 0 end
        local step = list[2]-list[1]
        for i=2,#list do if not Near(list[i]-list[i-1],step) then return nil end end
        return step-size
    end
    local px,py = Padding(xs,first.width),Padding(ys,first.height)
    if not px or not py or px < -EPS or py < -EPS then return nil,L.GRID_SPACING end
    for _,item in ipairs(ordered) do
        for i,v in ipairs(xs) do if Near(v,item.x) then item.column=i end end
        for i,v in ipairs(ys) do if Near(v,item.y) then item.row=i end end
    end
    -- Preserve asymmetric native margins and incomplete final tracks.
    return {items=ordered,xs=xs,ys=ys,axes=axes,width=bw,height=bar:GetHeight(),
        paddingX=px,paddingY=py,unit=us/bs,scale=bs}
end
local function Apply(bar,state)
    if InCombatLockdown() then pending = true; return end
    local entries = ns.GetGaps(bar.systemIndex)
    local eligible = enabled and supported and Shape(bar)
    local active = {}
    local axes = eligible and ns.GridAxes(bar)
    if axes then
        for _,entry in ipairs(entries) do
            for physical,axis in ipairs(axes) do
                if entry.axis == axis.axis and entry.after < axis.count then
                    active[#active+1] = {physical=physical,after=entry.after,gap=entry.gap}
                end
            end
        end
    end
    if state.applied or #active > 0 then NativeGrid(bar,state) end
    if not enabled or not supported then
        state.reason = L.DISABLED; return
    end
    if #entries == 0 then state.reason = L.NO_GAP_STATUS; return end
    if not eligible then state.reason = L.INACTIVE_GRID; return end
    if #active == 0 then state.reason = L.INACTIVE_SEAMS; return end
    local geometry,reason = Measure(bar)
    state.reason = reason
    if not geometry then return end
    local deltas,totals = {{},{}},{0,0}
    for _,entry in ipairs(active) do
        local physical = entry.physical
        local axis = geometry.axes[physical]
        -- Prefix sums use increasing x/y. UI rows use decreasing y.
        local reverse = physical == 1 and axis.reverse or physical == 2 and not axis.reverse
        local seam = reverse and axis.count-entry.after or entry.after
        local padding = physical == 1 and geometry.paddingX or geometry.paddingY
        local delta = entry.gap*geometry.unit-padding
        deltas[physical][seam] = delta
        totals[physical] = totals[physical]+delta
    end
    local expectedW,expectedH = geometry.width+totals[1],geometry.height+totals[2]
    if expectedW <= 0 or expectedH <= 0 then state.reason = L.INVALID_DIMENSIONS; return end
    local prefixes = {{0},{0}}
    for physical,axis in ipairs(axes) do
        for i=2,axis.count do prefixes[physical][i] = prefixes[physical][i-1]+(deltas[physical][i-1] or 0) end
    end
    state.applied = geometry.items
    for _,item in ipairs(geometry.items) do
        local factor = geometry.scale/item.scale
        item.frame:ClearAllPoints()
        item.frame:SetPoint("LEFT",bar,"BOTTOMLEFT",
            (item.x+prefixes[1][item.column])*factor,(item.y+prefixes[2][item.row])*factor)
    end
    bar:Layout()
    if not Near(bar:GetWidth(),expectedW) or not Near(bar:GetHeight(),expectedH) then
        NativeGrid(bar,state)
        state.reason = L.RESIZE_CONSTRAINTS; return
    end
    state.reason = string.format(L.ACTIVE_GAPS,#active)
end
local function Hook(bar)
    if hooked[bar] then return end
    hooked[bar] = true
    for _,method in ipairs({"UpdateGridLayout","UpdateShownButtons","UpdateSystemSettingIconSize",
        "UpdateSystemSettingNumIcons","UpdateSystemSettingNumRows","UpdateSystemSettingOrientation",
        "UpdateSystemSettingIconPadding","SetScale"}) do
        if type(bar[method]) == "function" then hooksecurefunc(bar,method,function() Schedule() end) end
    end
    bar:HookScript("OnShow",function() Schedule() end)
end
Refresh = function()
    if busy or not ready or not supported then return end
    if InCombatLockdown() then pending = true; return end
    pending,busy = false,true
    for i,name in ipairs(names) do
        local bar = _G[name]
        states[i] = states[i] or {}
        if bar and bar.systemIndex == i and type(bar.UpdateGridLayout) == "function" and ActionBarMixin then
            Hook(bar)
            Apply(bar,states[i])
        else states[i].reason = L.BAR_UNAVAILABLE end
    end
    busy = false
    if ns.RefreshPanel then ns.RefreshPanel() end
end
Schedule = function()
    if busy or not ready or not supported then return end
    if InCombatLockdown() then pending = true; return end
    if queued then return end
    queued = true
    C_Timer.After(0,function() queued = false; Refresh() end)
end
ns.Schedule = Schedule
function ns.StatusFor(index) return states[index] and states[index].reason or L.NOT_INSPECTED end
SLASH_SPLITACTIONBARS1 = "/splitbars"
SlashCmdList.SPLITACTIONBARS = function(text)
    local command = text:match("^%s*(%S*)"):lower()
    if command == "on" or command == "off" then
        enabled = command == "on"; Schedule()
        Say(enabled and L.ENABLED_MESSAGE or L.OFF_MESSAGE)
    elseif command == "" or command == "status" then
        Refresh()
        Say(string.format(L.STATUS,not supported and L.UNSUPPORTED_CLIENT
            or enabled and L.ENABLED or L.OFF)
            .. ((pending or InCombatLockdown()) and L.COMBAT_STATUS or ""))
        for i,name in ipairs(names) do Say(string.format(L.BAR_STATUS,i,name,ns.StatusFor(i))) end
    else Say(L.COMMAND_HELP) end
end
local watcher = CreateFrame("Frame")
for _,event in ipairs({"PLAYER_LOGIN","PLAYER_ENTERING_WORLD","PLAYER_REGEN_ENABLED","PLAYER_REGEN_DISABLED",
    "ADDON_LOADED","UI_SCALE_CHANGED","DISPLAY_SIZE_CHANGED"}) do watcher:RegisterEvent(event) end
watcher:SetScript("OnEvent",function(_,event,addon)
    if event == "ADDON_LOADED" and addon == "SplitActionBars" then ns.InitDB() end
    if event == "PLAYER_LOGIN" then
        ready = true
        ns.SetupManager()
        if not supported then Say(L.CLIENT_DISABLED) end
    elseif event == "ADDON_LOADED" and ready then ns.SetupManager() end
    if event == "PLAYER_REGEN_DISABLED" and ns.AttachPanel then ns.AttachPanel(nil) end
    Schedule()
end)

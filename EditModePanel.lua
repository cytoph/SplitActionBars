-- Shared native-style seam editor; native Save/Revert owns persistence.
local _, ns = ...
local L = ns.L
local panel, selectedBar, entry, axes, shape
local refreshing, committing, detaching = false, false, false
local dirty, loaded, epoch = false, false, 0
local CONTROL_LEFT, RIGHT_INSET, LABEL_LEFT = 124, 32, 20
local function FieldText(label,text)
    -- Keep the native font and allow longer labels to wrap before the controls.
    local maxWidth=CONTROL_LEFT-LABEL_LEFT-8
    label:SetText(text)
    label:SetWidth(math.min(label:GetUnboundedStringWidth(),maxWidth))
    -- Wrapped labels also hug the longest visible line, not the column boundary.
    label:SetWidth(math.min(label:GetWrappedWidth()+0.5,maxWidth))
end
local function Label(parent,text,x,y,font)
    local f=parent:CreateFontString(nil,"ARTWORK",font or "GameFontHighlightMedium")
    f:SetPoint("TOPLEFT",x,y); f:SetText(text); return f
end
local function Tooltip(owner,text)
    owner:HookScript("OnEnter",function(self)
        local value=type(text) == "function" and text() or text
        if not value or value == "" then return end
        GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
        GameTooltip:SetText(value,nil,nil,nil,nil,true); GameTooltip:Show()
    end)
    owner:HookScript("OnLeave",function() GameTooltip:Hide() end)
end
local function Info(parent,anchor,text)
    local b=CreateFrame("Button",nil,parent); b:SetSize(24,24)
    b:SetPoint("LEFT",anchor,"RIGHT",6,0)
    local icon=b:CreateTexture(nil,"ARTWORK"); icon:SetAllPoints()
    icon:SetTexture("Interface\\Common\\help-i"); Tooltip(b,text); return b
end
local function IconButton(parent,template,x,y,callback)
    local b=CreateFrame("Button",nil,parent,template)
    b:SetSize(24,24); b:SetPoint("TOPLEFT",x,y)
    b:SetFrameLevel(parent:GetFrameLevel()+1)
    b:SetScript("OnClick",callback); return b
end
local function LayoutErrors()
    if not panel then return end
    -- Measure the actual wrapped font strings after text and width are set.
    local function Height(f) return f:GetText() ~= "" and f:GetStringHeight() or 0 end
    local positionHeight=Height(panel.PositionError)
    local shift=positionHeight > 0 and math.max(0,positionHeight-4) or 0
    panel.DistanceRow:ClearAllPoints()
    panel.DistanceRow:SetPoint("TOPLEFT",panel,"TOPLEFT",0,-shift)
    panel.DistanceRow:SetPoint("TOPRIGHT",panel,"TOPRIGHT",0,-shift)
    local bottom=208+shift
    local distanceHeight=Height(panel.DistanceError)
    if distanceHeight > 0 then bottom=212+shift+distanceHeight end
    local messageTop=math.max(216,bottom+8)
    panel.Message:ClearAllPoints()
    panel.Message:SetPoint("TOPLEFT",panel,"TOPLEFT",20,-messageTop)
    panel.Message:SetPoint("TOPRIGHT",panel,"TOPRIGHT",-20,-messageTop)
    local messageHeight=Height(panel.Message)
    panel:SetHeight(math.max(228,bottom+16,messageHeight > 0 and messageTop+messageHeight+16 or 0))
end
local function FieldErrors(position,distance)
    if not panel then return end
    panel.PositionError:SetText(position or "")
    panel.DistanceError:SetText(distance or "")
    LayoutErrors()
end
local function Error(text)
    if panel then panel.Message:SetText(text or ""); LayoutErrors() end
end
local function Same(a,b) return a and b and a.axis == b.axis and a.after == b.after end
local function Signature(a)
    return table.concat({a[1].axis,a[1].count,tostring(a[1].reverse),
        a[2].axis,a[2].count,tostring(a[2].reverse)},":")
end
local function Physical(e,a) return e and e.axis == a[2].axis and 2 or 1 end
local function PositionLabel()
    if panel then
        FieldText(panel.PositionLabel,Physical(entry,axes) == 2 and L.AFTER_ROW or L.AFTER_COLUMN)
    end
end
local function Editable()
    return selectedBar and not InCombatLockdown() and EditModeManagerFrame:IsEditModeActive()
end
local function StepValue(text,delta,position)
    local value=tonumber(text)
    if not value or value ~= value or value == math.huge or value == -math.huge then return nil end
    local lo,hi=position and 1 or 0,position and 11 or 256
    if value < lo then return delta > 0 and lo or nil end
    if value > hi then return delta < 0 and hi or nil end
    if position and value%1 ~= 0 then return nil end
    if (value == lo and delta < 0) or (value == hi and delta > 0) then return nil end
    return math.max(lo,math.min(hi,value+delta))
end
local function StepCandidate(input,delta)
    -- Eligibility never stages settings or refreshes/replaces the current draft.
    if not entry or not axes or not Editable() or shape ~= Signature(ns.GridAxes(selectedBar)) then return nil end
    local axis=axes[Physical(entry,axes)]
    if not axis or (axis.axis ~= "primary" and axis.axis ~= "secondary") or entry.axis ~= axis.axis then return nil end
    local position=input == panel.Position
    local candidate=StepValue(input:GetText(),delta,position)
    if candidate and position then
        local occupied={}
        for _,other in ipairs(ns.GetGaps(selectedBar.systemIndex)) do
            if other.axis == axis.axis and not Same(entry,other) then occupied[other.after]=true end
        end
        while candidate and occupied[ns.VisualIndex(axis,candidate)] do
            candidate=StepValue(tostring(candidate),delta,true)
        end
    end
    return candidate
end
local function UpdateSteps()
    if not panel then return end
    panel.PositionDecrement:SetEnabled(StepCandidate(panel.Position,-1) ~= nil)
    panel.PositionIncrement:SetEnabled(StepCandidate(panel.Position,1) ~= nil)
    panel.DistanceDecrement:SetEnabled(StepCandidate(panel.Distance,-1) ~= nil)
    panel.DistanceIncrement:SetEnabled(StepCandidate(panel.Distance,1) ~= nil)
end
local function ClearDraft()
    epoch=epoch+1; dirty,loaded=false,false; detaching=true
    if panel then panel.Position:ClearFocus(); panel.Distance:ClearFocus(); FieldErrors() end
    detaching=false
end
local function CurrentAxes()
    if not selectedBar then return false end
    if shape ~= Signature(ns.GridAxes(selectedBar)) then
        ClearDraft(); ns.RefreshPanel()
        Error(L.GRID_CHANGED); return false
    end
    return true
end
local function ValidateValues(positionText,distanceText)
    local position,gap=tonumber(positionText),tonumber(distanceText)
    local positionError,distanceError
    if not position or position ~= position or position%1 ~= 0 or position < 1 or position > 11 then
        positionError=string.format(L.INVALID_POSITION,1,11)
    end
    if not gap or gap ~= gap or gap < 0 or gap > 256 then
        distanceError=string.format(L.INVALID_DISTANCE,0,256)
    end
    return position,gap,positionError,distanceError
end
local function ValidateDraft(direction)
    local position,gap,positionError,distanceError=ValidateValues(panel.Position:GetText(),panel.Distance:GetText())
    if not positionError and entry and axes and selectedBar then
        local axis=axes[direction or Physical(entry,axes)]
        local after=ns.VisualIndex(axis,position)
        for _,other in ipairs(ns.GetGaps(selectedBar.systemIndex)) do
            if other.axis == axis.axis and other.after == after and not Same(entry,other) then
                positionError=L.DUPLICATE_GAP; break
            end
        end
    end
    FieldErrors(positionError,distanceError)
    return position,gap,not positionError and not distanceError
end
local function Commit(direction)
    if refreshing or committing or detaching or not entry or not Editable() then return false end
    if not CurrentAxes() then return false end
    local position,gap,valid=ValidateDraft(direction)
    Error()
    if not valid then return false end
    local axis=axes[direction or Physical(entry,axes)]
    local after=ns.VisualIndex(axis,position)
    if entry.axis == axis.axis and entry.after == after and entry.gap == gap then
        dirty=false; Error(); UpdateSteps(); return true
    end
    committing=true
    local ok,err=ns.SetGap(selectedBar.systemIndex,axis.axis,entry.after,after,gap,entry.axis)
    committing=false
    if ok then
        entry={axis=axis.axis,after=after,gap=gap}; dirty=false; epoch=epoch+1; Error()
        PositionLabel()
        panel.Gaps:GenerateMenu(); panel.Direction:GenerateMenu()
    elseif err == L.DUPLICATE_GAP then FieldErrors(err,nil)
    else Error(err) end
    UpdateSteps()
    return ok
end
local function Select(e)
    if not Editable() or not CurrentAxes() then return end
    local reselect=Same(entry,e)
    if entry and not Commit() then return end
    -- A valid draft can move the selected seam while its menu is open.
    -- Reselecting that item must retain its newly committed identity.
    local target=reselect and entry or e
    ClearDraft(); entry={axis=target.axis,after=target.after,gap=target.gap}; Error(); ns.RefreshPanel()
end
local function FreePosition(a)
    local used={}
    for _,e in ipairs(ns.GetGaps(selectedBar.systemIndex)) do
        if e.axis == a.axis then used[ns.VisualIndex(a,e.after)]=true end
    end
    for i=1,11 do if not used[i] then return i end end
end
local function Add()
    if not Editable() or not CurrentAxes() then return end
    if entry and not Commit() then return end
    local first=Physical(entry,axes)
    local axis=axes[first]; local position=FreePosition(axis)
    if not position then axis=axes[3-first]; position=FreePosition(axis) end
    if not position then return end
    local after=ns.VisualIndex(axis,position)
    committing=true
    local ok,err=ns.SetGap(selectedBar.systemIndex,axis.axis,nil,after,16)
    committing=false
    if not ok then Error(err); return end
    ClearDraft(); entry={axis=axis.axis,after=after,gap=16}; Error(); ns.RefreshPanel()
end
local function Input(parent,x,y,width)
    local e=CreateFrame("EditBox",nil,parent,"InputBoxTemplate")
    e:SetSize(width,28); e:SetPoint("TOPLEFT",x,y); e:SetAutoFocus(false)
    e:SetFontObject(GameFontHighlight); e:SetMaxLetters(8)
    e:SetScript("OnTextChanged",function(_,userInput)
        if userInput then dirty=true; ValidateDraft(); Error(); UpdateSteps() end
    end)
    e:SetScript("OnEnterPressed",function(self)
        if Commit() then self:ClearFocus(); ns.RefreshPanel() end
    end)
    e:SetScript("OnEditFocusLost",function()
        if refreshing or committing or detaching then return end
        local token,bar=epoch,selectedBar
        -- Destination clicks and native Save/Revert run before this callback.
        C_Timer.After(0,function()
            if epoch == token and selectedBar == bar and dirty and not detaching then
                if Commit() then ns.RefreshPanel() end
            end
        end)
    end)
    e:SetScript("OnEscapePressed",function() ClearDraft(); Error(); ns.RefreshPanel() end)
    return e
end
local function Dropdown(parent,x,y,width)
    local d=CreateFrame("DropdownButton",nil,parent,"WowStyle1DropdownTemplate")
    d:SetPoint("TOPLEFT",x,y); d:SetWidth(width); d:EnableRegenerateOnResponse(); return d
end
local function CreatePanel()
    local p=CreateFrame("Frame","SplitActionBarsEditModePanel",UIParent)
    p:SetClampedToScreen(true); p:SetSize(370,228)
    local border=CreateFrame("Frame",nil,p,"DialogBorderTranslucentTemplate"); border:SetAllPoints()
    p.Title=Label(p,"SplitActionBars",0,-15,"GameFontHighlightLarge")
    p.Title:ClearAllPoints(); p.Title:SetPoint("TOP",0,-15)
    local help=Info(p,p.Title,L.HELP_MAIN)
    help:ClearAllPoints(); help:SetPoint("TOPRIGHT",-16,-12)
    p.Gaps=Dropdown(p,20,-48,296); p.Gaps:SetDefaultText(L.NO_GAPS)
    p.Gaps:SetupMenu(function(_,root)
        if not selectedBar then return end
        local a=ns.GridAxes(selectedBar); local entries={}
        for _,e in ipairs(ns.GetGaps(selectedBar.systemIndex)) do entries[#entries+1]=e end
        table.sort(entries,function(l,r)
            local lp,rp=Physical(l,a),Physical(r,a)
            return lp < rp or (lp == rp and ns.VisualIndex(a[lp],l.after)<ns.VisualIndex(a[rp],r.after))
        end)
        for _,e in ipairs(entries) do
            local physical=Physical(e,a)
            local text=string.format(physical == 1 and L.GAP_COLUMN or L.GAP_ROW,
                ns.VisualIndex(a[physical],e.after),tostring(e.gap))
            local item=root:CreateRadio(text,function() return Same(entry,e) end,function() Select(e) end)
            item:SetEnabled(not not Editable())
        end
        local add=root:CreateButton(L.ADD_GAP,Add)
        add:SetEnabled(not not (Editable() and (FreePosition(a[1]) or FreePosition(a[2]))))
    end)
    p.Remove=IconButton(p,"UIPanelCloseButtonNoScripts",326,-49,function()
        if not entry or not Editable() or not CurrentAxes() then return end
        committing=true
        local ok,err=ns.SetGap(selectedBar.systemIndex,entry.axis,entry.after,nil,nil)
        committing=false
        if ok then ClearDraft(); entry=nil; Error(); ns.RefreshPanel() else Error(err) end
    end)
    p.Remove:ClearAllPoints(); p.Remove:SetPoint("TOPRIGHT",-RIGHT_INSET-1,-49)
    p.Gaps:SetPoint("RIGHT",p.Remove,"LEFT",-8,0)
    Tooltip(p.Remove,L.HELP_REMOVE)
    p.DistanceRow=CreateFrame("Frame",nil,p)
    p.DistanceRow:SetHeight(228)
    p.DistanceRow:SetPoint("TOPLEFT"); p.DistanceRow:SetPoint("TOPRIGHT")
    local function Field(text,centerY,parent)
        parent=parent or p
        local label=Label(parent,"",0,0)
        label:ClearAllPoints(); label:SetPoint("LEFT",parent,"TOPLEFT",LABEL_LEFT,centerY)
        label:SetJustifyH("LEFT"); label:SetWordWrap(true); label:SetNonSpaceWrap(true)
        FieldText(label,text); return label
    end
    -- Resolve native globals when the Edit Mode panel is created, not at addon load.
    Field(HUD_EDIT_MODE_SETTING_ACTION_BAR_ORIENTATION or L.DIRECTION,-106)
    p.Direction=Dropdown(p,CONTROL_LEFT+1,-92,156); p.Direction:SetDefaultText(L.COLUMNS)
    p.Direction:SetPoint("TOPRIGHT",p,"TOPRIGHT",-RIGHT_INSET-1,-92)
    Tooltip(p.Direction,function()
        if not selectedBar or not entry then return L.HELP_DIRECTION end
        return Physical(entry,ns.GridAxes(selectedBar)) == 1 and L.HELP_DIRECTION_COLUMN or L.HELP_DIRECTION_ROW
    end)
    p.Direction:SetupMenu(function(_,root)
        for i,name in ipairs({L.COLUMNS,L.ROWS}) do
            root:CreateRadio(name,function() return entry and axes and Physical(entry,axes) == i end,
                function() Commit(i); p.Direction:GenerateMenu() end)
        end
    end)
    local after=Field(L.AFTER_COLUMN,-150); p.PositionLabel=after
    Field(HUD_EDIT_MODE_SETTING_ACTION_BAR_ICON_PADDING or L.DISTANCE,-194,p.DistanceRow)
    p.Position=Input(p,CONTROL_LEFT+6,-136,50); p.Distance=Input(p.DistanceRow,CONTROL_LEFT+6,-180,50)
    local function PositionHelp()
        if not selectedBar or not entry then return L.HELP_AFTER end
        local currentGridAxes=ns.GridAxes(selectedBar)
        return Physical(entry,currentGridAxes) == 1 and L.HELP_AFTER_COLUMN or L.HELP_AFTER_ROW
    end
    Tooltip(p.Position,PositionHelp); Tooltip(p.Distance,L.HELP_DISTANCE)
    p.Controls={p.Direction,p.Position,p.Distance,p.Remove}
    local function Step(input,delta)
        if not entry or not Editable() or not CurrentAxes() then return end
        local value=StepCandidate(input,delta)
        if value == nil then UpdateSteps(); return end
        input:SetText(tostring(value)); dirty=true; Commit(); UpdateSteps()
    end
    for _,row in ipairs({{p.Position,-138},{p.Distance,-182}}) do
        local input,y=row[1],row[2]
        local parent=input == p.Position and p or p.DistanceRow
        local decrement=IconButton(parent,"SteppersDecrementButtonTemplate",0,y,function() Step(input,-1) end)
        local increment=IconButton(parent,"SteppersIncrementButtonTemplate",0,y,function() Step(input,1) end)
        if input == p.Position then
            p.PositionDecrement,p.PositionIncrement=decrement,increment
        else
            p.DistanceDecrement,p.DistanceIncrement=decrement,increment
        end
        increment:ClearAllPoints(); increment:SetPoint("TOPRIGHT",parent,"TOPRIGHT",-RIGHT_INSET-2,y)
        decrement:ClearAllPoints(); decrement:SetPoint("RIGHT",increment,"LEFT",-8,0)
        input:SetPoint("RIGHT",decrement,"LEFT",-8,0)
        local help=input == p.Position and PositionHelp or L.HELP_DISTANCE
        Tooltip(decrement,help); Tooltip(increment,help)
        p.Controls[#p.Controls+1]=decrement; p.Controls[#p.Controls+1]=increment
    end
    local function FieldError(parent,y)
        local f=Label(parent,"",20,y,"GameFontHighlight")
        f:SetPoint("TOPRIGHT",parent,"TOPRIGHT",-20,y)
        f:SetWordWrap(true); f:SetNonSpaceWrap(true); f:SetJustifyH("LEFT")
        f:SetTextColor(1,0.2,0.2); return f
    end
    p.PositionError=FieldError(p,-168)
    p.DistanceError=FieldError(p.DistanceRow,-212)
    local layoutWidth
    p:SetScript("OnSizeChanged",function(_,width)
        if panel == p and width ~= layoutWidth then layoutWidth=width; LayoutErrors() end
    end)
    p.Message=Label(p,"",20,-216,"GameFontHighlight")
    p.Message:SetPoint("TOPRIGHT",-20,-216); p.Message:SetWordWrap(true)
    p.Message:SetJustifyH("LEFT"); p.Message:SetTextColor(1,0.82,0)
    p:Hide(); return p
end
function ns.RefreshPanel()
    if not panel or not selectedBar or not panel:IsShown() or committing or refreshing then return end
    local nextAxes=ns.GridAxes(selectedBar); local nextShape=Signature(nextAxes)
    if shape ~= nextShape then ClearDraft() end
    axes,shape=nextAxes,nextShape
    local found
    for _,e in ipairs(ns.GetGaps(selectedBar.systemIndex)) do if Same(entry,e) then found=e; break end end
    if not found then ClearDraft(); found=ns.GetGaps(selectedBar.systemIndex)[1] end
    entry=found and {axis=found.axis,after=found.after,gap=found.gap} or nil
    PositionLabel()
    refreshing=true
    local enabled=not not (Editable() and entry)
    for _,control in ipairs(panel.Controls) do control:SetEnabled(enabled) end
    panel.Gaps:SetEnabled(not not Editable())
    if not loaded or not (dirty or panel.Position:HasFocus() or panel.Distance:HasFocus()) then
        panel.Position:SetText(entry and tostring(ns.VisualIndex(axes[Physical(entry,axes)],entry.after)) or "")
        panel.Distance:SetText(entry and tostring(entry.gap) or ""); loaded=true
    end
    UpdateSteps()
    panel.Gaps:GenerateMenu(); panel.Direction:GenerateMenu(); refreshing=false
end
-- Native lifecycle resets cancel drafts and pending focus-loss callbacks.
function ns.ResetPanelEdits(bar)
    if not panel or (bar and bar ~= selectedBar) then return end
    ClearDraft(); Error()
end
function ns.AttachPanel(bar)
    if bar == selectedBar and panel and panel:IsShown() then ns.RefreshPanel(); return end
    ClearDraft(); selectedBar,entry,axes,shape=nil,nil,nil,nil
    if panel then panel.Gaps:CloseMenu(); panel.Direction:CloseMenu(); panel:Hide() end
    if not bar or InCombatLockdown() then return end
    panel=panel or CreatePanel(); selectedBar=bar
    local d=EditModeSystemSettingsDialog
    if d.Title and d.Title.GetFontObject then panel.Title:SetFontObject(d.Title:GetFontObject()) end
    panel:SetFrameStrata(d:GetFrameStrata()); panel:SetFrameLevel(d:GetFrameLevel()+10)
    -- Close template defaults to level 510; keep icon controls local.
    for _,control in ipairs(panel.Controls) do control:SetFrameLevel(panel:GetFrameLevel()+1) end
    panel:ClearAllPoints(); panel:SetPoint("TOPLEFT",d,"BOTTOMLEFT",0,-6)
    panel:SetPoint("TOPRIGHT",d,"BOTTOMRIGHT",0,-6)
    Error(); panel:Show(); ns.RefreshPanel()
end

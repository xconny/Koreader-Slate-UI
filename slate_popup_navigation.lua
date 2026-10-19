-- Forward deliberate dock taps only, after closing the current modal stack.
local UIManager=require('ui/uimanager')
local Navigation={}
local function contains(r,p)return r and p and p.x>=r.x and p.x<r.x+r.w and p.y>=r.y and p.y<r.y+r.h end
function Navigation:switch(popup,owner,ges,gesture)
    owner=owner or (popup and (popup.slate_owner or popup.owner))
    if not(owner and owner._slate_screen)then
        local ok,quotes=pcall(require,'slate_quotes')
        owner=ok and quotes.getSlateOwner and quotes:getSlateOwner()or nil
    end
    local screen=owner and owner._slate_screen
    if not screen or not screen.awake or not screen.interactive then return false end
    local pos=ges and ges.pos
    local hit=false
    for _,key in ipairs({'quicklaunch_button','quote_button','library_button','recents_button','weather_button','book_button','lock_button'})do
        local r=screen[key]
        if r and screen.touchRect then r=screen:touchRect(r)end
        if contains(r,pos) and (gesture~='hold' or key=='book_button' or key=='lock_button')then hit=true;break end
    end
    if not hit then return false end
    local x,y=pos.x,pos.y
    -- Registered roots close their children as part of onCloseWidget.
    if owner._slate_tag_manager then UIManager:close(owner._slate_tag_manager)end
    if owner._slate_settings_editor and owner._slate_settings_editor.onClose then owner._slate_settings_editor:onClose()end
    if owner.closeWeatherPopups then owner:closeWeatherPopups()
    elseif popup and popup.onClose then popup:onClose()end
    UIManager:nextTick(function()
        if owner._slate_screen==screen and screen.awake then
            if gesture=='hold' then screen:onHold(nil,{pos={x=x,y=y}})
            else screen:onTap(nil,{pos={x=x,y=y}})end
        end
    end)
    return true
end
function Navigation:wrapDialog(dialog,owner)
    local original=dialog.onTapClose
    if type(original)~='function'or dialog._slate_dock_navigation then return dialog end
    dialog._slate_dock_navigation=true
    dialog.onTapClose=function(instance,arg,ges)
        local r=instance.movable and instance.movable.dimen or instance.dimen
        if not contains(r,ges and ges.pos) and Navigation:switch(instance,owner,ges)then return true end
        return original(instance,arg,ges)
    end
    local hold=dialog.onHold
    local release=dialog.onHoldRelease
    local screen=owner and owner._slate_screen
    if screen and screen.dimen then
        local GestureRange=require('ui/gesturerange')
        dialog.ges_events=dialog.ges_events or {}
        dialog.ges_events.SlateDockHold={GestureRange:new{ges='hold',range=screen.dimen}}
        dialog.ges_events.SlateDockHoldRelease={GestureRange:new{ges='hold_release',range=screen.dimen}}
        dialog.onSlateDockHold=function(instance,arg,ges)
            local r=instance.movable and instance.movable.dimen or instance.dimen
            if not contains(r,ges and ges.pos)and Navigation:switch(instance,owner,ges,'hold')then return true end
            if hold then return hold(instance,arg,ges)end
        end
        dialog.onSlateDockHoldRelease=function(instance,...)
            if release then return release(instance,...)end
            return true
        end
    end
    return dialog
end
return Navigation

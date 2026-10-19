-- SPDX-License-Identifier: AGPL-3.0-or-later
local InputContainer = require('ui/widget/container/inputcontainer')
local UIManager = require('ui/uimanager')
local Device = require('device')
local Screen = Device.screen
local Geom = require('ui/geometry')
local GestureRange = require('ui/gesturerange')
local Font = require('ui/font')
local TextWidget = require('ui/widget/textwidget')
local TextBoxWidget = require('ui/widget/textboxwidget')
local ImageWidget = require('ui/widget/imagewidget')
local BB = require('ffi/blitbuffer')
local DocSettings = require('docsettings')
local ReaderUI = require('apps/reader/readerui')
local Event = require('ui/event')
local Utils = require('slate_utils')
local InfoMessage = require('ui/widget/infomessage')
local _ = require('gettext')
local module_source = debug.getinfo(1, 'S').source
local module_dir = module_source:sub(1, 1) == '@'
    and (module_source:sub(2):match('(.*/)') or '') or ''
local pagination_cache = {}
local pagination_order = {}
local Browser = {}
local Popup = InputContainer:extend{modal=true, dithered=true}
local function contains(r,p)
    return r and p and p.x>=r.x and p.x<r.x+r.w and p.y>=r.y and p.y<r.y+r.h
end
local function text(bb,value,r,size,bold,center,color)
    local widget
    for n=size,6,-1 do
        widget=TextWidget:new{text=tostring(value or ''),face=Font:getFace('infofont',n),bold=bold,fgcolor=color or BB.COLOR_BLACK}
        local d=widget:getSize()
        if d.w<=r.w and d.h<=r.h or n==6 then break end
        widget:free()
    end
    local d=widget:getSize()
    widget:paintTo(bb,r.x+(center=='right' and math.max(0,r.w-d.w) or (center and math.max(0,math.floor((r.w-d.w)/2)) or 0)),r.y+math.max(0,math.floor((r.h-d.h)/2)))
    widget:free()
end
local function measure(value,face,width)
    local t=TextBoxWidget:new{text=value,face=face,width=width}
    local h=t:getSize().h;t:free();return h
end
local function split(value,face,width,height)
    value=tostring(value or ''):gsub('\r\n','\n')
    if value=='' then return {''} end
    if measure(value,face,width)<=height then return {value} end
    local ends={}
    for i=1,#value do
        local b=value:byte(i+1)
        if not b or b<128 or b>=192 then ends[#ends+1]=i end
    end
    local pages,start,first={},1,1
    while start<=#value do
        while first<=#ends and ends[first]<start do first=first+1 end
        local low,high,best=first,#ends,ends[first]
        while low<=high do
            local mid=math.floor((low+high)/2)
            if measure(value:sub(start,ends[mid]),face,width)<=height then best=ends[mid];low=mid+1
            else high=mid-1 end
        end
        best=best or #value
        local finish=best
        if best<#value then
            local chunk=value:sub(start,best);local boundary=chunk:match('.*()%s')
            if boundary and boundary>#chunk*.55 then finish=start+boundary-2 end
        end
        pages[#pages+1]=value:sub(start,finish):gsub('%s+$','')
        start=finish+1
        while value:sub(start,start):match('%s') do start=start+1 end
    end
    return pages
end
local function loadBook(file)
    local reader=ReaderUI.instance
    local active=reader and reader.document and reader.document.file==file
    local settings=active and reader.doc_settings or DocSettings:open(file)
    local props=active and reader.doc_props or settings:readSetting('doc_props',{})
    props=props or {}
    local BookInfo=require('apps/filemanager/filemanagerbookinfo')
    if type(BookInfo.extendProps)=='function' then
        local ok,extended=pcall(BookInfo.extendProps,props,file)
        if ok and type(extended)=='table' then props=extended end
    end
    local source=active and reader.annotation and reader.annotation.annotations
        or settings:readSetting('annotations')
    local entries={}
    local function add(item,page,index)
        if type(item)~='table' or type(item.text)~='string' or item.text=='' then return end
        if not item.pos0 and not item.drawer and not item.highlighted then return end
        local p=tonumber(item.pageno or item.page or page)
        if type(item.pos0)=='table' then p=tonumber(item.pos0.page) or p end
        if active and type(item.pos0)=='string' and reader.document.getPageFromXPointer then
            local ok,n=pcall(reader.document.getPageFromXPointer,reader.document,item.pos0)
            if ok then p=tonumber(n) or p end
        end
        entries[#entries+1]={item=item,page=p,index=index or #entries+1}
    end
    if type(source)=='table' then
        for i,item in ipairs(source) do add(item,nil,i) end
    else
        for page,items in pairs(settings:readSetting('highlight',{})) do
            if type(items)=='table' then for _,item in ipairs(items) do add(item,page) end end
        end
    end
    table.sort(entries,function(a,b)
        if active and type(a.item.pos0)=='string' and type(b.item.pos0)=='string'
            and reader.document.compareXPointers then
            local ok,order=pcall(reader.document.compareXPointers,reader.document,a.item.pos0,b.item.pos0)
            if ok and order~=0 then return order==1 end
        end
        if a.page and b.page and a.page~=b.page then return a.page<b.page end
        local ap,bp=a.item.pos0,b.item.pos0
        if type(ap)=='table' and type(bp)=='table' then
            if ap.y and bp.y and ap.y~=bp.y then return ap.y<bp.y end
            if ap.x and bp.x and ap.x~=bp.x then return ap.x<bp.x end
        end
        return a.index<b.index
    end)
    return entries,props,active and reader or nil
end
local function fiveWords(value)
    local lines, words = {}, {}
    for word in tostring(value or ''):gmatch('%S+') do
        words[#words+1]=word
        if #words==5 then lines[#lines+1]=table.concat(words,' ');words={} end
    end
    if #words>0 then lines[#lines+1]=table.concat(words,' ') end
    return table.concat(lines,'\n')
end

local DiagnosticsPopup=InputContainer:extend{modal=true}
function DiagnosticsPopup:init()
    self.dimen=Screen:getSize()
    local parent=self.parent
    self.pad=parent.pad
    self.box={w=parent.box.w,h=math.max(1,math.floor(parent.box.h*.85))}
    self.box.x=parent.box.x
    self.box.y=parent.box.y+math.floor((parent.box.h-self.box.h)/2)
    local inner=self.box.w-self.pad*2
    self.header_h=math.max(36,Screen:scaleBySize(48))
    local pager_w=math.min(math.floor(inner*.45),Screen:scaleBySize(300))
    self.title_rect={x=self.box.x+self.pad,y=self.box.y+self.pad,w=inner-pager_w-self.pad/2,h=self.header_h}
    self.pager_rect={x=self.box.x+self.box.w-self.pad-pager_w,y=self.title_rect.y,w=pager_w,h=self.header_h}
    self.divider_gap=math.max(2,math.floor(self.pad/2))*3
    self.divider_y=self.title_rect.y+self.header_h+self.divider_gap
    self.body={x=self.box.x+self.pad,y=self.divider_y+self.divider_gap,w=inner}
    self.body.h=math.max(1,self.box.y+self.box.h-self.pad-self.body.y)
    self.face=Font:getFace('infofont',14)
    self.pages=split(tostring(self.text or ''),self.face,self.body.w,self.body.h)
    if #self.pages==0 then self.pages={_('No search details available.')} end
    self.page=1
    self.ges_events={Tap={GestureRange:new{ges='tap',range=self.dimen}},Swipe={GestureRange:new{ges='swipe',range=self.dimen}}}
    if Device:hasKeys() then self.key_events={Close={{'Back'}},NextPage={{'PgFwd'}},PrevPage={{'PgBack'}}} end
end
function DiagnosticsPopup:paintTo(bb)
    local r=self.box
    local radius=tonumber(G_reader_settings:readSetting('slate.popup_corner_radius',40)) or 40
    bb:paintRoundedRect(r.x,r.y,r.w,r.h,BB.COLOR_WHITE,radius)
    bb:paintBorder(r.x,r.y,r.w,r.h,2,BB.COLOR_BLACK,radius)
    text(bb,_('[SEARCH QUERY]'),self.title_rect,20,true,false)
    local pager=self.pager_rect
    local arrow=math.max(12,math.floor(pager.w*.16))
    self.prev={x=pager.x,y=pager.y,w=arrow,h=pager.h}
    self.next={x=pager.x+pager.w-arrow,y=pager.y,w=arrow,h=pager.h}
    if #self.pages>1 then
        text(bb,'‹',self.prev,48,true,true,self.page>1 and BB.COLOR_BLACK or BB.COLOR_DARK_GRAY)
        text(bb,'›',self.next,48,true,true,self.page<#self.pages and BB.COLOR_BLACK or BB.COLOR_DARK_GRAY)
    end
    text(bb,_('Pages')..' '..self.page..' / '..#self.pages,
        {x=pager.x+arrow+2,y=pager.y,w=pager.w-arrow*2-4,h=pager.h},14,false,true)
    bb:paintRect(self.body.x,self.divider_y,self.body.w,1,BB.COLOR_LIGHT_GRAY)
    local widget=TextBoxWidget:new{text=self.pages[self.page],face=self.face,width=self.body.w}
    widget:paintTo(bb,self.body.x,self.body.y);widget:free()
end
function DiagnosticsPopup:turn(delta)
    self.page=math.max(1,math.min(#self.pages,self.page+delta))
    UIManager:setDirty(self,'ui');return true
end
function DiagnosticsPopup:onTap(_,ges)
    local pos=ges and ges.pos
    if not contains(self.box,pos)then
        if require('slate_popup_navigation'):switch(self,nil,ges)then return true end
        return self:onClose()
    end
    if contains(self.prev,pos) then return self:turn(-1) end
    if contains(self.next,pos) then return self:turn(1) end
    return true
end
function DiagnosticsPopup:onSwipe(_,ges)
    if ges and contains(self.box,ges.pos) then
        if ges.direction=='west' or ges.direction=='north' then return self:turn(1) end
        if ges.direction=='east' or ges.direction=='south' then return self:turn(-1) end
    end
    return true
end
function DiagnosticsPopup:onNextPage()return self:turn(1)end
function DiagnosticsPopup:onPrevPage()return self:turn(-1)end
function DiagnosticsPopup:onClose()UIManager:close(self);return true end
function DiagnosticsPopup:onCloseWidget()
    if self.parent.trace_viewer==self then self.parent.trace_viewer=nil end
    if not self.parent.closed and not self.parent._closed then UIManager:setDirty(self.parent,'ui') end
end

local CoverPreview=InputContainer:extend{modal=true,dithered=true}
function CoverPreview:init()
    self.dimen=Screen:getSize()
    self.pad=self.parent.pad
    self.file=self.parent.file or (self.parent.entry and self.parent.entry.file)
    self.box={w=math.floor(Screen:getWidth()*2/3),h=math.floor(Screen:getHeight()*3/5)}
    self.box.x=math.floor((Screen:getWidth()-self.box.w)/2)
    local owner=self.parent.owner or {}
    local screen=owner._slate_screen;local lock=screen and screen.lock_button
    local top=lock and lock.y+lock.h or 0
    local bottom=owner._slate_card_bounds and owner._slate_card_bounds.y or Screen:getHeight()
    local edge=math.max(8,Screen:scaleBySize(10))
    local available=math.max(1,bottom-top-edge*2)
    local old_height=math.min(Screen:getHeight()*.60-Screen:scaleBySize(24),available)
    local base=math.max(1,old_height-math.max(36,Screen:scaleBySize(36))-math.max(32,Screen:scaleBySize(32))-self.pad)
    local highlights_h=math.min(available,math.floor(base*1.25))
    local anchor=math.floor(top+(bottom-top-highlights_h)/2)-math.floor(self.pad/2)
    self.box.y=math.max(edge,math.min(anchor,Screen:getHeight()-edge-self.box.h))
    local w,h=self.box.w-self.pad*2,self.box.h-self.pad*2
    local ok,image=pcall(function()return require('slate_books'):loadCover(self.file,w,h,true)end)
    if ok then self.image=image end
    if not self.image then
        local loaded,cover=pcall(function()
            return require('apps/filemanager/filemanagerbookinfo'):getCoverImage(
                self.parent.reader and self.parent.reader.document or nil,self.file)
        end)
        if loaded and cover then
            self.image=ImageWidget:new{image=cover,width=w,height=h,scale_factor=nil}
        end
    end
    self.ges_events={Tap={GestureRange:new{ges='tap',range=self.dimen}}}
    if Device:hasKeys() then self.key_events={Close={{'Back'}}} end
end
function CoverPreview:paintTo(bb)
    local r=self.box
    local radius=tonumber(G_reader_settings:readSetting('slate.popup_corner_radius',40)) or 40
    bb:paintRoundedRect(r.x,r.y,r.w,r.h,BB.COLOR_WHITE,radius)
    bb:paintBorder(r.x,r.y,r.w,r.h,2,BB.COLOR_BLACK,radius)
    if self.image then
        self.image:paintTo(bb,r.x+self.pad,r.y+self.pad)
    else text(bb,_('Cover not available.'),{x=r.x+self.pad,y=r.y+self.pad,w=r.w-self.pad*2,h=r.h-self.pad*2},16,false,true) end
end
function CoverPreview:onTap(_,ges)
    if require('slate_popup_navigation'):switch(self,nil,ges)then return true end
    return self:onClose()
end
function CoverPreview:onClose()UIManager:close(self);return true end
function CoverPreview:onCloseWidget()
    if self.image then self.image:free();self.image=nil end
    if self.parent.cover_preview==self then self.parent.cover_preview=nil end
    if not self.parent.closed then UIManager:setDirty(self.parent,'ui') end
end

function Popup:prepareHeader()
    local title=fiveWords(self.props.display_title or self.props.title or self.file:match('([^/]+)$'))
    local author=self.props.authors or self.props.author or ''
    if type(author)=='table' then author=table.concat(author,', ') end
    self.author_text=author
    self.cover_h=self.cover_h or self.header_h
    if self.header_title then self.header_title:free();self.header_title=nil end
    local cover_w=math.floor(self.cover_h*.68)
    local pager_w=math.min(math.floor(self.body.w*.50),Screen:scaleBySize(300))
    self.header_title_w=math.max(1,self.body.w-cover_w-self.pad*2-pager_w)
    local author_measure=TextWidget:new{text=author,face=Font:getFace('infofont',14)}
    self.author_h=author_measure:getSize().h;author_measure:free()
    self.author_gap=math.max(2,math.floor(self.pad*.125))
    for size=22,10,-1 do
        self.header_title=TextBoxWidget:new{text=title,face=Font:getFace('infofont',size),
            bold=true,width=self.header_title_w,alignment='left'}
        self.header_title_h=self.header_title:getSize().h
        if self.header_title_h+self.author_h+self.author_gap<=self.cover_h or size==10 then break end
        self.header_title:free()
    end
    self.header_h=math.max(self.cover_h,self.line_h+self.nav_h+math.max(1,math.floor(self.pad/3))*2)
    self.divider_gap=math.max(2,math.floor(self.pad/2))*3
    self.divider_y=self.box.y+self.pad+self.header_h+self.divider_gap+(self.search_title_h or 0)
    self.body.y=self.divider_y+self.divider_gap
    self.body.h=math.max(1,self.box.y+self.box.h-self.pad-self.footer_h-self.body.y)
end

local function paginationSignature(entries,width,height)
    local a,b,total=5381,2166136261,0
    for _,entry in ipairs(entries) do
        local value=tostring(entry.item.text)..'|'..tostring(entry.item.note or '')
            ..'|'..tostring(entry.page or '')..'|'..(type(entry.item.pos0)=='table'
                and table.concat({entry.item.pos0.page or '',entry.item.pos0.x or '',entry.item.pos0.y or ''},':')
                or tostring(entry.item.pos0 or ''))
        total=total+#value
        for i=1,#value do
            local byte=value:byte(i)
            a=(a*33+byte)%4294967296;b=(b*65599+byte)%4294967296
        end
    end
    return table.concat({width,height,#entries,total,a,b},'|')
end

function Popup:paginationReady()
    self.pagination_loading=false
    self.highlight_starts={}
    for index,page in ipairs(self.pages) do
        if not self.highlight_starts[page.number] then self.highlight_starts[page.number]=index end
    end
    if self.onPaginationReady then self:onPaginationReady() end
    if self.visible then UIManager:setDirty(self,'ui') end
end

function Popup:init()
    self.dimen=Screen:getSize()
    local current=ReaderUI.instance
    self.reader=current and current.document and current.document.file==self.file and current or nil
    self.props=self.reader and self.reader.doc_props or {}
    if not self.reader then
        local ok,settings=pcall(DocSettings.open,DocSettings,self.file)
        if ok and settings then self.props=settings:readSetting('doc_props',{}) or {} end
    end
    local ok,info=pcall(require,'apps/filemanager/filemanagerbookinfo')
    if ok and type(info.extendProps)=='function' then
        local extended,props=pcall(info.extendProps,self.props,self.file)
        if extended and type(props)=='table' then self.props=props end
    end
    self.entries={}
    self.pagination_loading=true
    local w,h=Screen:getWidth(),Screen:getHeight()
    local screen=self.owner._slate_screen;local lock=screen and screen.lock_button
    local top=lock and lock.y+lock.h or 0
    local card=self.owner._slate_card_bounds
    local bottom=card and card.y or h
    local edge=math.max(8,Screen:scaleBySize(10))
    local available=math.max(1,bottom-top-edge*2)
    self.box=Geom:new{w=math.min(math.floor(w*.96),Screen:scaleBySize(900))}
    self.box.x=math.floor((w-self.box.w)/2)
    self.pad=math.max(10,math.floor(self.box.w*.035))
    self.nav_h=math.max(36,Screen:scaleBySize(36))
    self.line_h=math.max(32,Screen:scaleBySize(32))
    local old_height=math.floor(math.min(h*.60-Screen:scaleBySize(24),available))
    local base_height=math.max(1,old_height-self.nav_h-self.line_h-self.pad)
    self.box.h=math.max(1,math.min(available,math.floor(base_height*1.25)))
    self.box.y=math.max(0,math.floor(top+(bottom-top-self.box.h)/2))
    local inner=self.box.w-self.pad*2
    self.view=self.search_state and 'highlights' or 'description'
    self.tab_pages={highlights=1,description=1}
    self.description_pages={}
    self.button_h=math.max(26,Screen:scaleBySize(36))
    self.footer_h=self.button_h+self.pad
    self.header_h=math.max(self.nav_h+self.line_h,math.floor(base_height*.22))
    self.body={x=self.box.x+self.pad,y=self.box.y+self.header_h+self.pad*2,w=inner}
    self.body.h=math.max(1,self.box.y+self.box.h-self.pad-self.footer_h-self.body.y)
    self.face=Font:getFace('infofont',16)
    if self.search_state then
        local q=self.search_state.results[self.search_state.index]
        if not self.props.title then self.props.title=q.book end
        if not self.props.authors then self.props.authors=q.author end
    end
    self.search_header_icons=G_reader_settings:readSetting('slate.popup_header_icons',true)==true
    self.search_header_size=math.max(16,math.min(200,tonumber(G_reader_settings:readSetting('slate.popup_header_icon_size',72)) or 72))
    self.search_header_h=math.max(Screen:scaleBySize(44),self.search_header_icons and self.search_header_size or 0)
    self.search_header_pad=math.max(10,math.min(Screen:scaleBySize(18),math.floor(self.box.w*.05)))
    self.search_title_h=self.search_state and self.search_header_h+self.pad*1.5+self.search_header_pad-self.pad or 0
    self:prepareHeader()
    self.pages={}
    local index,loaded=1,false
    local function paginate()
        self.pagination_task=nil
        if self.closed then return end
        if not loaded then
            local ok,entries,props,reader
            if self.search_state then
                local q=self.search_state.results[self.search_state.index]
                ok,entries,props,reader=true,{{text=q.text,page=q.page,item={text=q.text,pos0=q.pos0}}},self.props,self.reader
            else ok,entries,props,reader=pcall(loadBook,self.file) end
            if not ok then
                self.pagination_loading=false
                self.loading_error=_('Could not load this book’s highlights.')
                self:paginationReady()
                return
            end
            self.entries,self.props,self.reader=entries,props,reader
            self:prepareHeader()
            self.pagination_signature=paginationSignature(entries,self.body.w,self.body.h)
            local cached=pagination_cache[self.file]
            if cached and cached.signature==self.pagination_signature then
                for _,page in ipairs(cached.pages) do
                    self.pages[#self.pages+1]={entry=entries[page.number],text=page.text,
                        number=page.number,part=page.part,parts=page.parts}
                end
                self:paginationReady()
                return
            end
            loaded=true
        end
        local entry=self.entries[index]
        if entry then
            local body=entry.item.text
            if entry.item.note and entry.item.note~='' then
                body=body..'\n\n'.._('Note:')..' '..tostring(entry.item.note)
            end
            local ok,chunks=pcall(split,body,self.face,inner,self.body.h)
            if not ok then
                self.pagination_loading=false
                self.loading_error=_('Could not paginate this highlight.')
                self:paginationReady()
                return
            end
            for n,chunk in ipairs(chunks) do
                self.pages[#self.pages+1]={entry=entry,text=chunk,number=index,part=n,parts=#chunks}
            end
        end
        index=index+1
        if self.entries[index] then
            self.pagination_task=paginate
            UIManager:scheduleIn(.001,paginate)
        else
            local pages={}
            for _,page in ipairs(self.pages) do
                pages[#pages+1]={text=page.text,number=page.number,part=page.part,parts=page.parts}
            end
            if not pagination_cache[self.file] then pagination_order[#pagination_order+1]=self.file end
            pagination_cache[self.file]={signature=self.pagination_signature,pages=pages}
            while #pagination_order>4 do pagination_cache[table.remove(pagination_order,1)]=nil end
            self:paginationReady()
        end
    end
    self.pagination_task=paginate
    self.finishPagination=function(instance)
        while instance.pagination_loading and not instance.closed do
            local task=instance.pagination_task
            if not task then break end
            UIManager:unschedule(task)
            task()
        end
    end
    self.page=1
    self.highlight_pages={}
    self.ges_events={}
    for name,kind in pairs{Tap='tap',Swipe='swipe',Hold='hold',HoldRelease='hold_release'} do
        self.ges_events[name]={GestureRange:new{ges=kind,range=Screen:getSize()}}
    end
    if Device:hasKeys() then self.key_events={Close={{'Back'}}} end
    self.cover_task=function()
        self.cover_task=nil
        if self.closed then return end
        local ok,cover=pcall(function()
            return require('apps/filemanager/filemanagerbookinfo'):getCoverImage(
                self.reader and self.reader.document or nil,self.file)
        end)
        if ok and cover then
            self.cover=ImageWidget:new{image=cover,width=math.floor((self.cover_h or self.header_h)*.68),height=self.cover_h or self.header_h,scale_factor=nil}
            UIManager:setDirty(self,'ui')
        end
    end
    self.load_cover_task=self.cover_task
    local cached_ok,cached=pcall(function()
        return require('slate_books'):loadCover(self.file,math.floor(self.header_h*.68),self.header_h,true)
    end)
    if cached_ok and cached then
        self.cover=cached
        self.cover_task=nil
    else UIManager:scheduleIn(.02,self.cover_task) end
end
function Browser:paintQuoteControls(bb,o)
    local result={}
    local right_x,pager_w,controls_y=o.x,o.w,o.y
    local icon_gap=math.max(1,math.floor(o.pad/3))
    local nav_y=controls_y+math.max(o.line_h,math.max(24,Screen:scaleBySize(32)))+icon_gap*2
    local has_quote=o.entry and o.entry.text and o.entry.text~=''
    local star_space=has_quote and 2*(math.max(24,Screen:scaleBySize(32))+math.max(1,math.floor(o.pad/3))) or 0
    if o.mode=='highlights' and o.file and o.file~='' then
        local size=math.max(24,Screen:scaleBySize(32))
        local icon_gap=math.max(1,math.floor(o.pad/3))
        result.jump={x=right_x+pager_w-size-star_space,y=controls_y,w=size,h=size}
        -- Navigation remains on the eye; omit the former BOOK PAGE label/dot.
        result.book_page_link=nil
        local icon
        local ok=pcall(function()
            icon=ImageWidget:new{file=module_dir..'icons/view.svg',width=size,height=size,
                alpha=true,original_in_nightmode=false,invert=false}
            icon:paintTo(bb,result.jump.x,result.jump.y)
        end)
        if icon then icon:free() end
        if not ok then text(bb,'◉',result.jump,32,true,true) end
    end
    if o.mode=='highlights' and has_quote then
        local size=math.max(24,Screen:scaleBySize(32))
        result.favourite={x=right_x+pager_w-size*2-math.max(1,math.floor(o.pad/3)),y=controls_y,w=size,h=size}
        local quotes=require('slate_quotes')
        local marked=quotes:isFavourite(o.entry)
        local icon
        local ok=pcall(function()
            icon=ImageWidget:new{file=module_dir..'icons/'..(marked and 'favourited.svg' or 'unfavourited.svg'),
                width=size,height=size,alpha=true,original_in_nightmode=false,invert=false}
            icon:paintTo(bb,result.favourite.x,result.favourite.y)
        end)
        if icon then icon:free() end
        if not ok then text(bb,marked and '★' or '☆',result.favourite,32,true,true) end
    end
    if o.mode=='highlights' and has_quote then
        local size=math.max(24,Screen:scaleBySize(32))
        result.tag={x=right_x+pager_w-size,y=controls_y,w=size,h=size}
        local quotes=require('slate_quotes')
        local marked=quotes.hasTags and quotes:hasTags(o.entry) or false
        local icon
        local ok=pcall(function()
            icon=ImageWidget:new{file=module_dir..'icons/'..(marked and 'tagged.svg' or 'untagged.svg'),width=size,height=size,alpha=true,original_in_nightmode=false,invert=false}
            icon:paintTo(bb,result.tag.x,result.tag.y)
        end)
        if icon then icon:free()end
        if not ok then text(bb,marked and '◆' or '◇',result.tag,24,true,true)end
    end
    if o.mode=='highlights' and o.quote_total==0 then return result end
    local gap=math.max(4,math.floor(o.pad*.25))
    local inset=gap*2
    local pill_gap=gap*3
    local quote_total=o.quote_total or 1
    local page_total=o.parts or o.page_total or 1
    local show_quote=o.mode=='highlights'
    local random_quote=show_quote and o.random_quotes==true
    local show_pages=page_total>1
    local function sizeOf(value,size,bold)
        local widget=TextWidget:new{text=value,face=Font:getFace('infofont',size),bold=bold}
        local d=widget:getSize();widget:free();return d.w,d.h
    end
    local function requiredWidth(label,total,size,arrows)
        local w,h=sizeOf(label..' '..total..'/'..total,size,false)
        if not arrows then return w,h end
        local arrow_size=math.max(6,size)
        local left=label==_('Quote No.')and '↑'or '←'
        local right=label==_('Quote No.')and '↓'or '→'
        local aw,ah=sizeOf(left,arrow_size,true)
        local bw,bh=sizeOf(right,arrow_size,true)
        return math.ceil(w+math.max(aw,bw)*2+inset*4),math.max(h,ah,bh)
    end
    local font_size,quote_w,pages_w=14,0,0
    for size=14,6,-1 do
        local q,qh=0,0
        if random_quote then
            local tw,th=sizeOf(_('Next Quote'),size,false)
            local aw,ah=sizeOf('↓',math.max(6,size),true)
            local bw,bh=sizeOf('↑',math.max(6,size),true)
            q,qh=tw+math.max(aw,bw)*2+inset*4,math.max(th,ah,bh)
        elseif show_quote then q,qh=requiredWidth(_('Quote No.'),quote_total,size,true)end
        local p,ph=0,0
        -- Reserve the page pill while fitting even when it is hidden. This
        -- keeps quote controls from enlarging on single-page quotes.
        if show_pages or show_quote then p,ph=requiredWidth(_('Pages'),math.max(2,page_total,o.page_total or 1),size,true)end
        font_size,quote_w,pages_w=size,q,p
        if q+p+(show_quote and pill_gap or 0)<=pager_w and math.max(qh,ph)<=o.nav_h then break end
    end
    local function pager(label,index,total,rect,vertical,no_counter)
        local arrow_size=math.max(6,font_size)
        local left,right=vertical and '↑'or '←',vertical and '↓'or '→'
        local aw=sizeOf(left,arrow_size,true)
        local bw=sizeOf(right,arrow_size,true)
        local arrow_w=math.max(aw,bw)
        bb:paintBorder(rect.x,rect.y,rect.w,rect.h,1,BB.COLOR_BLACK,math.floor(rect.h/2))
        text(bb,left,{x=rect.x+inset,y=rect.y,w=arrow_w,h=rect.h},arrow_size,true,true)
        text(bb,right,{x=rect.x+rect.w-inset-arrow_w,y=rect.y,w=arrow_w,h=rect.h},arrow_size,true,true)
        text(bb,no_counter and label or label..' '..index..'/'..total,
            {x=rect.x+arrow_w+inset*2,y=rect.y,w=math.max(1,rect.w-arrow_w*2-inset*4),h=rect.h},font_size,false,true)
        return {x=rect.x,y=rect.y,w=rect.w/2,h=rect.h},
            {x=rect.x+rect.w/2,y=rect.y,w=rect.w/2,h=rect.h}
    end
    local combined=quote_w+(show_pages and pages_w or 0)+(show_quote and show_pages and pill_gap or 0)
    local x=right_x+pager_w-combined
    if show_quote then
        local rect={x=x,y=nav_y,w=quote_w,h=o.nav_h}
        result.quote_pill=rect
        result.quote_prev,result.quote_next=pager(random_quote and _('Next Quote')or _('Quote No.'),
            o.quote_index or 1,quote_total,rect,true,random_quote)
        x=x+quote_w+pill_gap
    end
    if show_pages then
        local rect={x=right_x+pager_w-pages_w,y=nav_y,w=pages_w,h=o.nav_h}
        result.pages_pill=rect
        result.prev,result.next=pager(_('Pages'),o.part or 1,page_total,rect,false)
    end
    return result
end

function Popup:paintTo(bb)
    local r=self.box
    local radius=tonumber(G_reader_settings:readSetting('slate.popup_corner_radius',40)) or 40
    bb:paintRoundedRect(r.x,r.y,r.w,r.h,BB.COLOR_WHITE,radius)
    bb:paintBorder(r.x,r.y,r.w,r.h,2,BB.COLOR_BLACK,radius)
    local cx,cy=r.x+self.pad,r.y+self.pad
    if self.search_state then
        local header_x=self.box.x+self.search_header_pad
        local header_y=self.box.y+self.search_header_pad
        local title_x=header_x
        if self.search_header_icons then
            local size=self.search_header_size
            local y=header_y+math.floor((self.search_header_h-size)/2)
            if G_reader_settings:readSetting('slate.popup_header_outline',true)~=false then
                bb:paintBorder(header_x,y,size,size,math.max(1,math.floor(size/14)),BB.COLOR_BLACK,math.floor(size/2))
            end
            local glyph=math.max(1,math.floor(size))
            local icon
            pcall(function()
                icon=ImageWidget:new{file=module_dir..'icons/'..(self.search_state.icon or 'search.svg'),width=glyph,height=glyph,
                    alpha=true,original_in_nightmode=false,invert=false}
                icon:paintTo(bb,header_x+math.floor((size-glyph)/2),y+math.floor((size-glyph)/2))
            end)
            if icon then icon:free() end
            title_x=header_x+size+Screen:scaleBySize(16)
        end
        if G_reader_settings:readSetting('slate.popup_header_text',true)==true then
            text(bb,_(self.search_state.title or 'SEARCH QUOTES'),{x=title_x,y=header_y,w=self.box.w-self.search_header_pad*2-(title_x-header_x),h=self.search_header_h},20,true,false)
        end
        bb:paintRect(cx,header_y+self.search_header_h+self.pad/2,self.body.w,1,BB.COLOR_LIGHT_GRAY)
        cy=cy+self.search_title_h
    end
    local cw=math.floor((self.cover_h or self.header_h)*.68)
    self.cover_link={x=cx,y=cy,w=cw,h=self.cover_h or self.header_h}
    if self.cover then self.cover:paintTo(bb,cx,cy+math.floor((self.header_h-self.cover_h)/2)) end
    bb:paintBorder(self.cover_link.x,self.cover_link.y,self.cover_link.w,self.cover_link.h,1,BB.COLOR_BLACK)
    local pager_w=math.min(math.floor(self.body.w*.50),Screen:scaleBySize(300))
    local right_x=cx+self.body.w-pager_w
    local tx=cx+cw+self.pad
    local group_h=self.header_title_h+self.author_h+self.author_gap
    local title_y=cy+math.max(0,math.floor((self.header_h-group_h)/2))
    self.header_title:paintTo(bb,tx,title_y)
    text(bb,self.author_text,{x=tx,y=title_y+self.header_title_h+self.author_gap,
        w=self.header_title_w,h=self.author_h},14,false,false)
    bb:paintRect(cx,self.divider_y,
        self.body.w,1,BB.COLOR_LIGHT_GRAY)
    local page=self:currentPages()[self.page]
    local controls_y=cy+math.max(0,math.floor((self.header_h-self.line_h-self.nav_h)/2))
    self.jump=nil
    self.book_page_link=nil
    self.menu_button=nil
    if self.view=='description' then
        local size=math.max(24,Screen:scaleBySize(32))
        self.menu_button={x=cx+self.body.w-size,y=controls_y,w=size,h=size}
        local inset=math.max(3,math.floor(size*.18))
        local stroke=math.max(2,math.floor(size*.07))
        for n=1,3 do
            bb:paintRect(self.menu_button.x+inset,
                self.menu_button.y+math.floor(size*n/4),size-inset*2,stroke,BB.COLOR_BLACK)
        end
    end
    if page then
        local t=TextBoxWidget:new{text=page.text,face=self.face,width=self.body.w}
        t:paintTo(bb,cx,self.body.y);t:free()
    else
        local message=self.view=='description' and (self.description_status or _('No downloaded description available.'))
            or self.loading_error or (self.pagination_loading and _('Loading highlights…'))
            or _('No highlights saved in this book.')
        text(bb,message,{x=cx,y=self.body.y,w=self.body.w,h=self.line_h*2},16,false,true)
    end
    self.search_query_link=nil
    if self.view=='description' and self.description_status and not (self.description_data and self.description_data.pending) then
        self.search_query_link={x=cx,y=self.body.y,w=self.body.w,h=math.min(self.body.h,self.line_h*5)}
    end
    local page_total=math.max(1,#self.description_pages)
    for _,highlight in ipairs(self.pages) do page_total=math.max(page_total,highlight.parts or 1) end
    self.favourite_entry=page and page.entry and {text=page.entry.item.text,file=self.file,
        book=self.props.display_title or self.props.title,author=self.props.authors or self.props.author,
        page=page.entry.page,pos0=page.entry.item.pos0} or nil
    if not self.favourite_entry and self.view=='highlights' and self.search_state then
        self.favourite_entry=self.search_state.results[self.search_state.index]
    end
    local controls=Browser:paintQuoteControls(bb,{entry=self.favourite_entry,x=right_x,y=controls_y,w=pager_w,pad=self.pad,
        line_h=self.line_h,nav_h=self.nav_h,mode=self.view,file=self.file,
        book_page=page and page.entry and (page.entry.page or page.entry.item.pageref),
        quote_total=self.search_state and #self.search_state.results or #self.entries,
        quote_index=self.search_state and self.search_state.index or (page and page.number or 1),
        page_total=page_total,parts=page and page.parts or #self.description_pages,
        part=self.view=='description' and self.page or (page and page.part or 1)})
    self.tag_button=controls.tag
    self.favourite_button=controls.favourite
    self.jump,self.book_page_link=controls.jump,controls.book_page_link
    self.quote_prev,self.quote_next=controls.quote_prev,controls.quote_next
    self.prev,self.next=controls.prev,controls.next

    local gap=math.max(6,math.floor(self.pad*.65))
    local width=math.floor((self.body.w-gap)/2)
    local radius=math.max(0,math.min(60,tonumber(G_reader_settings:readSetting('slate.button_corner_radius',40)) or 40))
    self.tab_buttons={}
    for i,tab in ipairs(self.search_state and {} or {'description','highlights'}) do
        local rect={x=cx+(i-1)*(width+gap),y=r.y+r.h-self.pad-self.button_h,w=width,h=self.button_h,tab=tab}
        self.tab_buttons[i]=rect
        local selected=self.view==tab
        bb:paintRoundedRect(rect.x,rect.y,rect.w,rect.h,selected and BB.COLOR_BLACK or BB.COLOR_WHITE,radius)
        bb:paintBorder(rect.x,rect.y,rect.w,rect.h,1,BB.COLOR_BLACK,radius)
        text(bb,tab=='highlights' and _('HIGHLIGHTS') or _('DESCRIPTION'),rect,18,true,true,
            selected and BB.COLOR_WHITE or BB.COLOR_BLACK)
    end

end
function Popup:currentPages()
    return self.view=='description' and self.description_pages or self.pages
end
function Popup:applyDescription(data)
    if self.closed then return end
    self.description_data=data
    self.search_query_link=nil
    self.description_pages={}
    if data and type(data.text)=='string' and data.text~='' then
        local value=data.text..'\n\n'.._('Source:')..' '..tostring(data.source or '')
        if data.cache_error then value=value..'\n\n'.._('Offline cache could not be saved:')..' '..data.cache_error end
        local ok,chunks=pcall(split,value,self.face,self.body.w,self.body.h)
        if ok then for _,chunk in ipairs(chunks) do self.description_pages[#self.description_pages+1]={text=chunk} end end
        self.description_status=nil
    else
        if data and data.pending then
            self.description_status=data.pending_message or _('Description queued. Waiting for the current download to finish.')
        elseif data and data.error then
            self.description_status=_('No description found.')..'\n\n'.._('[view search query]')
        else
            self.description_status=_('No description found.')..'\n\n'.._('[view search query]')
        end
        local ok,chunks=pcall(split,self.description_status,self.face,self.body.w,self.body.h)
        if ok then
            for _,chunk in ipairs(chunks) do
                self.description_pages[#self.description_pages+1]={text=chunk,status=true}
            end
        end
    end
    if self.view=='description' then self.page=math.max(1,math.min(self.page,math.max(1,#self.description_pages))) end
    if self.visible then UIManager:setDirty(self,'ui') end
end
function Popup:loadDescription()
    local ok,descriptions=pcall(require,'slate_book_descriptions')
    if not ok then
        local message=_('Could not load the description downloader:')..'\n\n'..tostring(descriptions)
        require('logger').warn('Slate: description module load failed:',tostring(descriptions))
        self:applyDescription({error=message});return
    elseif type(descriptions)~='table' or type(descriptions.refreshAsync)~='function' then
        self:applyDescription({error=_('The loaded description downloader has no refreshAsync function.')
            ..'\n\n'.._('Module type:')..' '..type(descriptions)
            ..'\n'.._('Build:')..' '..tostring(type(descriptions)=='table' and descriptions.BUILD or 'unavailable')});return
    end
    local cached,data=pcall(descriptions.get,descriptions,self.file,self.props)
    self:applyDescription(cached and data or {pending=true,pending_message=_('Starting description download…')})
    local received_status=false
    local started,pending=pcall(descriptions.refreshAsync,descriptions,self.file,self.props,function(result)
        received_status=result~=nil
        self:applyDescription(result or {error=_('The description worker returned no result. Check crash.log for the download error.')})
    end)
    if not started then
        self:applyDescription({error=_('Could not start the description search:')..' '..tostring(pending)})
    elseif pending then self:applyDescription(pending)
    elseif not received_status then
        self:applyDescription({error=_('The description search returned no status. Open Description diagnostics to check the downloader.')})
    end
end
function Popup:changeTab(tab)
    if self.view==tab then return true end
    self.tab_pages[self.view]=self.page
    self.view=tab
    self.page=math.max(1,math.min(self.tab_pages[tab] or 1,math.max(1,#self:currentPages())))
    UIManager:setDirty(self,'ui')
    return true
end
function Popup:turn(delta)
    local first,last=1,math.max(1,#self:currentPages())
    local selected=self.view=='highlights' and self.pages[self.page]
    if selected then
        first=(self.highlight_starts and self.highlight_starts[selected.number]) or self.page-selected.part+1
        last=first+selected.parts-1
    end
    local page=math.max(first,math.min(last,self.page+delta))
    if page~=self.page then self.page=page;UIManager:setDirty(self,'ui') end
    return true
end
function Popup:turnHighlight(delta)
    if self.search_state then
        local state=self.search_state
        local index=math.max(1,math.min(#state.results,state.index+delta))
        if index~=state.index then
            local owner=self.owner
            self.search_switching=true
            self:onClose();state.index=index
            Browser:show(owner,state.results[index].file or '',nil,state)
        end
        return true
    end
    if self.view~='highlights' then return self:turn(delta) end
    local selected=self.pages[self.page]
    if not selected then return true end
    self.highlight_pages[selected.number]=selected.part
    local number=math.max(1,math.min(#self.entries,selected.number+delta))
    local first=self.highlight_starts and self.highlight_starts[number]
    if first then
        local part=math.min(self.highlight_pages[number] or 1,self.pages[first].parts)
        self.page=first+part-1
        UIManager:setDirty(self,'ui')
    end
    return true
end
function Popup:jumpToText()
    local entry=self.pages[self.page] and self.pages[self.page].entry
    if not entry or self.file=='' then return true end
    local file,owner=self.file,self.owner
    -- Entering the reader is navigation away from the library. Merely closing
    -- this popup keeps its parent and the exact library page intact.
    if self.parent_popup and not self.parent_popup.closed then self.parent_popup:onClose() end
    self:onClose()
    local screen=owner._slate_screen
    if screen then require('ui/widget/screensaverwidget').onClose(screen) end
    UIManager:nextTick(function()
        local reader=ReaderUI.instance
        if not reader or not reader.document or reader.document.file~=file then ReaderUI:showReader(file) end
        local attempts=0
        local function jump()
            local ui=ReaderUI.instance;attempts=attempts+1
            if ui and ui.document and ui.document.file==file then
                local pos=entry.item.pos0
                if type(pos)=='string' and ui.rolling then ui:handleEvent(Event:new('GotoXPointer',pos))
                elseif entry.page then ui:handleEvent(Event:new('GotoPage',entry.page)) end
            elseif attempts<50 then UIManager:scheduleIn(.1,jump)
            else UIManager:show(Utils:themePopup(InfoMessage:new{text=_('Could not open the highlight location.')})) end
        end
        jump()
    end)
    return true
end
function Popup:traceDescriptionSearch()
    local descriptions=require('slate_book_descriptions')
    if type(descriptions.formatTrace)~='function' then
        UIManager:show(Utils:themePopup(InfoMessage:new{modal=true,text=_('The description downloader does not support lookup tracing.')}))
        return
    end
    if self.trace_notice then return end
    local notice=InfoMessage:new{modal=true,text=_('Tracing this book’s description search…')}
    self.trace_notice=notice;UIManager:show(Utils:themePopup(notice))
    local finished=false
    local function complete(data)
        if finished or self.closed then return end
        self:applyDescription(data)
        if not data or data.pending then return end
        finished=true
        UIManager:close(notice);self.trace_notice=nil
        local TextViewer=require('ui/widget/textviewer')
        local viewer
        viewer=TextViewer:new{title=_('Description search trace'),text=descriptions:formatTrace(data),
            close_callback=function() if self.trace_viewer==viewer then self.trace_viewer=nil end end}
        self.trace_viewer=viewer;UIManager:show(Utils:themePopup(viewer))
    end
    local ok,status=pcall(descriptions.refreshAsync,descriptions,self.file,self.props,complete,true)
    if not ok or not status then
        if not finished then
            UIManager:close(notice);self.trace_notice=nil
            UIManager:show(Utils:themePopup(InfoMessage:new{modal=true,text=_('Could not start the lookup trace:')..' '..tostring(status)}))
        end
    elseif not status.pending then complete(status) end
end
function Popup:showDescriptionMenu()
    if self.view~='description' then return true end
    local ButtonDialog=require('ui/widget/buttondialog')
    local menu
    menu=ButtonDialog:new{modal=true,title=_('Book options'),buttons={{
        {text=_('Edit meta data'),callback=function()
            UIManager:close(menu);self.metadata_menu=nil
            self.metadata_menu=require('slate_book_metadata'):edit(self.file,function(props)
                if self.closed then return end
                self.props=props;self:prepareHeader();self:loadDescription()
                UIManager:setDirty(self,'ui')
            end)
        end},
    },{
        {text=_('Trace description search'),callback=function()
            UIManager:close(menu);self.metadata_menu=nil
            self:traceDescriptionSearch()
        end},
    }}}
    self.metadata_menu=menu
    UIManager:show(Utils:themePopup(menu))
    return true
end
function Popup:openBook()
    if not self.file or self.file=='' then return true end
    local owner,file=self.owner,self.file
    if self.parent_popup and not self.parent_popup.closed then self.parent_popup:onClose() end
    self:onClose()
    require('slate_books'):openBook(owner,{file=file})
    return true
end
function Popup:showSearchQuery()
    local data=self.description_data or {}
    local ok,report=pcall(function()
        local descriptions=require('slate_book_descriptions')
        if type(descriptions.formatFailure)=='function' then return descriptions:formatFailure(data) end
        local identity=data.lookup_identity or data.search_override or data.identity or self.props or {}
        return tostring(data.error or 'No description found.')..'\n\nTitle: '..tostring(identity.title or '')
            ..'\nAuthor: '..tostring(identity.author or identity.authors or '')..'\n\n'
            ..table.concat(data.trace_lines or {},'\n')
    end)
    if not ok then report='Could not format search diagnostics: '..tostring(report) end
    local shown,err=pcall(function()
        local viewer
        viewer=DiagnosticsPopup:new{parent=self,text=tostring(report)}
        self.trace_viewer=viewer
        UIManager:show(Utils:themePopup(viewer))
    end)
    if not shown then
        require('logger').warn('Slate: diagnostics viewer failed:',err)
        UIManager:show(Utils:themePopup(InfoMessage:new{modal=true,text=tostring(report)}))
    end
    return true
end
function Popup:toggleFavourite()
    local marked=require('slate_quotes'):toggleFavourite(self.favourite_entry)
    local state=self.search_state
    if state and state.title=='FAVOURITES' and not marked then
        table.remove(state.results,state.index)
        if #state.results>0 then
            state.index=math.min(state.index,#state.results)
            local owner=self.owner
            self.search_switching=true;self:onClose()
            Browser:show(owner,state.results[state.index].file or '',nil,state)
        else
            self:onClose()
            UIManager:show(Utils:themePopup(InfoMessage:new{modal=true,text=_('No favourite quotes saved.')}))
        end
    else UIManager:setDirty(self,'ui') end
    return true
end
function Popup:onTap(_,ges)
    local pos=ges and ges.pos
    if not contains(self.box,pos)then
        if require('slate_popup_navigation'):switch(self,self.owner,ges)then return true end
        return self:onClose()
    end
    for _,button in ipairs(self.tab_buttons or {}) do
        if contains(button,pos) then return self:changeTab(button.tab) end
    end
    if contains(self.tag_button,pos) and self.favourite_entry then
        require("slate_quotes"):tagQuote(self.favourite_entry,self);return true
    end
    if contains(self.favourite_button,pos) and self.favourite_entry then
        return self:toggleFavourite()
    end
    if contains(self.cover_link,pos) then return self:openBook() end
    if self.view=='description' and contains(self.search_query_link,pos) then
        return self:showSearchQuery()
    end
    if self.view=='description' and contains(self.menu_button,pos) then return self:showDescriptionMenu() end
    if self.view=='highlights' and (contains(self.book_page_link,pos) or contains(self.jump,pos)) then return self:jumpToText() end
    if contains(self.quote_prev,pos) then return self:turnHighlight(-1) end
    if contains(self.quote_next,pos) then return self:turnHighlight(1) end
    if contains(self.prev,pos) then return self:turn(-1) end
    if contains(self.next,pos) then return self:turn(1) end
    return true
end
function Popup:onHold(_,ges)
    if self.box and not contains(self.box,ges and ges.pos)then
        require('slate_popup_navigation'):switch(self,self.owner,ges,'hold')
        return true
    end
    if not contains(self.cover_link,ges and ges.pos) or self.cover_preview then return true end
    return Browser:showCoverPreview(self)
end
function Popup:onHoldRelease()return true end
function Popup:onSwipe(_,ges)
    if not ges or not contains(self.box,ges.pos) then return true end
    if ges.direction=='north' then return self:turnHighlight(1) end
    if ges.direction=='south' then return self:turnHighlight(-1) end
    if ges.direction=='west' then return self:turn(1) end
    if ges.direction=='east' then return self:turn(-1) end
    return true
end
function Popup:onClose() UIManager:close(self);return true end
function Popup:onCloseWidget()
    local parent=self.search_state and self.search_state.parent_quote
    if parent and not parent._closed and not self.search_switching then parent:startTimeout() end
    self.closed=true
    self.visible=false
    if self.cover_preview then UIManager:close(self.cover_preview);self.cover_preview=nil end
    if self.metadata_menu then UIManager:close(self.metadata_menu);self.metadata_menu=nil end
    if self.trace_notice then UIManager:close(self.trace_notice);self.trace_notice=nil end
    if self.trace_viewer then UIManager:close(self.trace_viewer);self.trace_viewer=nil end
    if self.loading_dialog then
        local dialog=self.loading_dialog;self.loading_dialog=nil
        dialog._slate_finished=true;UIManager:close(dialog)
    end
    if self.cover_task then UIManager:unschedule(self.cover_task) end
    if self.pagination_task then UIManager:unschedule(self.pagination_task);self.pagination_task=nil end
    if self.cover then self.cover:free();self.cover=nil end
    if self.header_title then self.header_title:free();self.header_title=nil end
    if self.view_icon then self.view_icon:free();self.view_icon=nil end
    if self.owner._slate_highlights_popup==self then self.owner._slate_highlights_popup=nil end
    if self.parent_popup and not self.parent_popup.closed then UIManager:setDirty(self.parent_popup,'ui') end
    UIManager:setDirty(nil,'ui')
end
function Browser:showCoverPreview(parent)
    if parent.cover_preview then return true end
    local ok,preview=pcall(CoverPreview.new,CoverPreview,{parent=parent})
    if ok then parent.cover_preview=preview;UIManager:show(Utils:themePopup(preview)) end
    return true
end
function Browser:show(owner,file,parent_popup,search_state)
    if owner._slate_highlights_popup then return end
    local ok,popup=pcall(Popup.new,Popup,{owner=owner,file=file,parent_popup=parent_popup,search_state=search_state})
    if not ok then
        UIManager:show(Utils:themePopup(InfoMessage:new{text=_('Could not load this book’s highlights.')}))
        return
    end
    owner._slate_highlights_popup=Utils:themePopup(popup)
    if not popup.closed and owner._slate_highlights_popup==popup then
        popup.visible=true
        UIManager:show(popup,'ui')
        if UIManager.forceRePaint then UIManager:forceRePaint() end
        UIManager:nextTick(function()
            if popup.closed then return end
            local prepared=pcall(popup.pagination_task)
            if not prepared then
                popup.pagination_loading=false
                popup.loading_error=_('Could not load this book’s highlights.')
                if popup.pagination_task then UIManager:unschedule(popup.pagination_task);popup.pagination_task=nil end
            end
            if not search_state then popup:loadDescription() end
        end)
    end
end
return Browser

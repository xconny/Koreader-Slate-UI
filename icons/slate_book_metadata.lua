-- SPDX-License-Identifier: AGPL-3.0-or-later
-- KOReader custom title/author metadata shared by Slate's book popups.
local DocSettings = require('docsettings')
local ReaderUI = require('apps/reader/readerui')
local BookInfo = require('apps/filemanager/filemanagerbookinfo')
local UIManager = require('ui/uimanager')
local Event = require('ui/event')
local Utils = require('slate_utils')
local _ = require('gettext')
local Metadata = {}
local function trim(value)
    return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end
local function copy(value)
    local result={}
    for k,v in pairs(type(value)=='table' and value or {}) do result[k]=v end
    return result
end
function Metadata:getProps(file)
    local reader=ReaderUI.instance
    local props=reader and reader.document and reader.document.file==file
        and reader.doc_props or DocSettings:open(file):readSetting('doc_props',{})
    props=copy(props)
    if type(BookInfo.extendProps)=='function' then
        local ok,extended=pcall(BookInfo.extendProps,props,file)
        if ok and type(extended)=='table' then props=extended end
    end
    return props
end
function Metadata:suggest(file)
    local name=tostring(file):match('([^/]+)$') or tostring(file)
    name=name:gsub('%.[%w]+$',''):gsub('_',' '):gsub('%*','')
        :gsub(' – ',' - '):gsub(' — ',' - ')
    repeat
        local previous=name
        name=name:gsub('%s*%(%d+%)%s*$',''):gsub('%s*%[%d+%]%s*$','')
        if name==previous then break end
    until false
    local title,author=name:match('^(.*)%s+%-%s+(.+)$')
    local props=self:getProps(file)
    if not title then
        title=name
        author=props.authors or props.author or ''
        if type(author)=='table' then author=table.concat(author,', ') end
    else
        local known=props.authors or props.author or ''
        if type(known)=='table' then known=table.concat(known,', ') end
        -- Use existing metadata to recognize Author - Title filenames.
        if trim(known):lower()==trim(title):lower() then title,author=author,title end
    end
    title,author=trim(title),trim(author)
    local stem,article=title:match('^(.-),%s*([Tt][Hh][Ee])$')
    if stem then title=article..' '..stem end
    return title,author
end
function Metadata:apply(file,title,author)
    title,author=trim(title),trim(author)
    if title=='' then return false,_('Enter a book title.') end
    local ok,result=pcall(function()
        if type(DocSettings.openSettingsFile)~='function'
            or type(DocSettings.flushCustomMetadata)~='function' then
            error('This KOReader version cannot save custom book metadata.')
        end
        local path=DocSettings:findCustomMetadataFile(file)
        local settings=DocSettings.openSettingsFile(path)
        local props=copy(settings:readSetting('doc_props'))
        if next(props)==nil then props=copy(DocSettings:open(file):readSetting('doc_props',{})) end
        local custom=copy(settings:readSetting('custom_props',{}))
        custom.title,custom.authors=title,author
        -- KOReader requires both tables in custom_metadata.lua.
        settings:saveSetting('doc_props',props)
        settings:saveSetting('custom_props',custom)
        if not settings:flushCustomMetadata(file) then error('Could not write book metadata.') end
        local reader=ReaderUI.instance
        if reader and reader.document and reader.document.file==file then
            reader.doc_settings:getCustomMetadataFile(true)
            reader.doc_props=self:getProps(file)
            reader.doc_props.title,reader.doc_props.display_title,reader.doc_props.authors=title,title,author
        end
        UIManager:broadcastEvent(Event:new('InvalidateMetadataCache',file))
        UIManager:broadcastEvent(Event:new('BookMetadataChanged'))
        return self:getProps(file)
    end)
    if not ok then return false,tostring(result) end
    local loaded,descriptions=pcall(require,'slate_book_descriptions')
    if loaded and type(descriptions.metadataChanged)=='function' then
        local refreshed,err=pcall(descriptions.metadataChanged,descriptions,file,result)
        if not refreshed then require('logger').warn('Slate: could not refresh edited book description:',tostring(err)) end
    end
    return true,result
end
function Metadata:edit(file,onDone)
    local MultiInputDialog=require('ui/widget/multiinputdialog')
    local InfoMessage=require('ui/widget/infomessage')
    local title,author=self:suggest(file)
    local dialog
    dialog=MultiInputDialog:new{
        modal=true,title=_('Edit book metadata'),
        fields={
            {text=title,hint=_('Title'),description=_('Title')},
            {text=author,hint=_('Author'),description=_('Author')},
        },
        buttons={{
            {text=_('Cancel'),id='close',callback=function() UIManager:close(dialog) end},
            {text=_('Apply'),callback=function()
                local values=dialog:getFields()
                local ok,props=self:apply(file,values[1],values[2])
                if not ok then
                    UIManager:show(Utils:themePopup(InfoMessage:new{modal=true,text=props}))
                    return
                end
                UIManager:close(dialog)
                if onDone then onDone(props) end
            end},
        }},
    }
    UIManager:show(Utils:themePopup(dialog))
    dialog:onShowKeyboard()
    return dialog
end
return Metadata

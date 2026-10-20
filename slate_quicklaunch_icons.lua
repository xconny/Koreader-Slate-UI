-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Approved Slate launcher artwork; custom paths are keyed by actual menu ID.
local Icons={}
local source=debug.getinfo(1,'S').source
local directory=source:sub(1,1)=='@'and(source:sub(2):match('(.*/)')or '')or ''
local aliases={}
local function normalize(value)
    return tostring(value or ''):lower():gsub('%.koplugin$',''):gsub('%b()',''):gsub('[^%w]','')
end
local function add(file,names)
    for name in names:gmatch('[^,]+')do aliases[normalize(name)]=file end
    aliases[normalize(file)]=file
end
add('backgammon','backgammon')
add('battleship','battleship')
add('checkers','checkers,draughts')
add('chess','chess,kochess')
add('connect-four','connect4,connectfour,connectfourgame')
add('crossword','crossword')
add('hangman','hangman')
add('mahjong','mahjong,mahjongsolitaire')
add('memory','memory,memorygame')
add('minesweeper','minesweeper')
add('nonogram','nonogram,nonograms')
add('senet','senet')
add('sokoban','sokoban')
add('solitaire','solitaire')
add('sudoku','sudoku')
add('tic-tac-toe','tictactoe')
add('word-search','wordsearch')
add('wordle','wordle,kowordle')
add('ai-assistant','assistant,aiassistant,assistantmain')
add('bookdrop','bookdrop,bookdropstore')
add('calibre','calibre')
add('cloud-storage','cloudstorage,cloudstorageplus')
add('filebrowserplus','filebrowserplus,filebrowser')
add('opds-catalog','opds,opdscatalog')
add('storefront','storefront')
add('tarot-reader','tarot,tarotreader')
add('terminal','terminal,terminalemulator')
add('text-editor','texteditor')
add('wallabag','wallabag')
add('zlibrary','zlibrary,zlibrarymain')
function Icons:key(entry)return 'slate.quicklaunch_icons.path.'..tostring(entry.id)end
function Icons:placeholderKey(entry)return 'slate.quicklaunch_icons.keep_placeholder.'..tostring(entry.id)end
function Icons:keepPlaceholder(entry)
    G_reader_settings:saveSetting(self:placeholderKey(entry),true)
    G_reader_settings:flush()
end
function Icons:needsChoice(entry)
    local _,placeholder=self:getPath(entry)
    return placeholder==true and G_reader_settings:readSetting(self:placeholderKey(entry),false)~=true
end
function Icons:enabled()return G_reader_settings:readSetting('slate.quicklaunch_icons.enabled',true)==true end
local function exists(path)
    if type(path)~='string'or path==''then return false end
    local file=io.open(path,'rb');if file then file:close();return true end
    return false
end
function Icons:getDefault(entry)
    if entry.system_action then
        local name=entry.system_action
        if name=='wifi'or name=='bluetooth'or name=='restart'or name=='exit'then return directory..'icons/quicklaunch/'..name..'.svg'end
    end
    local plugin=entry.plugin or {}
    for _,value in ipairs({plugin.name or '',entry.context_plugin or '',entry.id or '',entry.text or ''})do
        local name=normalize(value)
        local file=aliases[name]or aliases[name:gsub('main$','')]
        if file then return directory..'icons/quicklaunch/'..file..'.svg'end
    end
end
function Icons:getPath(entry)
    if not self:enabled()then return end
    local custom=G_reader_settings:readSetting(self:key(entry))
    if exists(custom)then return custom,false end
    local default=self:getDefault(entry)
    if exists(default)then return default,false end
    local placeholder=directory..'icons/quicklaunch/placeholder.svg'
    if exists(placeholder)then return placeholder,true end
end
return Icons

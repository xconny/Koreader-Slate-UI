-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Downloaded book descriptions and a persistent offline cache for Slate.
local DataStorage = require('datastorage')
local UIManager = require('ui/uimanager')
local FFIUtil = require('ffi/util')
local DocSettings = require('docsettings')
local util = require('util')
local json = require('json')
local logger = require('logger')
local Descriptions = {BUILD="2026-10-14 staged title queries / Wikipedia literary and translator checks / deduplicated lookups 22"}
local queue, queued, callbacks = {}, {}, {}
local memory_cache = {}
local job, poll_task, kick_task, suspended
local CACHE_AGE, RETRY_AGE = 30 * 86400, 86400
local MATCH_VERSION = 22
local NO_LIBRARY_DESCRIPTION='Open Library found matching records, but the records checked supplied no usable description.'
local function trace(self,message)
    if not self._trace or #self._trace>=100 then return end
    message=tostring(message)
    local key=G_reader_settings:readSetting('slate.descriptions.google_api_key','')
    if type(key)=='string' and key~='' then message=message:gsub(key:gsub('([^%w])','%%%1'),'[redacted]') end
    message=message:gsub('AIza[%w_%-]+','[redacted]')
    self._trace[#self._trace+1]=message:sub(1,700)
end

local function encode(value)
    return (tostring(value or ''):gsub('([^%w%-%._~])',function(c) return string.format('%%%02X',c:byte()) end))
end
local function fold(value)
    local text=tostring(value or '')
    local groups={a='ÀÁÂÃÄÅàáâãäåāĀ',e='ÈÉÊËèéêëēĒ',i='ÌÍÎÏìíîïīĪ',o='ÒÓÔÕÖòóôõöōŌ',u='ÙÚÛÜùúûüūŪ',n='Ññ',c='Çç',s='ŚśŠš',z='Žž'}
    for plain,letters in pairs(groups)do
        for letter in letters:gmatch('[%z\1-\127\194-\244][\128-\191]*')do text=text:gsub(letter,plain)end
    end
    return text:gsub('ß','ss'):gsub('[\204\205][\128-\191]',''):lower()
end
local function normalize(value)
    return fold(value):gsub('[%p%c]',' '):gsub('%s+',' '):gsub('^%s+',''):gsub('%s+$','')
end
-- Remove extensions before punctuation so “epub” never becomes a search word.
local function searchText(value)
    local text=tostring(value or ''):lower():gsub('%.[Ee][Pp][Uu][Bb]$', '')
        :gsub('%.[Pp][Dd][Ff]$', ''):gsub('%.[Mm][Oo][Bb][Ii]$', '')
        :gsub('%.[Aa][Zz][Ww]3?$', ''):gsub('–', ' '):gsub('—', ' ')
        :gsub('‘', "'"):gsub('’', "'"):gsub('“', ' '):gsub('”', ' ')
    -- Keep apostrophes in the query; replace other filename punctuation.
    return text:gsub('[%p%c]',function(c) return c=="'" and c or ' ' end)
        :gsub('%s+',' '):gsub('^%s+',''):gsub('%s+$','')
end
local function authors(value)
    if type(value)=='table' then return table.concat(value,', ') end
    return tostring(value or '')
end
local function directory()
    local path=DataStorage:getDataDir() .. '/cache/slate-book-descriptions/'
    util.makePath(path)
    return path
end
local function cachePath(file)
    local a,b=5381,2166136261
    for i=1,#file do local v=file:byte(i);a=(a*33+v)%4294967296;b=(b*65599+v)%4294967296 end
    return directory() .. string.format('%08x%08x',a,b) .. '.json'
end
local function readCache(file,prefer_disk)
    if not prefer_disk and memory_cache[file] then return memory_cache[file] end
    local ok,path=pcall(cachePath,file)
    if not ok then return memory_cache[file] end
    local f=io.open(path,'r');if not f then return memory_cache[file] end
    local bytes=f:read('*all');f:close()
    local decoded,data=pcall(json.decode,bytes)
    if decoded and type(data)=='table' and data.version==1 and data.file==file and type(data.identity)=='table' then return data end
    return memory_cache[file]
end
local function writeCache(file,data)
    data.version,data.file=1,file
    data.cache_error=nil
    -- The UI owns the current status. Disk is for persistence, never the
    -- only way to hand an update back to the caller that just wrote it.
    memory_cache[file]=data
    local function failed(message)
        data.cache_error=message;memory_cache[file]=data
        logger.warn('Slate: description cache failed:',message)
        return false,message
    end
    local ok,bytes=pcall(json.encode,data)
    if not ok or type(bytes)~='string' then return failed('Could not encode the description cache.') end
    local located,path=pcall(cachePath,file)
    if not located then return failed('Could not create the description cache directory.') end
    local f,err=io.open(path..'.tmp','w')
    if not f then return failed('Could not open the description cache for writing: '..tostring(err or 'storage unavailable')) end
    local written,write_error=f:write(bytes)
    local closed,close_error=f:close()
    if not written or not closed then
        os.remove(path..'.tmp')
        return failed('Could not write the description cache: '..tostring(write_error or close_error or 'storage unavailable'))
    end
    local renamed,rename_error=os.rename(path..'.tmp',path)
    if renamed then return true end
    os.remove(path..'.tmp')
    return failed('Could not commit the description cache: '..tostring(rename_error or 'storage unavailable'))
end
local function cleanDescription(value,min_length)
    if type(value)=='table' then value=value.value end
    if type(value)~='string' then return nil end
    value=value:gsub('<[Ss][Cc][Rr][Ii][Pp][Tt].->.-</[Ss][Cc][Rr][Ii][Pp][Tt]%s*>','')
        :gsub('<[Bb][Rr]%s*/?>','\n'):gsub('</[Pp]%s*>','\n\n'):gsub('<[^>]*>','')
    local entities={amp='&',lt='<',gt='>',quot='"',apos="'",nbsp=' ',ndash='–',mdash='—',lsquo='‘',rsquo='’',ldquo='“',rdquo='”'}
    value=value:gsub('&([%a]+);',function(name) return entities[name] or '&'..name..';' end)
    value=value:gsub('&#([xX]?[%da-fA-F]+);',function(number)
        local n=number:sub(1,1):lower()=='x' and tonumber(number:sub(2),16) or tonumber(number)
        if not n or n<1 or n>1114111 or (n>=55296 and n<=57343) then return '' end
        if n<128 then return string.char(n)
        elseif n<2048 then return string.char(192+math.floor(n/64),128+n%64)
        elseif n<65536 then return string.char(224+math.floor(n/4096),128+math.floor(n/64)%64,128+n%64)
        else return string.char(240+math.floor(n/262144),128+math.floor(n/4096)%64,128+math.floor(n/64)%64,128+n%64) end
    end)
    value=value:gsub('\r',''):gsub('[ \t]+',' '):gsub('\n +','\n'):gsub('\n\n\n+','\n\n'):gsub('^%s+',''):gsub('%s+$','')
    if #value<(min_length or 40) then return nil end
    return value:sub(1,60000)
end
local function viableEmbedded(value)
    local text=cleanDescription(value,1)
    local words=0
    for _ in (text or ''):gmatch('%S+') do words=words+1 end
    return words>=15 and text or nil
end
local function isbn(value)
    if type(value)~='string' then return nil end
    value=value:gsub('[%s%-]',''):upper():gsub('^ISBN:?','')
    if #value==13 and value:match('^%d+$') then
        local sum=0;for i=1,13 do sum=sum+tonumber(value:sub(i,i))*(i%2==0 and 3 or 1) end
        if sum%10==0 then return value end
    elseif #value==10 and value:match('^%d%d%d%d%d%d%d%d%d[%dX]$') then
        local sum=0;for i=1,10 do local c=value:sub(i,i);sum=sum+(c=='X' and 10 or tonumber(c))*(11-i) end
        if sum%11==0 then return value end
    end
end
local function filenameIdentity(file)
    local name = tostring(file):match('([^/]+)$') or tostring(file)
    name = name:gsub('%.[%w]+$', ''):gsub('_', ' ')
        :gsub(' – ', ' - '):gsub(' — ', ' - ')
    repeat
        local previous = name
        name = name:gsub('%s*%(%d+%)%s*$', ''):gsub('%s*%[%d+%]%s*$', '')
            :gsub('%s*%([Zz]%-[Ll]ibrary%)%s*$','')
        if previous == name then break end
    until false
    local function clean(value)
        value = value:gsub('^%s+', ''):gsub('%s+$', '')
        local title, article = value:match('^(.-),%s*([Tt][Hh][Ee])$')
        if not title then title, article = value:match('^(.-),%s*([Aa][Nn]?)$') end
        return title and (article .. ' ' .. title) or value
    end
    local left, right = name:match('^(.-)%s+%-%s+([^%-]+)$')
    if left and right then
        return clean(left), clean(right), {title=clean(right),author=clean(left)}
    end
    local title,author=name:match('^(.-)%s*%(([^()]+)%)%s*$')
    if title and author and not author:find('%d') and not author:lower():find('edition',1,true) then
        return clean(title),clean(author)
    end
    return clean(name), ''
end
local function identity(file,props)
    props=type(props)=='table' and props or DocSettings:open(file):readSetting('doc_props',{}) or {}
    local loaded,bookinfo=pcall(require,'apps/filemanager/filemanagerbookinfo')
    if loaded and type(bookinfo.extendProps)=='function' then
        local ok,extended=pcall(bookinfo.extendProps,props,file)
        if ok and type(extended)=='table' then props=extended end
    end
    local title=tostring(props.title or '')
    if title=='' then title=tostring(props.display_title or '') end
    local author=authors(props.authors or props.author)
    local filename_title, filename_author, alternative = filenameIdentity(file)
    local needs_metadata = title == '' or title:match('%.[Ee][Pp][Uu][Bb]$')
        or title:match('%.[Pp][Dd][Ff]$')
    if title == '' or title:match('%.[Ee][Pp][Uu][Bb]$') or title:match('%.[Pp][Dd][Ff]$') then
        title=filename_title
    end
    local stem, article = title:match('^(.-),%s*([Tt][Hh][Ee])$')
    if stem then title=article .. ' ' .. stem end
    if author == '' or normalize(author) == 'unknown' then author=filename_author end
    local id=isbn(props.isbn) or isbn(props.isbn13) or isbn(props.isbn10)
    if not id and type(props.identifiers)=='table' then
        for _,v in pairs(props.identifiers) do id=isbn(type(v)=='table' and v.identifier or v);if id then break end end
    end
    return {title=title,author=author,isbn=id,language=props.language,
        needs_metadata=needs_metadata,filename_alternative=alternative,
        filename_identity=filename_author~='' and {title=filename_title,author=filename_author} or nil,
        signature=normalize(title)..'|'..normalize(author)..'|'..tostring(id or '')}
end
local function cleanLookupTitle(value,author)
    local text=tostring(value or ''):gsub('%.[Ee][Pp][Uu][Bb]$',''):gsub('%.[Pp][Dd][Ff]$','')
        :gsub('__i_',''):gsub('_i_',''):gsub('</?[iI]>',''):gsub(' – ',' - '):gsub(' — ',' - ')
        :gsub('%s*%(%d+%)%s*$',''):gsub('%s*%[%d+%]%s*$','')
    local left,right=text:match('^(.-)%s+%-%s+(.+)$')
    if right and normalize(right)==normalize(author)then text=left
    elseif left and normalize(left)==normalize(author)then text=right end
    text=text:gsub('%s*%([Zz]%-[Ll]ibrary%)','')
    if author and author~='' then
        text=text:gsub('%s*%(([^()]+)%)',function(part)
            return normalize(part)==normalize(author) and '' or ' ('..part..')'
        end)
    end
    text=text:gsub('%f[%a]thd%f[%A]','the')
        :gsub('%s*%(%d%d%d%d[^)]*%)',''):gsub('%s*%([^)]*[Ss]eries[^)]*%)','')
        :gsub('%s*%([^)]*[Ee]ditions?[^)]*%)',''):gsub('_+',': '):gsub('%s+',' '):gsub('^%s+',''):gsub('%s+$','')
    local base,article=text:match('^(.-),%s*([Tt][Hh][Ee])$')
    if base then text=article..' '..base end
    text=text:gsub(',%s*([Tt]he [Aa]utobiography)',': %1')
        :gsub(',%s*([Pp]oems of)',': %1')
    return text
end
local function lookupTitles(value)
    local full=cleanLookupTitle(value,'')
    local values,seen={},{}
    local function add(title)
        title=tostring(title or ''):gsub('^%s+',''):gsub('%s+$','')
        local key=searchText(fold(title))
        if key~='' and not seen[key] then seen[key]=true;values[#values+1]=title end
    end
    add(full)
    local base=full:match('^(.-):')
    if base then add(base)end
    local volume=full:match('^(.-)%s+[Vv]olume%s+[%dIVXivx]+%s*$')
    if volume then add(volume)end
    local aliases={
        ['the book of master lie']='The Book of Lieh-tzu',
        ['book of master lie']='The Book of Lieh-tzu',
        ['hsin hsin ming']='Xinxin Ming',
    }
    add(aliases[searchText(fold(full))])
    return values
end
local function oneLetterApart(a,b)
    if a==b then return true end
    if math.min(#a,#b)<7 or math.abs(#a-#b)>1 then return false end
    local i,j,edits=1,1,0
    while i<=#a and j<=#b do
        if a:sub(i,i)==b:sub(j,j)then i=i+1;j=j+1
        else edits=edits+1;if edits>1 then return false end
            if #a>#b then i=i+1 elseif #b>#a then j=j+1 else i=i+1;j=j+1 end
        end
    end
    return edits+(#a-i+1)+(#b-j+1)<=1
end
local function matches(wanted,title,candidate_authors)
    local function titleKey(value)
        -- Apostrophe variants and an omitted apostrophe refer to the same title.
        return searchText(fold(cleanLookupTitle(value,wanted.author))):gsub("'", ''):gsub('%f[%a]thd%f[%A]','the'):gsub('%f[%a]teachings%f[%A]','teaching'):gsub('^the ', ''):gsub('^an ', ''):gsub('^a ', '')
    end
    local a,b=titleKey(wanted.title),titleKey(title)
    local base_a,base_b=titleKey(tostring(wanted.title or ''):match('^[^:]+')),
        titleKey(tostring(title or ''):match('^[^:]+'))
    local same=a==b or (base_a~='' and base_a==base_b)
    local volume_a=a:match('^(.-)%s+volume%s+[%divx]+$')
    if volume_a==b then same=true end -- General work description for this volume.
    -- A subtitle containing collection/complete-edition information cannot
    -- identify a biography with just the author's name as its title.
    if a~=b and (a:find('complete digital edition',1,true) or a:find('collected works',1,true))then same=false end
    -- Bilingual editions often put the English title after a slash.
    for part in tostring(title or ''):gmatch('[^/]+')do
        if titleKey(part)==a then same=true end
    end
    local lieh={['book of master lie']=true,['book of lieh tzu']=true,['lieh tzu']=true}
    if lieh[a] and lieh[b]then same=true end
    local function words(value)
        local tokens,n={},0
        for word in value:gmatch('%S+')do
            if word~='the' and word~='a' and word~='an' and word~='and' and word~='of' and word~='in' and word~='on' and word~='for' then tokens[word]=true end
            n=n+1
        end
        return tokens,n
    end
    if not same then
        local ta,na=words(a);local tb,nb=words(b)
        local equal=true;for word in pairs(ta)do if not tb[word]then equal=false end end;for word in pairs(tb)do if not ta[word]then equal=false end end
        same=equal and na>=3 and nb>=3
        local function subtitle(short,long)
            local _,count=words(short)
            local suffix=long:sub(#short+2)
            return count>=3 and #short>=12 and long:sub(1,#short+1)==short..' '
                and not suffix:find('^volume ') and not suffix:find('^book %d') and not suffix:find('summary',1,true) and not suffix:find('workbook',1,true)
                and not suffix:find('study guide',1,true) and not suffix:find('companion',1,true)
        end
        same=same or subtitle(a,b) or subtitle(b,a)
    end
    if a=='' or not same then return false,'title differs' end
    -- Query by title only, but verify author metadata when both sides have it.
    -- Catalogs commonly omit Buddhist honorifics from an author's name.
    local function nameTokens(value)
        local tokens,count={},0
        for word in normalize(value):gmatch('%S+') do
            if word~='geshe' and word~='venerable' and word~='rinpoche' and word~='st' and word~='saint'
                and word~='unknown' and word~='swami' and word~='yogi' and word~='roshi' and word~='zen' and word~='master' and not tokens[word] then
                tokens[word]=true;count=count+1
            end
        end
        return tokens,count
    end
    local wanted_tokens,wanted_count=nameTokens(wanted.author)
    if wanted_count==0 or candidate_authors==nil then return true end
    local values=type(candidate_authors)=='table' and candidate_authors or {candidate_authors}
    if #values==0 then return true end
    for _,name in ipairs(values) do
        local tokens,count=nameTokens(name)
        if count==0 then return true end
        local common=0;for word in pairs(wanted_tokens) do if tokens[word] then common=common+1 end end
        if common==1 and count==1 then
            for token in pairs(tokens)do if #token>=8 and wanted_tokens[token]then return true end end
        end
        if count==1 then
            for token in pairs(tokens)do for word in pairs(wanted_tokens)do
                if #token>=8 and oneLetterApart(word,token)then return true end
            end end
        end
        local covered,exact,initial=0,0,0
        for word in pairs(wanted_tokens)do
            for token in pairs(tokens)do
                if word==token or oneLetterApart(word,token)then covered=covered+1;if #word>1 then exact=exact+1 end;break
                elseif #word==1 and word==token:sub(1,1)then covered=covered+1;initial=initial+1;break end
            end
        end
        if exact>=1 and ((initial>0 and covered==wanted_count) or (covered>=2 and covered==wanted_count))then return true end
        if common==1 and count==1 and tokens.anonymous and wanted_tokens.anonymous then return true end
        if common>=2 and (common==count or common==wanted_count)
            or common==1 and count==1 and wanted_count==1 then return true end
    end
    -- These classical works are routinely catalogued under their original
    -- author rather than an edition's translator. Exact work title plus the
    -- canonical author is required; generic titles never bypass author checks.
    local classical={
        ['hua hu ching']={'lao tzu','laozi','老子'},
        ['hsin hsin ming']={'sengtsan','seng can'},
        ['zen teaching of rinzai']={'lin chi','yixuan'},
        ['book of master lie']={'lieh tzu','liezi'},
        ['book of lieh tzu']={'lieh tzu','liezi'},
    }
    if wanted.allow_classical and classical[a] and (a==b or lieh[a] and lieh[b])then
        for _,name in ipairs(values)do for _,canonical in ipairs(classical[a])do
            if normalize(name)==canonical then return true,'classical work title and original author; edition translator differs' end
        end end
    end
    return false,'author differs'
end
function Descriptions:requestJSON(url)
    local cached=self._request_cache and self._request_cache[url]
    if cached then
        self._last_error,self._last_error_transient=cached.error,cached.transient
        trace(self,'Reusing identical provider query in this lookup')
        return cached.data
    end
    local data=self:_requestJSON(url)
    if self._request_cache then
        self._request_cache[url]={data=data,error=self._last_error,transient=self._last_error_transient}
    end
    return data
end
function Descriptions:_requestJSON(url)
    local available,https=pcall(require,'ssl.https')
    local provider=url:find('googleapis.com',1,true) and 'Google Books'
        or url:find('wikipedia.org',1,true) and 'Wikipedia' or 'Open Library'
    local cooldown_path,now=directory()..'wikipedia-cooldown',os.time()
    if provider=='Wikipedia' then
        local f=io.open(cooldown_path,'r')
        local until_time=f and tonumber(f:read('*all')) or 0
        if f then f:close() end
        if (until_time or 0)>now then
            self._last_error='Wikipedia requests paused until '..os.date('%Y-%m-%d %H:%M:%S',until_time)..' after a rate limit or recent request.'
            self._last_error_transient=true
            trace(self,self._last_error);return nil
        end
        local f=io.open(cooldown_path,'w');if f then f:write(tostring(now+3));f:close() end
    end
    if not available then
        self._last_error='HTTPS support is unavailable.';self._last_error_transient=false;return nil
    end
    local has_timeout,socketutil=pcall(require,'socketutil')
    for attempt=1,3 do
        local body,total={},0
        local old_timeout=https.TIMEOUT;https.TIMEOUT=12
        if has_timeout and type(socketutil.set_timeout)=='function' then
            pcall(socketutil.set_timeout,socketutil,6,12)
        end
        local ok,result,code,response_headers=pcall(https.request,{
            url=url,redirect=false,
            headers={['User-Agent']='Slate-KOReader/1.1 (KOReader plugin; https://github.com/koreader/koreader)',Accept='application/json'},
            sink=function(chunk)
                if chunk then total=total+#chunk;if total>2097152 then return nil,'Response too large' end;body[#body+1]=chunk end
                return 1
            end,
        })
        if has_timeout and type(socketutil.reset_timeout)=='function' then pcall(socketutil.reset_timeout,socketutil) end
        https.TIMEOUT=old_timeout
        local status=tonumber(code)
        trace(self,provider..': HTTP '..tostring(status or 'connection failed')..' (attempt '..attempt..')')
        if ok and result and status==200 then
            local parsed,data=pcall(json.decode,table.concat(body))
            if parsed and type(data)=='table' then return data end
            self._last_error=provider..' returned invalid JSON.';self._last_error_transient=true;return nil
        end
        if provider=='Wikipedia' and status==429 then
            local retry=type(response_headers)=='table' and tonumber(response_headers['retry-after'] or response_headers['Retry-After'])
            local until_time=os.time()+math.max(60,retry or 300)
            local f=io.open(cooldown_path,'w');if f then f:write(tostring(until_time));f:close() end
            trace(self,'Wikipedia shared cooldown: '..tostring(until_time)..'; Retry-After seconds: '..tostring(retry or 'not supplied'))
        end
        self._last_error_transient=not status or status==429 or status>=500
        if provider=='Google Books' and status==400 then
            self._last_error='Google Books rejected the request (HTTP 400). Check the API key.'
        elseif provider=='Google Books' and (status==401 or status==403) then
            self._last_error='Google Books denied access (HTTP '..status..'). Enable Books API and check the API key restrictions.'
        elseif status==429 then self._last_error=provider..' rate limit reached (HTTP 429). Try again later.'
        elseif status then self._last_error=provider..' returned HTTP '..status..'.'
        else self._last_error=provider..' could not be reached. The HTTPS connection failed.' end
        if provider=='Google Books' and status then
            local decoded,response=pcall(json.decode,table.concat(body))
            local err=decoded and type(response)=='table' and response.error
            if type(err)=='table' and type(err.message)=='string' then
                local message=err.message
                local key=G_reader_settings:readSetting('slate.descriptions.google_api_key','')
                if type(key)=='string' and key~='' then
                    message=message:gsub(key:gsub('([^%w])','%%%1'),'[redacted]')
                end
                message=message:gsub('AIza[%w_%-]+','[redacted]'):sub(1,500)
                self._last_error='Google Books returned HTTP '..status..': '..message
            end
        end
        if not (status and status>=500 and status<=599 and attempt<3) then break end
        local loaded,socket=pcall(require,'socket')
        if loaded and type(socket.sleep)=='function' then socket.sleep(1) end
    end
    logger.warn('Slate: description request failed:',self._last_error)
    return nil
end
local function openLibrary(self,wanted)
    local function workDescription(key)
        if type(key)~='string' then return nil end
        if key:match('^/works/OL%d+M$')then
            trace(self,'Normalizing legacy Open Library edition key '..key..' to /books/')
            key=key:gsub('^/works/','/books/')
        end
        if key:match('^/books/OL%d+M$')then
            local edition=self:requestJSON('https://openlibrary.org'..key..'.json')
            local value=edition and cleanDescription(edition.description)
            trace(self,'OL directly matched edition '..key..': '..(value and #value..' description characters' or 'no usable description'))
            if value then return value,'https://openlibrary.org'..key end
            for _,work in ipairs(edition and edition.works or {})do
                local text,url=workDescription(work.key)
                if text then return text,url end
            end
            if edition then self._last_error=NO_LIBRARY_DESCRIPTION;self._last_error_transient=false end
            return nil
        end
        if not key:match('^/works/OL%d+W$') then return nil end
        local work=self:requestJSON('https://openlibrary.org'..key..'.json')
        local description=work and cleanDescription(work.description)
        trace(self,'Open Library work '..key..': '..(description and (#description..' description characters')
            or work and 'no usable description' or 'request failed'))
        if work and not description then
            trace(self,'Matching work has no usable description; checking up to ten linked editions.')
            local editions=self:requestJSON('https://openlibrary.org'..key..'/editions.json?limit=10')
            for _,edition in ipairs(editions and editions.entries or {}) do
                local value=cleanDescription(edition.description)
                trace(self,'OL edition '..tostring(edition.key)..': '..(value and #value..' description characters' or 'no usable description'))
                if value then return value,'https://openlibrary.org'..tostring(edition.key or key) end
            end
            if editions then self._last_error=NO_LIBRARY_DESCRIPTION;self._last_error_transient=false
            else self._last_error='Open Library found a matching work without a description; its editions could not be checked. '..tostring(self._last_error or '') end
        end
        return description, 'https://openlibrary.org'..key
    end
    if searchText(wanted.title)=='' then return nil end
    trace(self,'Open Library search title: ['..searchText(wanted.title)..']')
    trace(self,'Open Library request field: title. Author is not queried; returned author names are checked for a match.')
    local result=self:requestJSON('https://openlibrary.org/search.json?limit=30&fields=key,title,author_name&title='
        ..encode(searchText(fold(wanted.title))))
    if result then
        local merged,seen={docs={}},{}
        local function merge(response)
            for _,item in ipairs(response and response.docs or {})do
                local key=tostring(item.key)..'|'..tostring(item.title)
                if not seen[key]then seen[key]=true;merged.docs[#merged.docs+1]=item end
            end
        end
        merge(result)
        local variants=lookupTitles(wanted.title)
        for i=2,#variants do
            trace(self,'Open Library alternate title field: ['..variants[i]..']; candidate must still match the book identity')
            local alternate=self:requestJSON('https://openlibrary.org/search.json?limit=30&fields=key,title,author_name&title='
                ..encode(searchText(fold(variants[i]))))
            if not alternate and #merged.docs==0 then return nil end
            merge(alternate)
        end
        result=merged
    end
    local candidates,contributor_candidates={},{}
    trace(self,'Open Library search returned '..tostring(result and #(result.docs or {}) or 'no')..' records')
    for _,item in ipairs(result and result.docs or {}) do
        local accepted,reason=matches(wanted,item.title,item.author_name)
        trace(self,'OL '..tostring(item.key)..': ['..tostring(item.title)..'] / ['..authors(item.author_name)..'] — '
            ..(accepted and ('accepted '..(reason or 'title/author match')..'; description still needs checking') or 'rejected: '..tostring(reason)))
        if accepted then candidates[#candidates+1]=item
        elseif reason=="author differs" and matches({title=wanted.title,author=""},item.title,{})then contributor_candidates[#contributor_candidates+1]=item end
    end
    trace(self,'Open Library accepted '..#candidates..' of '..tostring(result and #(result.docs or {}) or 0)..' returned records')
    if result and #candidates==0 then
        self._last_error=#(result.docs or {})==0 and 'Open Library returned no records for the search title.'
            or 'Open Library returned records, but none passed Slate’s title and author matching checks.'
        self._last_error_transient=false
    end
    local seen={}
    local attempts=0
    for _,candidate in ipairs(candidates) do
        if not seen[candidate.key] then
            seen[candidate.key]=true;attempts=attempts+1
            local text,url=workDescription(candidate.key)
            if text then return text,url,'Open Library' end
            if attempts>=10 then break end
        end
    end    for index,item in ipairs(contributor_candidates)do
        if index>3 then break end
        if type(item.key)=='string' and (item.key:match('^/works/OL%d+W$') or item.key:match('^/books/OL%d+M$'))then
            local editions
            if item.key:match('^/books/')then
                local edition=self:requestJSON('https://openlibrary.org'..item.key..'.json');editions=edition and {entries={edition}}
            else editions=self:requestJSON('https://openlibrary.org'..item.key..'/editions.json?limit=5')end
            local verified=false
            for _,edition in ipairs(editions and editions.entries or {})do
                local names={}
                if type(edition.by_statement)=='string' then names[#names+1]=edition.by_statement end
                for _,contributor in ipairs(edition.contributors or {})do
                    if type(contributor)=='table' and type(contributor.name)=='string' then names[#names+1]=contributor.name end
                end
                if #names>0 and matches(wanted,item.title,names)then
                    verified=true
                    trace(self,'OL '..item.key..': author/translator verified in edition '..tostring(edition.key)..' via contributors/by_statement')
                    local value=cleanDescription(edition.description)
                    if value then return value,'https://openlibrary.org'..tostring(edition.key),'Open Library' end
                    break
                end
            end
            if verified then
                local text,url=workDescription(item.key)
                if text then return text,url,'Open Library' end
            end
        end
    end
    local classical_wanted={title=wanted.title,author=wanted.author,allow_classical=true}
    for _,item in ipairs(contributor_candidates)do
        local accepted,reason=matches(classical_wanted,item.title,item.author_name)
        if accepted then
            trace(self,'OL '..tostring(item.key)..': fallback accepted — '..tostring(reason))
            local text,url=workDescription(item.key)
            if text then return text,url,'Open Library' end
        end
    end
end
local function googleBooks(self,wanted)
    local key=G_reader_settings:readSetting('slate.descriptions.google_api_key')
    if type(key)=='string' then key=key:gsub('^%s+',''):gsub('%s+$','') end
    if type(key)~='string' or key=='' then return nil end
    local titles=lookupTitles(wanted.title)
    local queries={'intitle:"'..searchText(titles[1])..'"',searchText(titles[1])}
    if titles[2]then queries[#queries+1]=searchText(titles[2])end
    local seen,found,matched,details={},false,false,0
    local detail_error,detail_transient
    for _,query in ipairs(queries)do
        trace(self,'Google search query: ['..query..']')
        trace(self,'Google request field: q; title-only staged query. Returned title and author are verified; broader query does not relax author checks.')
        local result=self:requestJSON('https://www.googleapis.com/books/v1/volumes?maxResults=20&printType=books&q='
            ..encode(query)..'&key='..encode(key))
        if not result then return nil end -- Do not multiply failed-service requests.
        trace(self,'Google search returned '..#(result.items or {})..' records')
        for _,item in ipairs(result.items or {})do
            local info=item.volumeInfo or {}
            local accepted,reason=matches(wanted,info.title,info.authors)
            local text=cleanDescription(info.description)
            found=true;matched=matched or accepted
            trace(self,'Google '..tostring(item.id)..': ['..tostring(info.title)..'] / ['..authors(info.authors)..'] — '
                ..(accepted and 'accepted title/author match' or 'rejected: '..tostring(reason))..'; '
                ..(text and (#text..' description characters') or 'no usable description'))
            if accepted and not text and type(item.id)=='string' and not seen[item.id] and details<3 then
                seen[item.id]=true;details=details+1
                local detail=self:requestJSON('https://www.googleapis.com/books/v1/volumes/'..encode(item.id)..'?key='..encode(key))
                if not detail then detail_error,detail_transient=self._last_error,self._last_error_transient end
                local full=detail and detail.volumeInfo or {}
                if matches(wanted,full.title,full.authors)then text=cleanDescription(full.description)end
                trace(self,'Google volume detail '..item.id..': '..(text and #text..' description characters' or 'no usable description'))
            end
            if text and accepted then return text,'https://books.google.com/books?id='..encode(item.id),'Google Books' end
        end
    end
    self._last_error=not found and 'Google Books returned no records for any title-query variant.'
        or matched and 'Google Books found matching books, but neither search results nor checked volume details supplied a usable description.'
        or 'Google Books returned records, but none passed the title and author checks.'
    self._last_error_transient=false
    if detail_error then self._last_error=self._last_error..' '..detail_error;self._last_error_transient=detail_transient end
end
local function wikipedia(self,wanted)
    local searched_title=searchText(lookupTitles(wanted.title)[2] or wanted.title):match('^[^:]+') or searchText(wanted.title)
    local work_aliases={['the book of lieh tzu']='liezi',['book of lieh tzu']='liezi',
        ['the book of master lie']='liezi',['book of master lie']='liezi',
        ['hsin hsin ming']='xinxin ming', ['hua hu ching']='huahujing',
        ['the cloud of unknowing and other works']='the cloud of unknowing',
        ['cloud of unknowing and other works']='the cloud of unknowing'}
    searched_title=work_aliases[searched_title] or searched_title
    local query='"'..searched_title..'"' 
    trace(self,'Wikipedia request field: gsrsearch; title query: ['..query..']')
    local result=self:requestJSON('https://en.wikipedia.org/w/api.php?action=query&format=json&formatversion=2'
        ..'&generator=search&gsrlimit=5&gsrsearch='..encode(query)
        ..'&prop=extracts%7Cpageprops&exintro=1&explaintext=1&exlimit=5&ppprop=disambiguation')
    if not result then return nil end
    for _,page in ipairs(result.query and result.query.pages or {}) do
        local title=tostring(page.title or ''):gsub('%s*%([^()]*%)$','')
        local text=cleanDescription(page.extract)
        local introductory=(text or ''):lower()
        local lead=(introductory:match('^(.-)\n\n') or introductory):sub(1,1000)
        local literary=lead:find('%f[%a]book%f[%A]') or lead:find('%f[%a]novel%f[%A]') or lead:find('%f[%a]poem%f[%A]')
            or lead:find('memoir',1,true) or lead:find('treatise',1,true) or lead:find('spiritual text',1,true) or lead:find('taoist work',1,true)
            or lead:find('scripture',1,true) or lead:find('religious text',1,true)
            or lead:find('fiction work',1,true) or lead:find('buddhist text',1,true)
            or lead:find('chan text',1,true) or lead:find('zen text',1,true)
            or lead:find('work of christian mysticism',1,true) or lead:find('mystical text',1,true)
            or lead:find('collection of',1,true) and (lead:find('verse',1,true) or lead:find('koan',1,true) or lead:find('essay',1,true))
        local other_medium=lead:find('%f[%a]film%f[%A]') or lead:find('%f[%a]album%f[%A]')
            or lead:find('%f[%a]song%f[%A]') or lead:find('television',1,true)
        local primary=tostring(wanted.author or ''):match('^[^&;]+') or ''
        local author_tokens,author_hits=0,0
        local searchable=normalize(introductory):gsub('lao tzu','laozi'):gsub('lao tse','laozi'):gsub('á','a'):gsub('é','e'):gsub('í','i'):gsub('ó','o'):gsub('ú','u')
        for word in normalize(primary):gsub('lao tzu','laozi'):gsub('lao tse','laozi'):gmatch('%S+') do
            if word~='st' and word~='saint' and word~='geshe' and word~='venerable'
                and word~='rinpoche' and word~='of' and word~='and' and word~='unknown' then
                author_tokens=author_tokens+1
                if (' '..searchable..' '):find(' '..word..' ',1,true) then author_hits=author_hits+1 end
            end
        end
        local author_ok=author_tokens==0 or author_hits>=math.min(2,author_tokens)
        local alias_title=normalize(searched_title)
        local alias_in_lead=alias_title~='' and (' '..normalize(lead)..' '):find(' '..alias_title..' ',1,true)
        local overview_titles={['huahujing']=true,['xinxin ming']=true,['liezi']=true,
            ['platform sutra']=true,['the platform sutra']=true,['book of serenity']=true,['the book of serenity']=true,
            ['the cloud of unknowing']=true,['cloud of unknowing']=true}
        local overview=overview_titles[alias_title] and normalize(title):gsub('^the ','')==alias_title:gsub('^the ','')
        local title_ok=matches(wanted,title) or alias_in_lead or overview
        local disambiguation=page.pageprops and page.pageprops.disambiguation~=nil
        local accepted=title_ok and text and literary and (author_ok or overview) and not other_medium and not disambiguation
        local reasons={}
        if not title_ok then reasons[#reasons+1]='title/alias differs' end
        if not text then reasons[#reasons+1]='no usable extract' end
        if not literary then reasons[#reasons+1]='intro does not identify a literary work' end
        if not author_ok and not overview then reasons[#reasons+1]='author absent/different in extract' end
        if other_medium then reasons[#reasons+1]='film/music/television article' end
        if disambiguation then reasons[#reasons+1]='disambiguation page' end
        trace(self,'Wikipedia ['..tostring(page.title)..']: '..(accepted and (overview and not author_ok
            and 'accepted exact classical work overview; edition translator not required' or 'accepted literary page')
            or 'rejected: '..table.concat(reasons,', ')))
        if accepted then return text,'https://en.wikipedia.org/?curid='..tostring(page.pageid),'Wikipedia' end
    end
    self._last_error='Wikipedia returned no matching book article with a usable introduction.'
    self._last_error_transient=false
end
-- Read KOReader's Book Info metadata without changing the document or its
-- sidecar settings. If an old sidecar only contains a filename, inspect the
-- document metadata directly, using the same document provider as covers.
local function bookIdentity(file,need_description)
    local loaded,info=pcall(require,'apps/filemanager/filemanagerbookinfo')
    if loaded and type(info.getDocProps)=='function' then
        local ui={}
        for _,name in ipairs({'apps/reader/readerui','apps/filemanager/filemanager'}) do
            local ok,app=pcall(require,name)
            if ok and app.instance and app.instance.coverbrowser then ui=app.instance;break end
        end
        local ok,props=pcall(info.getDocProps,{ui=ui},file,nil,false)
        if ok and type(props)=='table' then
            local found=identity(file,props)
            if (need_description and viableEmbedded(props.description)) or (not need_description and not found.needs_metadata) then
                return found,'KOReader Book Info',props
            end
        end
    end
    local ok,registry=pcall(require,'document/documentregistry')
    if not ok then return nil end
    local document
    local success,props=pcall(function()
        if not registry:hasProvider(file) then return end
        document=registry:openDocument(file)
        if not document then return end
        -- Never inspect a failed load: native document methods may be unsafe.
        if document.loadDocument and not document:loadDocument(false) then return end
        return document:getProps()
    end)
    if document then pcall(document.close,document) end
    if success and type(props)=='table' then
        local found=identity(file,props)
        if need_description or not found.needs_metadata then return found,'KOReader document metadata',props end
    end
end
local function localDescription(file,props,quick)
    local text=type(props)=='table' and viableEmbedded(props.description)
    if text then return text,'Book metadata' end
    local ok,settings=pcall(DocSettings.open,DocSettings,file)
    if ok and settings then
        local loaded,saved=pcall(settings.readSetting,settings,'doc_props',{})
        text=loaded and type(saved)=='table' and viableEmbedded(saved.description)
        if text then return text,'Saved book metadata' end
    end
    if quick then return nil end
    local _,source,extracted=bookIdentity(file,true)
    text=type(extracted)=='table' and viableEmbedded(extracted.description)
    return text,source
end
function Descriptions:getLocalDescription(file,props,quick)
    local text,source=localDescription(file,props,quick)
    if not text then return nil end
    local data={identity=identity(file,props),text=text,source='Built-in description',
        lookup_metadata_source=source,pending=false,fetched_at=os.time(),match_version=MATCH_VERSION}
    data.trace_lines={'Build: '..self.BUILD,'Built-in description: '..#text..' characters, '..tostring(source),
        'Result: built-in description; no online queries made'}
    writeCache(file,data)
    return data
end
function Descriptions:download(file,wanted)
    self._request_cache={}
    self._trace={}
    trace(self,'Build: '..self.BUILD)
    trace(self,'File: '..(tostring(file):match('[^/]+$') or tostring(file)))
    trace(self,'Initial title: ['..tostring(wanted.title)..']')
    trace(self,'Initial author: ['..tostring(wanted.author or '')..']')
    trace(self,'Search identity: '..(wanted.manual and 'manual search override' or 'saved metadata / filename'))
    self._last_error=nil;self._last_error_transient=false
    local previous=readCache(file)
    if previous and (previous.identity.signature~=wanted.signature or previous.match_version~=MATCH_VERSION) then previous=nil end
    local embedded,embedded_source=localDescription(file)
    trace(self,'Built-in description: '..(embedded and (#embedded..' characters, '..tostring(embedded_source)) or 'none found'))
    if embedded then
        local data={identity=wanted,text=embedded,source='Built-in description',
            lookup_metadata_source=embedded_source,pending=false,fetched_at=os.time(),match_version=MATCH_VERSION,
            search_override=previous and previous.search_override}
        trace(self,'Result: built-in description; no online queries made')
        data.trace_lines=self._trace;self._trace=nil;writeCache(file,data);return data
    end
    local extracted,metadata_source
    if not wanted.manual and wanted.needs_metadata then extracted,metadata_source=bookIdentity(file) end
    local lookup=extracted or wanted
    if extracted then trace(self,'Document metadata title: ['..tostring(extracted.title)..'] / author: ['..tostring(extracted.author)..']') end
    local google_error,google_transient,library_description_error,primary_library_error,wikipedia_error
    local tried={}
    local function lookupDescription(candidate)
        local cleaned=cleanLookupTitle(candidate.title,candidate.author)
        if cleaned~=candidate.title then
            trace(self,'Cleaned lookup title: ['..tostring(candidate.title)..'] → ['..cleaned..'] (author unchanged)')
            local copy={};for key,value in pairs(candidate)do copy[key]=value end;copy.title=cleaned;candidate=copy
        end
        local lookup_key=searchText(fold(candidate.title))..'|'..normalize(candidate.author)
        if tried[lookup_key] then trace(self,'Skipping duplicate title/author lookup: ['..candidate.title..']');return nil end
        tried[lookup_key]=true
        trace(self,'Lookup title: ['..tostring(candidate.title)..'] / author: ['..tostring(candidate.author or '')..']')
        self._last_error=nil;self._last_error_transient=false
        local text,url,source=openLibrary(self,candidate)
        if text then return text,url,source end
        local library_error,library_transient=self._last_error,self._last_error_transient
        primary_library_error=primary_library_error or library_error
        if library_error==NO_LIBRARY_DESCRIPTION then
            library_description_error=library_error
        end
        text,url,source=googleBooks(self,candidate)
        if text then return text,url,source end
        if self._last_error then
            google_error,google_transient=self._last_error,self._last_error_transient
        end
        text,url,source=wikipedia(self,candidate)
        if text then return text,url,source end
        wikipedia_error=self._last_error
        self._last_error=library_error or self._last_error
        self._last_error_transient=library_transient or google_transient or self._last_error_transient
    end
    local text,url,source=lookupDescription(lookup)
    if not text and not wanted.manual and lookup~=wanted then
        text,url,source=lookupDescription(wanted)
        if text then lookup=wanted end
    end
    if not text and not wanted.manual and wanted.filename_identity then
        local candidate=wanted.filename_identity
        trace(self,'Trying filename fallback')
        text,url,source=lookupDescription(candidate)
        if text then lookup=candidate end
    end
    if not text and not wanted.manual and wanted.filename_alternative then
        local alternate=wanted.filename_alternative
        local primary=wanted.filename_identity
        if primary and normalize(primary.author)==normalize(wanted.author) and normalize(wanted.author)~='' then
            trace(self,'Skipping reversed filename: saved author already agrees with the filename author.')
        else
            trace(self,'Trying reversed filename fallback because saved author does not confirm filename orientation')
            text,url,source=lookupDescription(alternate)
            if text then lookup=alternate end
        end
    end
    local data=previous or {identity=wanted}
    data.lookup_identity={title=lookup.title,author=lookup.author,isbn=lookup.isbn}
    data.lookup_metadata_source=lookup==extracted and metadata_source or 'Saved identity / filename'
    data.checked_at=os.time();data.pending=false;data.phase=nil;data.pending_message=nil;data.match_version=MATCH_VERSION
    if text then
        trace(self,'Result: '..source..', '..#text..' description characters')
        data.text,data.url,data.source,data.fetched_at=text,url,source,os.time()
        data.error=nil;data.retry_at=nil
    else data.error=library_description_error or primary_library_error or self._last_error
            or 'No downloaded description is available for this book.'
        if google_error and google_error~=data.error then data.error=google_error..'\n\n'..data.error end
        if wikipedia_error and wikipedia_error~=data.error then data.error=data.error..'\n\n'..wikipedia_error end
        if searchText(lookup.title)=='' then
            data.error='No usable title was found. Enter a custom search title.'
        end
        data.retry_at=os.time()+((self._last_error_transient or google_transient) and 60 or RETRY_AGE)
        logger.warn('Slate: description unavailable:',data.error)
        trace(self,'Result: '..data.error)
    end
    data.trace_lines=self._trace;self._trace=nil
    writeCache(file,data)
    return data
end
function Descriptions:formatTrace(data)
    local lines=data and data.trace_lines
    if type(lines)~='table' or #lines==0 then return 'No lookup trace was recorded for this result.' end
    local report=table.concat(lines,'\n\n')
    if data.cache_error then report=report..'\n\nCache: '..data.cache_error end
    return report
end
function Descriptions:formatFailure(data)
    local lines={tostring(data and data.error or 'No description was downloaded.')}
    local found=data and (data.lookup_identity or data.search_override or data.identity)
    if found then
        lines[#lines+1]='Lookup title: ['..tostring(found.title or '')..']\nLookup author: ['..tostring(found.author or '')..']'
    end
    if data and type(data.trace_lines)=='table' and #data.trace_lines>0 then
        lines[#lines+1]='Actual search diagnostics:\n'..self:formatTrace(data)
    else
        lines[#lines+1]='Detailed search evidence was not recorded for this cached result. Retry this book to record the request fields, returned records, rejected matches, and description availability.'
    end
    return table.concat(lines,'\n\n')
end
function Descriptions:get(file,props)
    if type(file)~='string' or file=='' then return nil end
    local data=readCache(file)
    if data and props and data.identity.signature~=identity(file,props).signature then return nil end
    return data
end
local function online()
    local ok,network=pcall(require,'ui/network/manager')
    if not ok or type(network.isConnected)~='function' then return false end
    local success,connected=pcall(network.isConnected,network)
    return success and connected
end
local function notify(file,data,finished)
    local listeners=callbacks[file] or {}
    if finished then callbacks[file]=nil end
    for _,callback in ipairs(listeners) do pcall(callback,data) end
end
local function setStatus(request,phase,message)
    local data=readCache(request.file) or {identity=request.identity}
    data.pending=true;data.phase=phase;data.pending_message=message
    writeCache(request.file,data);notify(request.file,data)
    return data
end
local function finishJob(result)
    local active=job;job=nil
    if not active then return end
    if active.prevented and type(UIManager.allowStandby)=='function' then UIManager:allowStandby() end
    queued[active.file]=nil
    local data=result
    if type(data)=='table' and type(data.identity)=='table' then
        writeCache(active.file,data)
    else data=readCache(active.file,true) end
    if not data or data.pending then
        data=data or {identity=active.identity}
        data.pending=false;data.phase=nil;data.pending_message=nil
        data.error='The description worker exited without saving a result. Tap Retry all missing descriptions.'
        data.retry_at=os.time()+60;writeCache(active.file,data)
    end
    if G_reader_settings:readSetting('slate.descriptions.diagnostic_logging',false)==true then
        local ok,err=pcall(function()
            local log=assert(io.open('/mnt/us/koreader/description_diagnostic.log','a'))
            local identity=data.identity or active.identity or {}
            log:write(os.date('%Y-%m-%d %H:%M:%S'),'\nFile: ',tostring(active.file),
                '\nTitle: ',tostring(identity.title),'\nAuthor: ',tostring(identity.author),
                '\nStatus: ',tostring(data.error or (data.text and 'Description received' or 'Completed')),
                '\n',Descriptions:formatTrace(data),'\n\n')
            log:close()
        end)
        if not ok then logger.warn('Slate: diagnostic log could not be written:',err)end
    end
    if data.error then logger.warn('Slate: description status:',data.error) end
    notify(active.file,data,true)
end
local function closeResultPipe(active)
    if active and active.read_fd then
        pcall(FFIUtil.readAllFromFD,active.read_fd);active.read_fd=nil
    end
end
local function cancelKick()
    if kick_task then UIManager:unschedule(kick_task);kick_task=nil end
end
function Descriptions:startNext()
    if job or suspended or #queue==0 then return end
    cancelKick()
    local request=queue[1]
    if not online() then
        setStatus(request,'waiting_network','Waiting for KOReader to report a network connection. Downloads will resume automatically.')
        kick_task=function() kick_task=nil;self:startNext() end
        UIManager:scheduleIn(2,kick_task)
        return
    end
    if type(FFIUtil.runInSubProcess)~='function' or type(FFIUtil.isSubProcessDone)~='function' then
        table.remove(queue,1);queued[request.file]=nil
        local data=readCache(request.file) or {identity=request.identity}
        data.pending=false;data.phase=nil;data.pending_message=nil
        data.error='This KOReader build cannot start the background description worker.'
        data.retry_at=os.time()+60;writeCache(request.file,data);notify(request.file,data,true)
        if #queue>0 then UIManager:nextTick(function() self:startNext() end) end
        return
    end
    table.remove(queue,1)
    setStatus(request,'downloading','Downloading book description…')
    local with_pipe=type(FFIUtil.writeToFD)=='function'
        and type(FFIUtil.readAllFromFD)=='function'
        and type(FFIUtil.getNonBlockingReadSize)=='function'
    local ok,pid,read_fd=pcall(FFIUtil.runInSubProcess,function(_pid,write_fd)
        local success,result=pcall(self.download,self,request.file,request.identity)
        if not success then
            local err=result
            local data=readCache(request.file) or {identity=request.identity}
            data.retry_at=os.time()+60;data.pending=false;data.phase=nil;data.pending_message=nil
            data.error='Description worker failed: '..tostring(err);writeCache(request.file,data)
            logger.warn('Slate: description worker failed:',tostring(err))
            result=data
        end
        if with_pipe and write_fd then
            local encoded,bytes=pcall(json.encode,result)
            FFIUtil.writeToFD(write_fd,encoded and type(bytes)=='string' and bytes or '',true)
        end
    end,with_pipe)
    if not ok or not pid then
        queued[request.file]=nil
        local data=readCache(request.file) or {identity=request.identity}
        data.pending=false;data.phase=nil;data.pending_message=nil
        data.error='Could not start the background description worker.'
        data.retry_at=os.time()+60;writeCache(request.file,data);notify(request.file,data,true)
        if #queue>0 then UIManager:nextTick(function() self:startNext() end) end
        return
    end
    request.pid,request.started,request.read_fd=pid,os.time(),with_pipe and read_fd or nil;job=request
    if type(UIManager.preventStandby)=='function' then UIManager:preventStandby();request.prevented=true end
    local function poll()
        poll_task=nil
        if job~=request then return end
        local checked,done=pcall(FFIUtil.isSubProcessDone,pid)
        local ready=false
        if request.read_fd then
            local available,size=pcall(FFIUtil.getNonBlockingReadSize,request.read_fd)
            ready=available and tonumber(size) and size>0
        end
        if checked and (done or ready) then
            local result
            if request.read_fd then
                -- The worker writes only after networking finishes. Start draining
                -- as soon as bytes arrive so a large result cannot fill the pipe.
                local read,bytes=pcall(FFIUtil.readAllFromFD,request.read_fd)
                request.read_fd=nil
                if read and type(bytes)=='string' and bytes~='' then
                    local decoded,value=pcall(json.decode,bytes)
                    if decoded and type(value)=='table' then result=value end
                end
                if not done then pcall(FFIUtil.isSubProcessDone,pid,true) end
            end
            finishJob(result);self:startNext()
        elseif not checked or os.time()-request.started>180 then
            if type(FFIUtil.terminateSubProcess)=='function' then pcall(FFIUtil.terminateSubProcess,pid) end
            closeResultPipe(request)
            local data=readCache(request.file) or {identity=request.identity}
            data.pending=false;data.phase=nil;data.pending_message=nil
            data.error=not checked and 'Could not check the description worker status.'
                or 'Description search timed out. Retry or enter a custom search title.'
            data.retry_at=os.time()+60;writeCache(request.file,data)
            finishJob();self:startNext()
        else poll_task=poll;UIManager:scheduleIn(.25,poll) end
    end
    poll_task=poll;UIManager:scheduleIn(.25,poll)
end
function Descriptions:refreshAsync(file,props,callback,force)
    if type(file)~='string' or file=='' then return end
    -- Check local metadata before Wi-Fi, failed-cache backoff or online work.
    -- Only inspect native document metadata when a description is explicitly
    -- opened; background scans use the subprocess download path instead.
    if callback then
        local local_result=self:getLocalDescription(file,props,true)
        if local_result then callback(local_result);return local_result end
    end
    -- Explicit foreground use must resume downloads paused by device suspend.
    if callback or force then suspended=false end
    local wanted=identity(file,props)
    local data=self:get(file,props)
    local override=data and data.search_override
    if override then
        wanted.title,wanted.author,wanted.isbn=override.title,override.author,override.isbn
        wanted.manual=true
    end
    if not force and data and not data.pending and ((data.match_version==MATCH_VERSION and (data.retry_at or 0)>os.time())
        or ((data.match_version==MATCH_VERSION or data.match_version==21 or data.match_version==20 or data.match_version==19) and data.text and os.time()-(data.fetched_at or 0)<CACHE_AGE)) then
        if callback then callback(data) end
        self:startNext()
        return data
    end
    if callback then callbacks[file]=callbacks[file] or {};callbacks[file][#callbacks[file]+1]=callback end
    if not queued[file] then
        data=data or {identity=wanted};data.pending=true;data.phase='queued'
        data.pending_message='Description queued. Waiting for the current download to finish.'
        data.retry_at=nil;writeCache(file,data)
        queued[file]=true;queue[#queue+1]={file=file,identity=wanted}
    end
    if callback or force then
        for i,request in ipairs(queue) do
            if request.file==file then table.remove(queue,i);table.insert(queue,1,request);break end
        end
    end
    self:startNext()
    -- Return current status, not the stale pre-worker snapshot.
    return readCache(file)
end
function Descriptions:missingBooks()
    local books=require('slate_books')
    local entries=books:scanDirectory(books:getDirectory(),true)
    local missing={}
    for _,entry in ipairs(entries) do
        local data=self:get(entry.file)
        if not data or not data.text or data.text=='' then missing[#missing+1]=entry end
    end
    return missing
end
function Descriptions:retryAllMissing()
    suspended=false
    local missing=self:missingBooks()
    for _,entry in ipairs(missing) do self:refreshAsync(entry.file,nil,nil,true) end
    return #missing
end
function Descriptions:setSearch(file,title,author,callback)
    if queued[file] then return false,'A search for this book is already queued. Try again when it finishes.' end
    title=tostring(title or ''):gsub('^%s+',''):gsub('%s+$','')
    author=tostring(author or ''):gsub('^%s+',''):gsub('%s+$','')
    if title=='' then return false,'Enter a book title.' end
    local data=self:get(file) or {identity=identity(file)}
    data.search_override={title=searchText(title),author=''}
    data.retry_at=nil;data.checked_at=nil;data.error=nil
    if not writeCache(file,data) then return false,'Could not save the search.' end
    self:refreshAsync(file,nil,callback,true)
    return true
end
function Descriptions:editSearch(file,onDone)
    local InputDialog=require('ui/widget/inputdialog')
    local InfoMessage=require('ui/widget/infomessage')
    local Utils=require('slate_utils')
    local _=require('gettext')
    local data=self:get(file)
    local wanted=data and (data.search_override or data.lookup_identity or data.identity) or identity(file)
    local dialog
    dialog=InputDialog:new{
        modal=true,title=_('Search book title'),input=wanted.title or '',input_type='string',
        description=_("Search using only the title. Apostrophes are preserved; no author is required."),
        buttons={{
            {text=_('Cancel'),callback=function() UIManager:close(dialog) end},
            {text=_('Search'),is_enter_default=true,callback=function()
                local ok,err=self:setSearch(file,dialog:getInputValue(),'',function(result)
                    if onDone then onDone(result) end
                    if not result or not result.text then
                        UIManager:show(Utils:themePopup(InfoMessage:new{modal=true,text=result and result.error or _('Search did not finish.')}))
                    end
                end)
                UIManager:close(dialog)
                UIManager:show(Utils:themePopup(InfoMessage:new{modal=true,text=ok and _('Search queued. Connect to Wi-Fi to download the description.') or err}))
            end},
        }},
    }
    UIManager:show(Utils:themePopup(dialog));dialog:onShowKeyboard()
end
function Descriptions:credentialsChanged()
    if job then
        if poll_task then UIManager:unschedule(poll_task);poll_task=nil end
        local active=job;job=nil
        if type(FFIUtil.terminateSubProcess)=='function' then pcall(FFIUtil.terminateSubProcess,active.pid) end
        closeResultPipe(active)
        if active.prevented and type(UIManager.allowStandby)=='function' then UIManager:allowStandby() end
        table.insert(queue,1,{file=active.file,identity=active.identity})
    end
    suspended=false
    self:retryAllMissing();self:startNext()
end
function Descriptions:metadataChanged(file,props)
    if job and job.file==file then
        if poll_task then UIManager:unschedule(poll_task);poll_task=nil end
        local active=job;job=nil
        if type(FFIUtil.terminateSubProcess)=='function' then pcall(FFIUtil.terminateSubProcess,active.pid) end
        closeResultPipe(active)
        if active.prevented and type(UIManager.allowStandby)=='function' then UIManager:allowStandby() end
    end
    for i=#queue,1,-1 do if queue[i].file==file then table.remove(queue,i) end end
    queued[file]=nil
    local data={identity=identity(file,props)}
    writeCache(file,data)
    return self:refreshAsync(file,props,nil,true)
end
function Descriptions:onWake(owner)
    suspended=false
    local file=owner and owner._slate_book_file or G_reader_settings:readSetting('lastfile')
    if file then self:refreshAsync(file) end
    -- Discover books never opened in Slate, rather than only revisiting cache files.
    if not self.library_discovered then
        local ok,missing=pcall(self.missingBooks,self)
        if ok then
            self.library_discovered=true
            for _,entry in ipairs(missing) do self:refreshAsync(entry.file) end
        else logger.warn('Slate: could not discover missing descriptions:',missing) end
    end
    local ok,lfs=pcall(require,'libs/libkoreader-lfs')
    if ok then
        local count=0
        for name in lfs.dir(directory()) do
            if name:match('%.json$') then
                local f=io.open(directory()..name,'r')
                if f then
                    local success,data=pcall(json.decode,f:read('*all'));f:close()
                    if success and type(data)=='table' and type(data.file)=='string' and (data.pending or data.error
                        or (data.text and os.time()-(data.fetched_at or 0)>=CACHE_AGE))
                        and data.file~=file then
                        self:refreshAsync(data.file);count=count+1;if count>=2 then break end
                    end
                end
            end
        end
    end
    self:startNext()
end
function Descriptions:onSuspend()
    suspended=true
    cancelKick()
    if poll_task then UIManager:unschedule(poll_task);poll_task=nil end
    if job then
        local active=job;pcall(FFIUtil.terminateSubProcess,active.pid)
        closeResultPipe(active)
        job=nil;table.insert(queue,1,{file=active.file,identity=active.identity})
        setStatus(active,'paused','Description download paused while the device sleeps.')
        if active.prevented and type(UIManager.allowStandby)=='function' then UIManager:allowStandby() end
    end
end
return Descriptions

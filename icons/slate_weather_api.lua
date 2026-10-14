-- Modified for Slate on 2026-10-10.
-- Weather API Module for Slate.
-- Open-Meteo forecast and dated moon phase, adapted to Slate’s display format.

local DataStorage = require("datastorage")
local logger = require("logger")
local SlateUtils = require("slate_utils")
local util = require("util")

local SlateWeatherAPI = {}
local REQUEST_TIMEOUT = 12

local function encode_query(value)
    return (tostring(value or ""):gsub("([^%w%-%._~])", function(char)
        return string.format("%%%02X", char:byte())
    end))
end

local function http_request_code(url, sink_table)
    local ok_ltn, ltn12 = pcall(require, "ltn12")
    if not ok_ltn then return nil end

    local ok_client, client = pcall(require, "ssl.https")
    if not ok_client or not client or type(client.request) ~= "function" then
        ok_client, client = pcall(require, "socket.http")
    end

    if not ok_client or not client or type(client.request) ~= "function" then
        return nil
    end

    local previous_timeout = client.TIMEOUT
    client.TIMEOUT = REQUEST_TIMEOUT

    local ok, result, code = pcall(client.request, {
        url = url,
        sink = ltn12.sink.table(sink_table),
        redirect = false,
    })

    client.TIMEOUT = previous_timeout

    if not ok or not result then return nil end
    return tonumber(code)
end

local function format_temperature(value, suffix)
    value = tonumber(value)
    if not value then return "—" end
    return tostring(math.floor(value)) .. suffix
end

local function get_cached(slate)
    return SlateUtils:loadWeatherCache(function()
        return slate:getCacheMaxAge()
    end, true)
end

local function requestURL(url)
    local body = {}
    local code = http_request_code(url, body)
    local ok, data = pcall(require('json').decode, table.concat(body))
    return ok and type(data) == 'table' and data or nil, code
end

local weather_codes = {
    [0]={'Clear',113}, [1]={'Mostly clear',116}, [2]={'Partly cloudy',116},
    [3]={'Overcast',122}, [45]={'Fog',248}, [48]={'Freezing fog',260},
    [51]={'Light drizzle',266}, [53]={'Drizzle',266}, [55]={'Heavy drizzle',266},
    [56]={'Freezing drizzle',281}, [57]={'Heavy freezing drizzle',284},
    [61]={'Light rain',296}, [63]={'Rain',302}, [65]={'Heavy rain',308},
    [66]={'Freezing rain',311}, [67]={'Heavy freezing rain',314},
    [71]={'Light snow',326}, [73]={'Snow',332}, [75]={'Heavy snow',338},
    [77]={'Snow grains',350}, [80]={'Light showers',353}, [81]={'Showers',356},
    [82]={'Heavy showers',359}, [85]={'Snow showers',368}, [86]={'Heavy snow showers',371},
    [95]={'Thunderstorm',389}, [96]={'Thunderstorm with hail',389}, [99]={'Heavy thunderstorm with hail',389},
}
local function condition(code, is_day)
    local value = weather_codes[tonumber(code)]
    if not value then return {text='Weather unavailable'} end
    local label = value[1]
    if tonumber(code)==0 and is_day~=0 then label='Sunny' end
    return {text=label,icon='https://cdn.weatherapi.com/weather/64x64/'
        .. (is_day==0 and 'night' or 'day') .. '/' .. value[2] .. '.png'}
end
local function moonName(value)
    value=tonumber(value)
    if not value or value<0 or value>1 then return nil end
    if value<=.017 or value>=.983 then return 'New Moon'
    elseif value<.233 then return 'Waxing Crescent'
    elseif value<=.267 then return 'First Quarter'
    elseif value<.483 then return 'Waxing Gibbous'
    elseif value<=.517 then return 'Full Moon'
    elseif value<.733 then return 'Waning Gibbous'
    elseif value<=.767 then return 'Last Quarter'
    else return 'Waning Crescent' end
end
local function readJSONFile(path)
    local f=io.open(path,'r');if not f then return {} end
    local bytes=f:read('*all');f:close()
    local ok,result=pcall(require('json').decode,bytes)
    return ok and type(result)=='table' and result or {}
end
function SlateWeatherAPI:resolveLocation(slate)
    local query=tostring(G_reader_settings:readSetting('slate_weather_location') or slate.default_location or '')
        :gsub('^%s+',''):gsub('%s+$','')
    local lat,lon=query:match('^([%+%-]?[%d%.]+)%s*,%s*([%+%-]?[%d%.]+)$')
    lat,lon=tonumber(lat),tonumber(lon)
    if lat and lon and math.abs(lat)<=90 and math.abs(lon)<=180 then
        return {latitude=lat,longitude=lon,name=query}
    end
    if query=='' then return nil end
    local path=DataStorage:getDataDir() .. '/cache/slate-geocoding.json'
    self._locations=self._locations or readJSONFile(path)
    local key=query:lower()
    local cached=self._locations[key]
    if type(cached)=='table' and tonumber(cached.latitude) and tonumber(cached.longitude) then return cached end
    local city,country=query:match('^(.-)%s*,%s*(.+)$')
    local result,code=requestURL('https://geocoding-api.open-meteo.com/v1/search?count=10&language=en&format=json&name='
        .. encode_query(city or query))
    if code~=200 or not result or type(result.results)~='table' then return nil end
    local selected
    for _,place in ipairs(result.results) do
        if not country or tostring(place.country or ''):lower()==country:lower()
            or tostring(place.country_code or ''):lower()==country:lower()
            or tostring(place.admin1 or ''):lower()==country:lower() then selected=place;break end
    end
    if not selected then return nil end
    self._locations[key]=selected
    util.makePath(DataStorage:getDataDir() .. '/cache/')
    local ok,bytes=pcall(require('json').encode,self._locations)
    if ok then
        local f=io.open(path..'.tmp','w')
        if f then local written=f:write(bytes);local closed=f:close()
            if written and closed then os.rename(path..'.tmp',path) else os.remove(path..'.tmp') end
        end
    end
    return selected
end

function SlateWeatherAPI:requestJSON(slate, method, parameters)
    if method~='forecast' then return nil end
    local place=self:resolveLocation(slate)
    if not place then return nil end
    local unit=G_reader_settings:readSetting('slate_weather_temp_scale') or 'C'
    local url='https://api.open-meteo.com/v1/forecast?latitude=' .. encode_query(place.latitude)
        .. '&longitude=' .. encode_query(place.longitude)
        .. '&timezone=auto&forecast_days=7&past_days=6&temperature_unit='
        .. (unit=='F' and 'fahrenheit' or 'celsius')
        .. '&current=temperature_2m,relative_humidity_2m,apparent_temperature,is_day,weather_code,wind_speed_10m,wind_direction_10m'
        .. '&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,moon_phase'
        .. '&hourly=temperature_2m,weather_code,is_day'
    local raw,code=requestURL(url)
    if code~=200 or not raw or raw.error or type(raw.current)~='table'
        or type(raw.daily)~='table' or type(raw.daily.time)~='table'
        or type(raw.daily.moon_phase)~='table' then return nil,code end
    local offset=tonumber(raw.utc_offset_seconds) or 0
    local c=raw.current
    local current_epoch=SlateUtils:dateTimeToEpoch(c.time)
    local function temperatures(t)
        t=tonumber(t);if not t then return nil,nil end
        if unit=='F' then return (t-32)*5/9,t end
        return t,t*9/5+32
    end
    local tc,tf=temperatures(c.temperature_2m)
    local fc,ff=temperatures(c.apparent_temperature)
    local result={provider='open-meteo',location={name=place.name,localtime=c.time,
        localtime_epoch=current_epoch and current_epoch-offset,tz_id=raw.timezone},
        current={temp_c=tc,temp_f=tf,feelslike_c=fc,feelslike_f=ff,
            humidity=c.relative_humidity_2m,wind_kph=c.wind_speed_10m,
            wind_dir=({'N','NE','E','SE','S','SW','W','NW'})[math.floor(((tonumber(c.wind_direction_10m) or 0)+22.5)%360/45)+1],
            is_day=c.is_day,condition=condition(c.weather_code,c.is_day),
            last_updated=c.time,last_updated_epoch=current_epoch and current_epoch-offset},
        forecast={forecastday={}},astronomy_days={}}
    local by_date={}
    local daily=raw.daily
    for i,date in ipairs(daily.time) do
        local phase=moonName(daily.moon_phase[i])
        local hi_c,hi_f=temperatures(daily.temperature_2m_max[i])
        local lo_c,lo_f=temperatures(daily.temperature_2m_min[i])
        local function timeOnly(value) return type(value)=='string' and value:match('T(%d%d:%d%d)') or nil end
        local astro={date=date,source='astronomy',fetched_at=os.time(),moon_phase=phase,
            moon_illumination=phase and math.floor((1-math.cos(2*math.pi*daily.moon_phase[i]))*50+.5),
            sunrise=timeOnly(daily.sunrise[i]),sunset=timeOnly(daily.sunset[i])}
        result.astronomy_days[date]=astro
        local day={date=date,astro=astro,hour={},day={maxtemp_c=hi_c,maxtemp_f=hi_f,
            mintemp_c=lo_c,mintemp_f=lo_f,condition=condition(daily.weather_code[i],1),
            daily_chance_of_rain=daily.precipitation_probability_max[i]}}
        result.forecast.forecastday[#result.forecast.forecastday+1]=day;by_date[date]=day
    end
    local hourly=raw.hourly or {}
    for i,time in ipairs(hourly.time or {}) do
        local day=by_date[time:sub(1,10)]
        if day then
            local hc,hf=temperatures(hourly.temperature_2m[i])
            day.hour[#day.hour+1]={time=time:gsub('T',' '),time_epoch=SlateUtils:dateTimeToEpoch(time)-offset,
                temp_c=hc,temp_f=hf,condition=condition(hourly.weather_code[i],hourly.is_day[i])}
        end
    end
    return result,code
end

function SlateWeatherAPI:fetchWeatherData(slate)
    self._icon_attempts={}
    local result,code=self:requestJSON(slate,'forecast',{days=7})
    local previous=get_cached(slate)
    if code~=200 or not result then
        logger.warn('Slate: Open-Meteo request failed; using saved weather')
        if previous then previous.is_cached=true end
        return previous
    end
    local ok,data=pcall(self.processWeatherData,self,slate,result)
    if not ok or not data then
        if previous then previous.is_cached=true end
        return previous
    end
    data.provider='open-meteo'
    data.attribution='Weather data: Open-Meteo (CC BY 4.0)'
    data.is_cached=false
    data.astronomy_days=result.astronomy_days
    local today=SlateUtils:getWeatherLocalDate(data)
    data.astronomy=today and data.astronomy_days[today] or {is_stale=true}
    for _,day in ipairs(data.forecast_days) do
        local astro=data.astronomy_days[day.date]
        if astro then day.moon_phase=astro.moon_phase;day.moon_illumination=astro.moon_illumination;day.moon_source='astronomy' end
    end
    SlateUtils:mergeWeatherHistory(data,previous and previous.provider=='open-meteo' and previous or nil)
    SlateUtils:prepareWeatherData(data)
    SlateUtils:saveWeatherCache(data)
    return data
end

function SlateWeatherAPI:recoverMissingDays(slate,data) return data end
function SlateWeatherAPI:refreshAstronomy(slate,data) return data end

function SlateWeatherAPI:processWeatherData(slate, result)
    if type(result) ~= "table" or type(result.current) ~= "table" then
        return nil
    end

    local temp_scale = G_reader_settings:readSetting("slate_weather_temp_scale") or "C"
    local is_celsius = temp_scale == "C"
    local twelve_hour_clock = G_reader_settings:isTrue("twelve_hour_clock")
    local fetched_at = os.time()

    local current = result.current
    local location = type(result.location) == "table" and result.location or {}
    local condition = type(current.condition) == "table" and current.condition or {}
    local localtime = location.localtime
    local local_epoch = tonumber(location.localtime_epoch)
    local civil_epoch = SlateUtils:dateTimeToEpoch(localtime)
    local utc_offset

    if civil_epoch and local_epoch then
        -- The local-time string has minute precision, so truncate seconds
        -- in the epoch before finding the location's UTC offset.
        utc_offset = civil_epoch - math.floor(local_epoch / 60) * 60
        if math.abs(utc_offset) > 86400 then utc_offset = nil end
    end

    local today = type(localtime) == "string"
        and localtime:match("^(%d%d%d%d%-%d%d%-%d%d)") or nil
    local today_epoch = today and SlateUtils:dateTimeToEpoch(today)
    local tomorrow = today_epoch and os.date("!%Y-%m-%d", today_epoch + 86400)

    local current_icon = self:getIconPath(condition.icon)
    if not current_icon then
        local fallback = DataStorage:getDataDir() .. "/icons/"
            .. (tonumber(current.is_day) == 0 and "moon.svg" or "sun.svg")
        if util.fileExists(fallback) then current_icon = fallback end
    end

    local current_data = {
        icon_path = current_icon,
        temperature = format_temperature(
            is_celsius and current.temp_c or current.temp_f,
            "°" .. temp_scale
        ),
        condition = condition.text or "",
        location = location.name,
        timestamp = current.last_updated or localtime,
        observation_epoch = tonumber(current.last_updated_epoch),
        localtime = localtime,
        timezone = location.tz_id,
        utc_offset = utc_offset,
        feels_like = format_temperature(
            is_celsius and current.feelslike_c or current.feelslike_f,
            "°" .. temp_scale
        ),
        humidity = current.humidity and tostring(current.humidity) .. "%" or nil,
        wind = current.wind_kph
            and tostring(math.floor(current.wind_kph)) .. " km/h" or nil,
        wind_dir = current.wind_dir,
    }

    local days = result.forecast and result.forecast.forecastday
    if type(days) ~= "table" then days = {} end

    local today_data, tomorrow_data
    for _, day in ipairs(days) do
        if type(day) == "table" then
            if day.date == today then today_data = day end
            if day.date == tomorrow then tomorrow_data = day end
        end
    end

    local astronomy
    if today_data and type(today_data.astro) == "table" then
        local astro = today_data.astro
        astronomy = {
            date = today_data.date,
            sunrise = astro.sunrise,
            sunset = astro.sunset,
            moonrise = astro.moonrise,
            moonset = astro.moonset,
            moon_phase = SlateUtils:normalizeMoonPhase(astro.moon_phase),
            moon_illumination = tonumber(astro.moon_illumination),
        }
    end

    local function process_hours(day_data)
        local all, basic = {}, {}
        if not day_data or type(day_data.hour) ~= "table" then
            return all, basic
        end

        for _, hour_data in ipairs(day_data.hour) do
            if type(hour_data) == "table" and type(hour_data.time) == "string" then
                local hour = tonumber(
                    hour_data.time:match("[ T](%d%d?):%d%d$")
                )

                if hour and hour >= 0 and hour <= 23 then
                    local hour_condition = type(hour_data.condition) == "table"
                        and hour_data.condition or {}

                    local entry = {
                        date = day_data.date,
                        time = hour_data.time,
                        time_epoch = tonumber(hour_data.time_epoch),
                        hour = SlateUtils:formatHourLabel(hour, twelve_hour_clock),
                        hour_num = hour,
                        icon_path = self:getIconPath(hour_condition.icon),
                        temperature = format_temperature(
                            is_celsius and hour_data.temp_c or hour_data.temp_f,
                            "°"
                        ),
                        condition = hour_condition.text or "",
                    }

                    all[#all + 1] = entry
                    if hour == 6 or hour == 12 or hour == 18 then
                        basic[#basic + 1] = entry
                    end
                end
            end
        end

        return all, basic
    end

    local hourly_today, hourly_today_basic = process_hours(today_data)
    local hourly_tomorrow, hourly_tomorrow_basic = process_hours(tomorrow_data)
    local forecast_days = {}

    for _, day_data in ipairs(days) do
        if type(day_data) == "table" and type(day_data.day) == "table" then
            local day = day_data.day
            local date_epoch = SlateUtils:dateTimeToEpoch(day_data.date)
            local day_condition = type(day.condition) == "table"
                and day.condition or {}
            local day_name = date_epoch and os.date("!%a", date_epoch) or "—"

            if day_data.date == today then day_name = "Today" end
            if day_data.date == tomorrow then day_name = "Tomorrow" end

            local high = tonumber(is_celsius and day.maxtemp_c or day.maxtemp_f)
            local low = tonumber(is_celsius and day.mintemp_c or day.mintemp_f)

            forecast_days[#forecast_days + 1] = {
                date = day_data.date,
                date_epoch = date_epoch,
                weekday = date_epoch and tonumber(os.date("!%w", date_epoch)) or nil,
                day_name = day_name,
                icon_path = self:getIconPath(day_condition.icon),
                high = high,
                low = low,
                high_low = format_temperature(high, "°")
                    .. " / " .. format_temperature(low, "°"),
                condition = day_condition.text or "",
                chance_of_rain = tonumber(day.daily_chance_of_rain),
                moon_phase = type(day_data.astro) == "table"
                    and SlateUtils:normalizeMoonPhase(day_data.astro.moon_phase)
                    or nil,
            }
        end
    end

    return {
        fetched_at = fetched_at,
        temperature_unit = temp_scale,
        current = current_data,
        hourly_today = hourly_today_basic,
        hourly_tomorrow = hourly_tomorrow_basic,
        hourly_today_all = hourly_today,
        hourly_tomorrow_all = hourly_tomorrow,
        forecast_days = forecast_days,
        forecast_days_available = #forecast_days,
        astronomy = astronomy,
    }
end

local function valid_png(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local signature = f:read(8)
    f:close()
    return signature == "\137PNG\r\n\26\n"
end

function SlateWeatherAPI:getIconPath(icon_url_from_api)
    if type(icon_url_from_api) ~= "string" or icon_url_from_api == "" then
        return nil
    end

    local url = icon_url_from_api
    if url:sub(1, 2) == "//" then url = "https:" .. url end

    local day_night, filename = url:match("/([^/]+)/([^/]+%.png)$")
    if (day_night ~= "day" and day_night ~= "night")
        or not filename or not filename:match("^%d+%.png$") then
        return nil
    end

    local cache_dir = DataStorage:getDataDir() .. "/cache/slate-weather-icons/"
    local cache_path = cache_dir .. day_night .. "_" .. filename
    if valid_png(cache_path) then return cache_path end

    self._icon_attempts = self._icon_attempts or {}
    if self._icon_attempts[url] then return nil end
    self._icon_attempts[url] = true

    util.makePath(cache_dir)

    local body = {}
    local code = http_request_code(url, body)
    local bytes = table.concat(body)

    if code ~= 200 or bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then
        return nil
    end

    local temporary = cache_path .. ".tmp"
    local f = io.open(temporary, "wb")
    if not f then return nil end

    local written = f:write(bytes)
    local closed = f:close()
    if not written or not closed then
        os.remove(temporary)
        return nil
    end

    if not os.rename(temporary, cache_path) then
        os.remove(temporary)
        return nil
    end

    return cache_path
end

return SlateWeatherAPI
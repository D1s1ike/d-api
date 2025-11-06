local socket = require("socket")

-- Global Config
local Port = Config.Port or 8080
local ApiKey = Config.ApiKey or nil
local PlayersEndpoint = Config.PlayersEndpoint or "/players"
local listeners = {}
local players = {}
local clients = {}

-- Helper Functions
local function build_response(body, code, mime)
  code = code or "200 OK"
  mime = mime or "application/json; charset=utf-8"
  return ("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s")
    :format(code, mime, #body, body)
end

local function make_json_body(tbl)
  local ok, json_str = pcall(JSON.stringify, tbl)
  if not ok then
    json_str = '{"error":"failed to encode JSON"}'
  end
  return json_str
end

local function get_players()
  local _players = {}
  for k,v in pairs(GetAllPlayers()) do
    local PlayerState = v:GetLyraPlayerState()
    local HelixUserId = PlayerState:GetHelixUserId()
    local PlayerName = PlayerState:GetPlayerName()
    table.insert(_players, { id = k, name = PlayerName, license = HelixUserId })
  end
  return _players
end

-- Binding Functions
local function try_listen_ipv6_dual()
  if not socket.tcp6 then return false end
  local s = socket.tcp6()
  if not s then return false end
  s:settimeout(0)
  pcall(function() s:setoption("reuseaddr", true) end)
  pcall(function() s:setoption("ipv6-v6only", false) end)
  local ok = s:bind("::", Port)
  if not ok then s:close(); return false end
  ok = s:listen(128)
  if not ok then s:close(); return false end
  table.insert(listeners, s)
  return true
end

local function listen_ipv4_any()
  local s = assert(socket.tcp())
  pcall(function() s:setoption("reuseaddr", true) end)
  assert(s:bind("0.0.0.0", Port))
  assert(s:listen(128))
  s:settimeout(0)
  table.insert(listeners, s)

  assert(s, err)
  s:settimeout(0)
  table.insert(listeners, s)
end

local function listen_ipv6_any()
  if not socket.tcp6 then return end
  local s = socket.tcp6()
  if not s then return end
  s:settimeout(0)
  pcall(function() s:setoption("reuseaddr", true) end)
  local ok = s:bind("::", Port)
  if not ok then s:close(); return end
  ok = s:listen(128)
  if not ok then s:close(); return end
  table.insert(listeners, s)
end

if not try_listen_ipv6_dual() then
  listen_ipv4_any()
  listen_ipv6_any()
end


local function drop_client(i)
  local c = clients[i]
  if c and c.sock then pcall(c.sock.close, c.sock) end
  table.remove(clients, i)
end

local function begin_players_response(c)
    c.deadline = socket.gettime() + 5
    local response = {
        status = "success",
        clients = #players,
        players = players
    }
    local body = make_json_body(response)
    c.pending_body = build_response(body)
end

local function process_client(i)
  local c = clients[i]
  local s = c.sock
  local chunk, err, partial = s:receive(8192)
  local data = chunk or partial
  if data and #data > 0 then
    c.buf = c.buf .. data
  end
  if err == "closed" then
    return drop_client(i)
  end
  local MAX_HEADER_BYTES = 16 * 1024
  if #c.buf > MAX_HEADER_BYTES then
    local resp = build_response(make_json_body({ status="error", message="header too large" }),
                                "431 Request Header Fields Too Large")
    pcall(s.send, s, resp)
    return drop_client(i)
  end

  local header_end = c.buf:find("\r\n\r\n", 1, true) or c.buf:find("\n\n", 1, true)
  if not header_end or c.started then
    return
  end
  c.started = true
  
  local req_line = c.buf:match("^(.-)\r?\n") or ""
  local method, path = req_line:match("^(%u+)%s+([^%s]+)")
  method = method or "GET"
  path = path or "/"

  local headers = {}
  local header_block = c.buf:sub(#req_line + 2, header_end)
  for line in header_block:gmatch("[^\r\n]+") do
    local k, v = line:match("^([%w%-]+):%s*(.+)$")
    if k and v then headers[k:lower()] = v end
  end

  if method ~= "GET" then
    local resp = build_response(make_json_body({ status="error", message="method not allowed" }),
                                "405 Method Not Allowed")
    pcall(s.send, s, resp)
    return drop_client(i)
  end

  local supplied = headers["x-api-key"] or headers["authorization"] or ""
  supplied = supplied:match("^%s*(.-)%s*$")

  if ApiKey and supplied ~= ApiKey then
    local resp = build_response(make_json_body({ status="error", message="unauthorized" }),
                                "401 Unauthorized")
    pcall(s.send, s, resp)
    return drop_client(i)
  end

  local clean_path = path:gsub("%?.*$", "")
  if clean_path == "/health" then
    local body = make_json_body({ status = "ok" })
    c.pending_body = build_response(body)
    return
  end

  if PlayersEndpoint then
    if clean_path ~= PlayersEndpoint then
      local resp = build_response(make_json_body({ status="error", message="not found", path=path }),
                                  "404 Not Found")
      pcall(s.send, s, resp)
      return drop_client(i)
    end
  end
  if not PlayersEndpoint and clean_path ~= "/" then
    local resp = build_response(make_json_body({ status="error", message="not found", path=path }),
                                "404 Not Found")
    pcall(s.send, s, resp)
    return drop_client(i)
  end
  begin_players_response(c)
end

-- Player Cache Updater
Timer.CreateThread(function()
  while true do
    local new_players = get_players()
    if new_players then
      players = new_players
    end
    Timer.Wait(1000)
  end
end)

-- HTTP Server Loop
Timer.CreateThread(function()
  while true do
    for _, srv in ipairs(listeners) do
      while true do
        local cli = srv:accept()
        if not cli then break end
        cli:settimeout(0)
        clients[#clients+1] = { sock = cli, buf = "" }
      end
    end
    if #clients > 0 then
      local read_set = {}
      for _, c in ipairs(clients) do read_set[#read_set+1] = c.sock end
      local readable = socket.select(read_set, nil, 0)
      if #readable > 0 then
        for i = #clients, 1, -1 do
          local c = clients[i]
          for _, rs in ipairs(readable) do
            if rs == c.sock then process_client(i); break end
          end
        end
      end
    end
    local now = socket.gettime()
    for i = #clients, 1, -1 do
      local c = clients[i]
      if c.pending_body then
        pcall(c.sock.send, c.sock, c.pending_body)
        drop_client(i)
      elseif c.started and c.deadline and now > c.deadline then
        local timeout_body = make_json_body({ status = "timeout", players = {}, count = 0 })
        pcall(c.sock.send, c.sock, build_response(timeout_body))
        drop_client(i)
      end
    end
    Timer.Wait(10)
  end
end)

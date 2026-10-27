-- utdV2.luau (Obsidian build)
-- Ultimate Tower Defense - Obsidian UI + Macro System
-- (utdV2/utd_li'ye dokunulmaz; bu dosya ayni makronun Obsidian UI'li ikizidir)

local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
-- Obsidian is a Linoria fork: element APIs, Toggles/Options registries,
-- Notify and the SaveManager/ThemeManager addons all match, so only the
-- header differs from the Linoria build - no source patches needed (its
-- custom cursor is natively switchable via ShowCustomCursor).
local Library = loadstring(game:HttpGet(repo .. "Library.lua"))()
Library.ShowCustomCursor = false
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()

-- Obsidian keeps the element registries on the Library table itself (Linoria
-- parked them on getgenv); fail fast with a clear message instead of a
-- cryptic nil-index fifty lines later
local Toggles = Library.Toggles
local Options = Library.Options
assert(Toggles and Options, "[UTD] Obsidian did not register Toggles/Options")

-- load generation: every Execute bumps this. Long-lived threads check it so
-- a second Execute starves the first copy's loops instead of doubling them.
getgenv().__UTD_GEN = (getgenv().__UTD_GEN or 0) + 1
local MY_GEN = getgenv().__UTD_GEN
local function myGenAlive()
	return getgenv().__UTD_GEN == MY_GEN
end

-- STATE only exists under live-reload. When the file is run straight from the
-- editor there is none, so build a compatible shim: one shared __namecall
-- dispatcher (same contract: return nothing and the original still runs),
-- plain Connect, and an alive() that never dies. Declaring it local also
-- silences the editor's "Unknown global STATE" warnings for real.
local STATE = getgenv().STATE or (_G :: any).STATE
if not STATE then
	-- editor re-Execute: unhook the previous copy first, otherwise every run
	-- stacks another recorder and each step gets logged twice
	local slot = getgenv()
	if slot.__UTD_SHIM_ORIG then
		pcall(hookmetamethod, game, "__namecall", slot.__UTD_SHIM_ORIG)
		slot.__UTD_SHIM_ORIG = nil
	end
	local shimHooks = {}
	local shimOrig
	shimOrig = hookmetamethod(game, "__namecall", function(self, ...)
		local m = getnamecallmethod()
		local h = shimHooks[m]
		if h and not checkcaller() then
			-- a non-nil return substitutes and skips the original, mirroring
			-- the live-reload contract (this is what guarantees single-fire)
			local r = h(self, m, ...)
			if r ~= nil then
				return r
			end
		end
		return shimOrig(self, ...)
	end)
	-- remember the true original for the next editor run's teardown above
	slot.__UTD_SHIM_ORIG = shimOrig
	STATE = {
		namecallHook = function(method, fn)
			shimHooks[method] = fn
		end,
		connect = function(sig, fn)
			return sig:Connect(fn)
		end,
		onCleanup = function(fn)
			-- editor runs have no reload cycle; kept for API shape only
		end,
		alive = function()
			return true
		end,
	}
end

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

local MACRO_DIR = "FallyoUTD/macros"
local EXPORT_DIR = "FallyoUTD/export"
-- writefile can create the folder itself, but make it explicit so listfiles
-- works from the very first save
pcall(makefolder, "FallyoUTD")
pcall(makefolder, MACRO_DIR)
pcall(makefolder, EXPORT_DIR)

-- Notify takes a single text string (no title table), so wrap it
local function notify(title, desc, time)
	pcall(function()
		Library:Notify(tostring(title) .. (desc and ("\n" .. tostring(desc)) or ""), time or 4)
	end)
end

--// State
local RECORDING = false
local RECORDS = {}
local RECORD_T0 = 0
-- map the capture belongs to: MatchBegun's display name is canonical
-- ("Kamii University"); NetworkProxy's matchData.mapId is only a fallback
local RECORD_MAP = nil
local LAST_MATCH_MAP = nil
local LAST_MATCH_MAP_AT = 0
local RecordLabel
-- last per-event lines (step + cash) so the ticker can repaint them
local lastExtra = nil
-- Obsidian buttons expose SetText (writes the data field + the label in one
-- call); the sync below uses it directly.
-- (syncRecordBtn is defined after RecState below)
local RecordBtn = nil
-- recording lifecycle: idle -> recording <-> paused -> finished
local RecState = "idle"
local PAUSE_AT = nil -- clock reading captured when the recording was paused/finished
local function syncRecordBtn()
	if not RecordBtn then
		return
	end
	local want = RecState == "recording" and "Stop" or (RecState == "paused" and "Start" or "Record")
	pcall(function()
		RecordBtn:SetText(want)
	end)
end
local ReplayStatusLabel
-- declared up here: fireRecorded (below) reads it, and Lua only sees
-- locals declared ABOVE the function definition
local ReplayCtx = nil
local ReplayStepLabel

local function inMatchHud()
	local gui = LocalPlayer.PlayerGui:FindFirstChild("MainGui")
	local frames = gui and gui:FindFirstChild("MainFrames")
	local wave = frames and frames:FindFirstChild("Wave")
	return wave ~= nil and wave.Visible == true
end

local function getCash()
	local ls = LocalPlayer:FindFirstChild("leaderstats")
	if not ls then
		return nil
	end
	local c = ls:FindFirstChild("Cash")
	if c and (c:IsA("IntValue") or c:IsA("NumberValue")) then
		return c.Value
	end
	return nil
end

-- Map names differ between the two sources: MatchBegun sends display names
-- ("Kamii University") while NetworkProxy/matchData may use an id
-- ("KamiiUniversity"). Compare them with case/spacing/punctuation stripped.
local function normalizeMapName(name)
	if name == nil then
		return ""
	end
	local s = tostring(name):lower()
	return (s:gsub("[^%w]", ""))
end

-- canonical map name for the current match: MatchBegun wins, the live proxy
-- is only the fallback for recordings started after that event was missed.
-- skipStaleLast = true ignores a LAST_MATCH_MAP left over from a previous
-- match (used by the match-start replay picker before MatchBegun arrives).
local function currentMapName(skipStaleLast)
	if not skipStaleLast and LAST_MATCH_MAP and LAST_MATCH_MAP ~= "" then
		return LAST_MATCH_MAP
	end
	local ok, root = pcall(function()
		local rs = game:GetService("ReplicatedStorage")
		local gm = rs:FindFirstChild("GenericModules")
		local ob = gm and gm:FindFirstChild("Object")
		local mod = ob and ob:FindFirstChild("NetworkProxy")
		if mod and mod:IsA("ModuleScript") then
			local np = require(mod)
			return np and np.root
		end
		return nil
	end)
	local md = ok and root and root.matchData
	if md then
		local id = md.mapId or md.mapName
		if type(id) == "string" and id ~= "" then
			return id
		end
	end
	return nil
end

-- called on every MatchBegun, before the 2s start debounce, so a capture
-- claimed by the HUD poll still gets the canonical map name
local function noteMatchMap(mapName)
	if mapName == nil or mapName == "" then
		return
	end
	LAST_MATCH_MAP = tostring(mapName)
	LAST_MATCH_MAP_AT = os.clock()
	if RecState == "recording" or RecState == "armed" then
		RECORD_MAP = LAST_MATCH_MAP
	end
end

-- last map is only trusted for a short window: at match start the HUD poll
-- can fire before MatchBegun, and a leftover name from the previous match
-- must never start the wrong macro.
local function freshMatchMap()
	if LAST_MATCH_MAP and LAST_MATCH_MAP ~= "" and (os.clock() - LAST_MATCH_MAP_AT) < 8 then
		return LAST_MATCH_MAP
	end
	return nil
end

-- Cash can change for reasons that have nothing to do with the recorded step
-- (wave payouts, kills, cash boosts), so a naive delta between two recorded
-- events is wrong. Instead we watch the Cash value while recording and read the
-- cost off the first dip that lands inside a short window after the step fired.
local CashLog = {}
local CashConn = nil
-- wide enough for a laggy server to take the money; joint attribution keeps
-- later payouts from polluting the math, so width is safe now
local CASH_WINDOW = 3

local function attachCashWatcher()
	if CashConn then
		CashConn:Disconnect()
		CashConn = nil
	end
	local ls = LocalPlayer:FindFirstChild("leaderstats")
	local cash = ls and ls:FindFirstChild("Cash")
	if not cash then
		return false
	end
	CashConn = STATE.connect(cash:GetPropertyChangedSignal("Value"), function()
		table.insert(CashLog, { t = os.clock() - RECORD_T0, v = cash.Value })
	end)
	return true
end

-- readable step names for the recorded remotes
local STEP_NAMES = {
	PlayerPlaceTower = "Place Tower",
	PlayerUpgradeTower = "Upgrade Tower",
	PlayerSellTower = "Sell Tower",
	PlayerSetTowerTargetMode = "Set Target Mode",
	PlayerCancelPhantomTower = "Cancel Phantom",
	PlayerMovePhantomTower = "Move Tower",
	PlayerSelectPhantomPath = "Select Path",
	PlayerActivateTowerAbility = "Activate Ability",
	PlayerToggleAutoAbility = "Toggle Auto Ability",
}

local function stepLabel(rec)
	return STEP_NAMES[rec.name] or (rec.name:gsub("^Player", ""))
end

local function formatCash(n)
	if not n then
		return "?"
	end
	local s = tostring(math.floor(n + 0.5))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return "$" .. out
end

-- time actually spent capturing; paused/finished gaps never count into it
local function recDuration()
	if PAUSE_AT then
		return PAUSE_AT - RECORD_T0
	end
	return os.clock() - RECORD_T0
end

-- the status label is a step flow: every phase (idle, waiting, capturing,
-- paused, finished) shows which step we are on, always.
-- NOTE: record hooks run on the GAME's thread, which may not touch the menu
-- (Plugin capability). SetText is therefore pcall-guarded, and the ticker
-- below repaints from our own thread - a failed paint is retried, never fatal.
local function updateRecordLabel(extra)
	if not RecordLabel then
		return
	end
	local mapText = (RECORD_MAP and RECORD_MAP ~= "") and tostring(RECORD_MAP) or "?"
	local line
	if RecState == "recording" then
		line = string.format("> CAPTURING: %d events, T+%.1fs", #RECORDS, recDuration())
		line ..= "\nMap: " .. mapText
		if extra then
			line ..= extra
		elseif lastExtra then
			line ..= lastExtra
		end
	elseif RecState == "paused" then
		line = string.format("|| PAUSED at %d events, T+%.1fs", #RECORDS, recDuration())
		line ..= "\nMap: " .. mapText
		if lastExtra then
			line ..= "\nLast:" .. lastExtra
		end
		line ..= "\nStart = continue, Finish = end"
	elseif RecState == "armed" then
		line = "... WAITING: match has not started yet"
		line ..= "\nMap: captured when the match begins"
		line ..= "\n- Capture begins at match start (t=0)"
		line ..= "\nRecord = cancel"
	elseif RecState == "finished" then
		line = string.format("* FINISHED: %d events, T+%.1fs", #RECORDS, recDuration())
		line ..= "\nMap: " .. mapText
		line ..= "\nSave Macro to keep it, Record to start over"
	else
		line = "- IDLE: press Record"
		line ..= "\nNext: wait for match, then capture"
	end
	pcall(function()
		RecordLabel:SetText(line)
	end)
	syncRecordBtn()
end

-- spend check at save: place/upgrade/sell MUST have moved cash; a nil cost
-- means the click died server-side (nothing charged) and replaying it is
-- dead weight that only desyncs the run. Only judges when the cash watcher
-- actually ran (non-empty log). Free actions (target mode, phantom moves,
-- paths, abilities, auto-ability) are always kept. Returns pruned, dropped.
-- NOTE: this table MUST stay above computeCosts - Lua locals are only
-- visible after their declaration line.
local SPEND_REQUIRED = {
	PlayerPlaceTower = true,
	PlayerUpgradeTower = true,
	PlayerSellTower = true,
}

-- cost of a step = the deepest cash dip inside a short window after that step
-- fired. The window's HIGHEST point is the baseline, not the fire-time
-- snapshot: a kill/wave payout landing between the click and the server
-- taking the money would otherwise shrink (or hide) the real spend.
-- positive = spent, negative = gained (a sell), nil = the server never moved
-- the cash for this step (or the window has not closed yet).
local function costOf(rec, cashLog)
	local before = rec.cash
	if not before then
		return nil
	end
	local lowest, highest = before, before
	for _, sample in ipairs(cashLog or {}) do
		if sample.t >= rec.t and sample.t <= rec.t + CASH_WINDOW then
			if sample.v < lowest then
				lowest = sample.v
			end
			if sample.v > highest then
				highest = sample.v
			end
		end
	end
	if lowest < before then
		return highest - lowest
	elseif highest > before then
		return -(highest - before)
	end
	return nil
end

local function computeCosts(events, cashLog)
	cashLog = cashLog or {}
	-- JOINT drop attribution. The balance is one shared pool: with independent
	-- per-step windows, 3 rapid upgrades sharing a single dip would each claim
	-- the full dip and the replay would wait 3x the cash. Instead walk the log
	-- once, cut it into falling segments, and give every segment to exactly
	-- one step: the earliest spend-requiring step covering it that does not
	-- already own a segment (falls back to the earliest covering step, so a
	-- real spend is never lost - over-waiting beats a lost tower level).
	-- Free actions never own drops. Sells (pure rises) keep a local
	-- gain check; anything with no movement stays nil (prunable at save).
	local spenders = {}
	for idx, rec in ipairs(events) do
		if SPEND_REQUIRED[rec.name] then
			spenders[#spenders + 1] = { idx = idx, t = rec.t or 0 }
		end
	end
	local segs = {}
	do
		local prevV, prevT, segStart, segAmt = nil, nil, nil, 0
		local function closeSeg(endT)
			if segStart ~= nil and segAmt > 0 then
				segs[#segs + 1] = { t0 = segStart, t1 = endT, amt = segAmt }
			end
			segStart, segAmt = nil, 0
		end
		for _, s in ipairs(cashLog) do
			if prevV ~= nil then
				local move = prevV - s.v
				if move > 0 then
					if segStart == nil then
						segStart = prevT
					end
					segAmt += move
				else
					closeSeg(prevT)
				end
			end
			prevV, prevT = s.v, s.t
		end
		closeSeg(prevT)
	end
	local dropByIdx = {}
	for _, sg in ipairs(segs) do
		-- every spend-step covering this fall shares it equally: total
		-- conservation beats precision here. Over-waiting just slows the
		-- replay (and the refire net catches the rest); dropping a real
		-- tower would break the macro, so no step leaves empty-handed.
		local cover = {}
		for _, sp in ipairs(spenders) do
			if sp.t <= sg.t1 and sg.t0 <= sp.t + CASH_WINDOW then
				cover[#cover + 1] = sp
			end
		end
		if #cover > 0 then
			local share = math.floor(sg.amt / #cover + 0.5)
			for _, sp in ipairs(cover) do
				dropByIdx[sp.idx] = (dropByIdx[sp.idx] or 0) + share
			end
		end
	end
	for idx, rec in ipairs(events) do
		local drop = dropByIdx[idx] or 0
		if drop > 0 then
			rec.cost = drop
		else
			local before = rec.cash
			local highest = before
			if before then
				for _, s in ipairs(cashLog) do
					if s.t >= rec.t and s.t <= rec.t + CASH_WINDOW and s.v > highest then
						highest = s.v
					end
				end
			end
			if before and highest > before then
				rec.cost = -(highest - before)
			else
				rec.cost = nil
			end
		end
	end
	return events
end

local function pruneUnspent(events, cashLog)
	if not (cashLog and #cashLog > 0) then
		return events, 0
	end
	local kept, dropped = {}, 0
	for _, rec in ipairs(events) do
		if SPEND_REQUIRED[rec.name] and rec.cost == nil then
			-- soft prune: a spend landing just past the window (laggy server)
			-- still counts - only drop when the 5s after the step are silent
			local later = false
			for _, s in ipairs(cashLog) do
				if s.t > rec.t and s.t <= rec.t + 5 then
					later = true
					break
				end
			end
			if not later then
				dropped += 1
			else
				kept[#kept + 1] = rec
			end
		else
			kept[#kept + 1] = rec
		end
	end
	return kept, dropped
end

-- live spend line: the window closes CASH_WINDOW after the step, so resolve
-- the cost then and repaint the label if this is still the latest step
local function resolveSpend(rec)
	task.delay(CASH_WINDOW + 0.1, function()
		rec.cost = costOf(rec, CashLog)
		if RecState == "recording" and RECORDS[#RECORDS] == rec then
			local extra = string.format("\nStep: %s", stepLabel(rec))
			if rec.cost and rec.cost > 0 then
				extra ..= string.format("\nSpent: %s", formatCash(rec.cost))
			elseif rec.cost and rec.cost < 0 then
				extra ..= string.format("\nGained: %s", formatCash(-rec.cost))
			end
			if rec.cash then
				extra ..= string.format("\nCash: %s", formatCash(rec.cash))
			end
			lastExtra = extra
			updateRecordLabel(extra)
		end
	end)
end

--// Serialization
local function safePath(inst)
	local parts = {}
	local cur = inst
	while cur and cur ~= game do
		table.insert(parts, 1, cur.Name)
		cur = cur.Parent
	end
	return table.concat(parts, ".")
end

local function resolvePath(path)
	local cur = game
	for name in path:gmatch("[^%.]+") do
		cur = cur:FindFirstChild(name)
		if not cur then
			return nil
		end
	end
	return cur
end

local function ser(v, depth)
	depth = depth or 0
	local tt = type(v)
	if tt == "nil" or tt == "number" or tt == "string" or tt == "boolean" then
		return v
	elseif tt == "table" then
		if depth >= 6 then
			return tostring(v)
		end
		local out = {}
		for k, val in pairs(v) do
			local key = (type(k) == "number") and k or tostring(k)
			out[key] = ser(val, depth + 1)
		end
		return out
	elseif tt == "Instance" then
		return { __t = "inst", p = safePath(v) }
	end
	-- Roblox data types: under the current Luau type system type() reports
	-- these as "vector"/"userdata", so typeof() is the only reliable check.
	local rt = typeof(v)
	if rt == "Vector3" then
		return { __t = "v3", v = { v.X, v.Y, v.Z } }
	elseif rt == "Vector2" then
		return { __t = "v2", v = { v.X, v.Y } }
	elseif rt == "CFrame" then
		return { __t = "cf", v = { v:GetComponents() } }
	elseif rt == "Color3" then
		return { __t = "c3", v = { v.R, v.G, v.B } }
	elseif rt == "Color3uint8" then
		return { __t = "c3", v = { v.R / 255, v.G / 255, v.B / 255 } }
	elseif rt == "EnumItem" then
		return { __t = "enum", v = tostring(v) }
	end
	return tostring(v)
end

local function deser(v, depth)
	depth = depth or 0
	local t = type(v)
	if t ~= "table" or depth > 8 then
		return v
	end
	if v.__t then
		local k = v.__t
		if k == "inst" then
			return resolvePath(v.p)
		elseif k == "v3" then
			return Vector3.new(v.v[1], v.v[2], v.v[3])
		elseif k == "v2" then
			return Vector2.new(v.v[1], v.v[2])
		elseif k == "cf" then
			return CFrame.new(unpack(v.v))
		elseif k == "c3" then
			return Color3.new(v.v[1], v.v[2], v.v[3])
		elseif k == "enum" then
			-- "Enum.KeyCode.X" back into the real enum item when possible
			local typeName, itemName = tostring(v.v):match("^Enum%.([%w_]+)%.([%w_]+)$")
			if typeName and itemName then
				local okE, res = pcall(function()
					return Enum[typeName][itemName]
				end)
				if okE and res ~= nil then
					return res
				end
			end
			return v.v
		end
	end
	local out = {}
	for k, val in pairs(v) do
		out[k] = deser(val, depth + 1)
	end
	return out
end

-- tower entity ids ("20") are handed out per match, so a raw replay aims at
-- ids that do not exist in the new match. TowerPlacedSuccessfully carries the
-- fresh id for every placed tower - capture it on both sides and rewrite:
-- recording: place rec -> old id | replay: place rec -> new id, then
-- upgrade-like steps look up old id -> place rec -> new id.
local ENTITY_REMOTES = {
	PlayerUpgradeTower = true,
	PlayerSellTower = true,
	PlayerSetTowerTargetMode = true,
	PlayerActivateTowerAbility = true,
	PlayerToggleAutoAbility = true,
}
-- pre-place cursor mimicry: recorded for completeness, skipped in replay
local PHANTOM_REMOTES = {
	PlayerCancelPhantomTower = true,
	PlayerMovePhantomTower = true,
	PlayerSelectPhantomPath = true,
}
local PlaceQueue = {} -- place recs awaiting the server id (recording side)

-- args go through JSON, and JSON cannot tell an array from an object reliably
-- once keys get stringified. So every arg is stored under a string key and the
-- count lives in its own field instead of inside the args table.
local function packArgs(...)
	local n = select("#", ...)
	local out = {}
	for i = 1, n do
		local v = select(i, ...)
		out[tostring(i)] = ser(v, 0)
	end
	return out, n
end

-- args are written with string keys, but JSON turns a 1..n table back into an
-- array, so read either form
local function argAt(args, i)
	if type(args) ~= "table" then
		return nil
	end
	local v = args[i]
	if v == nil then
		v = args[tostring(i)]
	end
	return v
end

local function fireRecorded(rec, ctx)
	local remote = resolvePath(rec.path)
	if not remote or not (remote:IsA("BaseRemoteEvent") or remote:IsA("RemoteFunction")) then
		-- a remote that shows up a beat late must not silently eat the step:
		-- hold briefly (bounded) and re-resolve instead of skipping it
		if ctx and ReplayCtx == ctx and not ctx.paused then
			local t0 = os.clock()
			while os.clock() - t0 < 1 and ReplayCtx == ctx and not ctx.paused do
				task.wait(0.05)
				remote = resolvePath(rec.path)
				if remote and (remote:IsA("BaseRemoteEvent") or remote:IsA("RemoteFunction")) then
					break
				end
			end
		end
	end
	if not remote or not (remote:IsA("BaseRemoteEvent") or remote:IsA("RemoteFunction")) then
		return false
	end
	local args = {}
	local n = tonumber(rec.argn)
	if n == nil and type(rec.args) == "table" then
		-- older macro files kept the count inside the args table
		n = tonumber(rec.args.n)
		if n == nil then
			n = 0
			for k in pairs(rec.args) do
				local num = tonumber(k)
				if num and num > n then
					n = num
				end
			end
		end
	end
	n = n or 0
	if n > 0 then
		for i = 1, n do
			args[i] = deser(argAt(rec.args, i))
		end
	end
	-- entity-id rewrite: an upgrade-like step aims at the OLD match's tower
	-- id; swap it for this match's id through the shared place rec.
	-- If the place went out but its id response is still in flight, hold
	-- briefly (bounded) instead of firing stale. If the place itself died,
	-- skip: the tower does not exist here.
	if ctx and ctx.placeByEntity and ENTITY_REMOTES[rec.name] and n >= 1 and args[1] ~= nil then
		local oldRec = ctx.placeByEntity[tostring(args[1])]
		local newId = oldRec and ctx.newIdByRec[oldRec]
		if not newId and oldRec and not (ctx.deadRecs and ctx.deadRecs[oldRec]) then
			local waited = 0
			while not ctx.newIdByRec[oldRec] and waited < 1.5 and ReplayCtx == ctx and not ctx.paused do
				task.wait(0.1)
				waited += 0.1
			end
			newId = ctx.newIdByRec[oldRec]
		end
		if newId then
			args[1] = newId
		elseif oldRec and ctx.deadRecs and ctx.deadRecs[oldRec] then
			return false
		end
	end
	local ok, err = pcall(function()
		remote:FireServer(unpack(args, 1, n))
	end)
	if not ok then
		warn("[UTD] replay fire err: " .. tostring(err))
		if ctx and rec.name == "PlayerPlaceTower" then
			ctx.deadRecs = ctx.deadRecs or {}
			ctx.deadRecs[rec] = true
		end
	elseif ctx and rec.name == "PlayerPlaceTower" then
		-- queue the fired place so the server's id response can be matched
		table.insert(ctx.placeQueue, rec)
	end
	return ok
end

--// Recording filter: tower actions only, PlayerReadyForNextWave excluded
-- (the game auto-skips waves by default anyway)
-- value = true: always capture | value = "SomeToggle": capture only while
-- that Record* toggle is on. Place is the backbone of every macro, so it
-- is always kept.
local RECORD_WHITELIST = {
	PlayerPlaceTower = true,
	PlayerUpgradeTower = "RecordUpgrades",
	PlayerSellTower = "RecordSells",
	PlayerSetTowerTargetMode = "RecordTarget",
	PlayerActivateTowerAbility = "RecordAbility",
	PlayerToggleAutoAbility = "RecordAbility",
	PlayerCancelPhantomTower = true,
	PlayerMovePhantomTower = true,
	PlayerSelectPhantomPath = true,
	-- settings toggles (e.g. "toggleAutoUpgrade", true/false) - plain string +
	-- bool args, replayed verbatim, no cash/entity handling
	PlayerSetSetting = true,
}

local function shouldRecord(remote)
	local gate = RECORD_WHITELIST[remote.Name]
	if not gate then
		return false
	end
	if gate ~= true then
		local t = Toggles[gate]
		if not (t and t.Value) then
			return false
		end
	end
	return true
end

-- instance args (tower models etc.) do not survive into a new match: the
-- replay refires nil for them. Warn once per remote so it is visible.
local InstanceWarned = {}

--// Namecall hook
STATE.namecallHook("FireServer", function(self, method, ...)
	if RECORDING and not checkcaller() and typeof(self) == "Instance" and self:IsA("BaseRemoteEvent") and shouldRecord(self) then
		local ok, err = pcall(function(...)
			local args, argn = packArgs(...)
			if not InstanceWarned[self.Name] then
				for i = 1, argn do
					if typeof(select(i, ...)) == "Instance" then
						InstanceWarned[self.Name] = true
						warn("[UTD] " .. self.Name .. " takes an Instance arg - it replays as nil in a new match")
						break
					end
				end
			end
			local rec = {
				t = os.clock() - RECORD_T0,
				path = safePath(self),
				name = self.Name,
				cash = getCash(),
				args = args,
				argn = argn,
			}
			table.insert(RECORDS, rec)
			resolveSpend(rec)
			if rec.name == "PlayerPlaceTower" then
				table.insert(PlaceQueue, rec)
			end
			if RecordLabel then
				local extra = string.format("\nStep: %s", stepLabel(rec))
				if rec.cash then
					extra ..= string.format("\nCash: %s", formatCash(rec.cash))
				end
				lastExtra = extra
				updateRecordLabel(extra)
			end
		end, ...)
		if not ok then
			warn("[UTD] record err: " .. tostring(err))
		end
	end
	-- fire the original ourselves EXACTLY once, then return false so the
	-- wrapper substitutes (and never re-runs) it. Returning nothing would rely
	-- on implicit passthrough, which demonstrably swallows the call - that is
	-- why nothing could be placed while recording. Game code never uses a
	-- FireServer return value, so substituting false is invisible.
	self[method](self, ...)
	return false
end)

STATE.namecallHook("InvokeServer", function(self, method, ...)
	if RECORDING and not checkcaller() and typeof(self) == "Instance" and self:IsA("RemoteFunction") and shouldRecord(self) then
		pcall(function(...)
			local args, argn = packArgs(...)
			local rec = {
				t = os.clock() - RECORD_T0,
				path = safePath(self),
				name = self.Name,
				cash = getCash(),
				args = args,
				argn = argn,
			}
			table.insert(RECORDS, rec)
			resolveSpend(rec)
			if RecordLabel then
				local extra = string.format("\nStep: %s", stepLabel(rec))
				if rec.cash then
					extra ..= string.format("\nCash: %s", formatCash(rec.cash))
				end
				lastExtra = extra
				updateRecordLabel(extra)
			end
		end, ...)
	end
	-- same single-fire guarantee as FireServer: run it ourselves, then hand
	-- the real reply back as the substitute so the wrapper skips the original.
	-- A void reply becomes false (callers of these remotes never read it).
	local rep = table.pack(self[method](self, ...))
	if rep.n == 0 then
		return false
	end
	return table.unpack(rep, 1, rep.n)
end)

--// Macro storage
local function listMacros()
	local out = {}
	local ok, files = pcall(listfiles, MACRO_DIR)
	if ok then
		for _, f in ipairs(files) do
			local base = f:match("([^/\\]+)%.json$")
			if base then
				table.insert(out, base)
			end
		end
	end
	table.sort(out)
	return out
end

local function refreshMacroList()
	local names = listMacros()
	if Options.MacroSelect then
		-- never hand the dropdown an empty table; its display code assumes at
		-- least one entry. "-" simply fails the load with a notify.
		Options.MacroSelect:SetValues(#names > 0 and names or { "-" })
	end
	return names
end

-- macro names become file paths, so keep them to safe characters
local function safeName(name)
	local n = tostring(name or "")
	n = n:gsub("[^%w%-%_%. ]", "_")
	n = n:gsub("%.%.", "_")
	n = n:gsub("^%s+", ""):gsub("%s+$", "")
	if n == "" then
		n = "macro_" .. tostring(math.random(1000, 9999))
	end
	return n
end

local function saveMacro(name, events, tolerance, cashLog, mapName)
	-- the initial idle before the first action is not part of the macro:
	-- shift the whole run so the first step sits at t=0 (gaps after it stay
	-- exactly as recorded). cashLog shifts with it so costs still line up.
	local base = (events and events[1] and tonumber(events[1].t)) or 0
	local outEvents, outCash = events, cashLog
	if base > 0 then
		outEvents = {}
		for i, e in ipairs(events) do
			local copy = {}
			for k, v in pairs(e) do
				copy[k] = v
			end
			copy.t = (tonumber(e.t) or 0) - base
			outEvents[i] = copy
		end
		outCash = {}
		for i, s in ipairs(cashLog or {}) do
			outCash[i] = { t = (tonumber(s.t) or 0) - base, v = s.v }
		end
	end
	local payload = {
		game = "Ultimate Tower Defense",
		created = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		-- nil omits the field in JSON; legacy macros simply have no map
		map = (mapName and mapName ~= "") and tostring(mapName) or nil,
		tolerance = tolerance or 1.05,
		events = outEvents,
		cashLog = outCash,
	}
	local ok, json = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if not ok then
		return false, "encode failed: " .. tostring(json)
	end
	local okW, errW = pcall(writefile, MACRO_DIR .. "/" .. name .. ".json", json)
	if not okW then
		return false, "write failed: " .. tostring(errW)
	end
	return true
end

-- after JSONDecode an array can come back with string keys, which ipairs
-- will not walk. Rebuild it as a real array.
local function normalizeEvents(events)
	local out = {}
	if type(events) ~= "table" then
		return out
	end
	for _, e in ipairs(events) do
		out[#out + 1] = e
	end
	if #out == 0 then
		local i = 1
		while events[tostring(i)] do
			out[i] = events[tostring(i)]
			i += 1
		end
	end
	return out
end

local function loadMacro(name)
	local ok, content = pcall(readfile, MACRO_DIR .. "/" .. name .. ".json")
	if not ok then
		return nil, "read failed: " .. tostring(content)
	end
	local ok2, data = pcall(HttpService.JSONDecode, HttpService, content)
	if not ok2 or type(data) ~= "table" then
		return nil, "json failed"
	end
	if data.events then
		local events = normalizeEvents(data.events)
		-- drop entries the replay engine cannot run (corrupt / hand-edited files),
		-- otherwise a missing name or time would crash the replay thread
		local clean, dropped = {}, 0
		for _, e in ipairs(events) do
			local t = type(e) == "table" and tonumber(e.t) or nil
			if type(e) == "table" and type(e.name) == "string" and t then
				e.t = t
				clean[#clean + 1] = e
			else
				dropped += 1
			end
		end
		if dropped > 0 then
			warn("[UTD] dropped " .. dropped .. " invalid event(s) from " .. tostring(name))
		end
		data.events = computeCosts(clean, data.cashLog)
		-- old tower id -> the place step that created it (for replay remap)
		local byEntity = {}
		for _, e in ipairs(data.events) do
			if e.name == "PlayerPlaceTower" then
				if e.entityId ~= nil then
					byEntity[tostring(e.entityId)] = e
				end
				if e.entityId2 ~= nil then
					byEntity[tostring(e.entityId2)] = e
				end
			end
		end
		-- repair for macros recorded before the id-reply race was fixed: a
		-- place step whose TowerPlacedSuccessfully reply was missed stays
		-- without entityId, so every later ability/upgrade step on that tower
		-- points at an id nothing maps to (the step fired stale and did
		-- nothing). Ability/upgrade steps only ever reference OUR towers, so
		-- exactly one unstamped place step + exactly one unknown id means that
		-- id belongs to it - stamp it now so the replay can remap.
		local unstamped = {}
		for _, e in ipairs(data.events) do
			if e.name == "PlayerPlaceTower" and e.entityId == nil then
				unstamped[#unstamped + 1] = e
			end
		end
		if #unstamped == 1 then
			local unknown = {}
			-- the place rec is the earliest tower placed while recording, so a
			-- step that predates it cannot belong to it (it would have to
			-- reference a tower that already existed before the recording
			-- started) - skip those instead of guessing.
			local recAt = tonumber(unstamped[1].t) or 0
			for _, e in ipairs(data.events) do
				if ENTITY_REMOTES[e.name] and (tonumber(e.t) or 0) >= recAt - 0.001 then
					local a1 = argAt(e.args, 1)
					if type(a1) == "string" or type(a1) == "number" then
						local id = tostring(a1)
						if not byEntity[id] then
							unknown[id] = true
						end
					end
				end
			end
			local ids = {}
			for id in pairs(unknown) do
				ids[#ids + 1] = id
			end
			if #ids == 1 then
				unstamped[1].entityId = ids[1]
				byEntity[ids[1]] = unstamped[1]
			end
		end
		data.placeByEntity = byEntity
	end
	return data
end

-- Auto Name Replay scans EVERY saved macro and picks the newest one whose
-- saved map matches the match. Comparison ignores case/spaces so
-- "Kamii University" (MatchBegun) meets "KamiiUniversity" (queue name).
local function findMacroByMap(mapName)
	local key = normalizeMapName(mapName)
	if key == "" then
		return nil
	end
	local bestName, bestCreated
	for _, name in ipairs(listMacros()) do
		local ok, content = pcall(readfile, MACRO_DIR .. "/" .. name .. ".json")
		if ok then
			local okD, data = pcall(HttpService.JSONDecode, HttpService, content)
			if okD and type(data) == "table" and type(data.map) == "string" then
				if normalizeMapName(data.map) == key then
					local created = type(data.created) == "string" and data.created or ""
					if not bestName or created > bestCreated or (created == bestCreated and name > bestName) then
						bestName, bestCreated = name, created
					end
				end
			end
		end
	end
	if not bestName then
		return nil
	end
	local data = loadMacro(bestName)
	if not data or not data.events or #data.events == 0 then
		return nil
	end
	return bestName, data
end

--// Replay

local function updateReplayStatus()
	local ctx = ReplayCtx
	if not ctx then
		if ReplayStatusLabel then
			ReplayStatusLabel:SetText("Replay: idle")
		end
		if ReplayStepLabel then
			ReplayStepLabel:SetText("")
		end
		return
	end
	local done = math.min(ctx.i - 1, #ctx.events)
	local rec = ctx.events[ctx.i]
	-- same game-thread hazard as the record label: guard every paint
	if ReplayStatusLabel then
		local head
		local w = ctx.waiting
		if ctx.paused then
			head = "Paused"
		elseif w and w.kind == "time" then
			head = string.format("Waiting for time (%.1fs)", math.max(0, w.left))
		elseif w and w.kind == "cash" then
			head = string.format("Waiting for cash (%s short)", formatCash(w.need - w.have))
			if w.left then
				head ..= string.format("  %.0fs left", math.max(0, w.left))
			end
		else
			head = "Replaying"
		end
		pcall(function()
			ReplayStatusLabel:SetText(string.format(
				"%s  %d/%d  -  Cash %s",
				head,
				done,
				#ctx.events,
				formatCash(getCash())
			))
		end)
	end
	if ReplayStepLabel and rec then
		local line = string.format("Step %d: %s", ctx.i, stepLabel(rec))
		if rec.cost and rec.cost ~= 0 then
			if rec.cost > 0 then
				line ..= string.format("  (-%s)", formatCash(rec.cost))
			else
				line ..= string.format("  (+%s)", formatCash(-rec.cost))
			end
		end
		pcall(function()
			ReplayStepLabel:SetText(line)
		end)
	end
end

local function stopReplay(reason)
	if ReplayCtx then
		ReplayCtx = nil
		updateReplayStatus()
		notify("Replay stopped", reason or "")
	end
end

local function togglePause()
	local ctx = ReplayCtx
	if not ctx then
		return
	end
	ctx.paused = not ctx.paused
	if ctx.paused then
		-- remember when the pause began; on resume the timeline is shifted by the
		-- paused duration, otherwise every step scheduled during the pause would
		-- fire in one burst
		ctx.pauseAt = os.clock()
	elseif ctx.pauseAt then
		-- slide the schedule forward by the paused gap
		local gap = os.clock() - ctx.pauseAt
		ctx.t0 = ctx.t0 + gap
		if ctx.nextAt then
			ctx.nextAt = ctx.nextAt + gap
		end
		ctx.pauseAt = nil
	end
	updateReplayStatus()
end

-- pre-flight: verify every remote in the macro still exists, count usage
local function validateMacro(events)
	local counts, missing = {}, {}
	for _, rec in ipairs(events) do
		counts[rec.name] = (counts[rec.name] or 0) + 1
		local r = resolvePath(rec.path)
		if not r then
			missing[rec.name] = true
		elseif not (r:IsA("BaseRemoteEvent") or r:IsA("RemoteFunction")) then
			missing[rec.name] = true
		end
	end
	return counts, missing
end

local function summarizeCounts(counts)
	local parts = {}
	for name, n in pairs(counts) do
		parts[#parts + 1] = name:gsub("^Player", "") .. " x" .. n
	end
	table.sort(parts)
	return table.concat(parts, ", ")
end

-- pacer: never fire faster than this. The server silently drops upgrades
-- arriving in a burst (catch-up backlog, spam taps); paced fires get
-- accepted. Only binds when steps are denser than the gap, so recorded
-- rhythm is untouched otherwise. Kept low so replay runs at recording pace.
local FIRE_GAP = 0.25
local function paceFire(ctx)
	local last = ctx.lastFire or 0
	local wait = FIRE_GAP - (os.clock() - last)
	if wait > 0 then
		task.wait(wait)
	end
	ctx.lastFire = os.clock()
end

-- schedule the next step relative to NOW, scaled from only the recorded GAP
-- to that step: the live tolerance slider then slows down what comes next
-- without ever rescaling the history that already played.
-- Anchored to the step's DUE time, not to the firing moment: cash waits and
-- spend confirmations then catch up instead of pushing every later step late,
-- so the run stays on the recorded rhythm (their cost in time is absorbed,
-- not billed to the timeline).
local function advanceStep(ctx, rec)
	ctx.i += 1
	local nxt = ctx.events[ctx.i]
	if nxt then
		local tol = Options.Tolerance.Value or ctx.tolerance
		local base = ctx.nextAt or os.clock()
		if base > os.clock() then
			base = os.clock()
		end
		ctx.nextAt = base + math.max(0, nxt.t - rec.t) * tol
	end
end

-- post-fire spend check: did the server actually take money? True if any
-- dip is seen within timeout (a rise for sells, a fresh tower id for
-- places). Read-only: never touches the macro file.
-- Returns true on stop/pause too (the main loop owns those states).
local function confirmSpend(rec, ctx, timeout)
	local base = getCash()
	if not base and not (ctx and ctx.newIdByRec and ctx.newIdByRec[rec]) then
		return true -- no baseline and nothing to match: cannot judge
	end
	local wantRise = (rec.cost or 0) < 0 -- sells confirm by gain, not dip
	local t0 = os.clock()
	while os.clock() - t0 < (timeout or 2) do
		if ReplayCtx ~= ctx or ctx.paused then
			return true
		end
		if ctx.newIdByRec and ctx.newIdByRec[rec] then
			return true -- server answered with the tower: placed, for sure
		end
		task.wait(0.05)
		local nowCash = getCash()
		if nowCash and base then
			if wantRise and nowCash > base + 1 then
				return true
			elseif not wantRise and nowCash < base - 1 then
				return true
			end
		end
	end
	return ReplayCtx ~= ctx
end

-- every distinct remote a macro touches must exist before the first step:
-- firing into a still-loading remote is a silent skip that desyncs the run.
-- Only the opening seconds are checked: later steps resolve their remotes at
-- their own due time, so one missing cosmetic path can never stall the start.
-- Bounded and instant when ready, so replay timing is untouched.
local function waitForStepRemotes(events, timeout)
	local seen, missing = {}, {}
	for _, rec in ipairs(events) do
		if (rec.t or 0) > 2 then
			break
		end
		if rec.path and not seen[rec.path] and not PHANTOM_REMOTES[rec.name] then
			seen[rec.path] = true
			missing[#missing + 1] = rec.path
		end
	end
	if #missing == 0 then
		return
	end
	local t0 = os.clock()
	while os.clock() - t0 < (timeout or 1.5) do
		local allHere = true
		for _, path in ipairs(missing) do
			local r = resolvePath(path)
			if not (r and (r:IsA("BaseRemoteEvent") or r:IsA("RemoteFunction"))) then
				allHere = false
				break
			end
		end
		if allHere then
			return
		end
		task.wait(0.1)
	end
	warn("[UTD] some remotes still missing at replay start")
end

local function startReplay(events, tolerance, placeByEntity)
	if ReplayCtx then
		return false
	end
	if RecState == "recording" or RecState == "paused" then
		-- replay spends would pollute the live capture's cash log: refuse
		notify("Replay refused", "Finish or cancel recording first", 4)
		return false
	end
	if not events or #events == 0 then
		return false
	end
	tolerance = tolerance or 1.05
	-- the idle head before the first action never counts: make the earliest
	-- step t=0 so replay starts on it. later gaps keep the recorded rhythm.
	-- (macros saved by this version are already trimmed; old ones are not)
	local base
	for _, e in ipairs(events) do
		local t = tonumber(e.t) or 0
		if not base or t < base then
			base = t
		end
	end
	base = base or 0
	if base > 0 then
		for _, e in ipairs(events) do
			e.t = (tonumber(e.t) or 0) - base
		end
	end
	waitForStepRemotes(events, 1.5)
	local ctx = {
		events = events,
		i = 1,
		t0 = os.clock(),
		tolerance = tolerance,
		nextAt = os.clock() + math.max(0, (events[1].t or 0)) * tolerance,
		skipped = 0,
		fired = 0,
		paused = false,
		waiting = nil,
		cashWait = 0,
		noCash = 0,
		noConfirm = 0,
		lastHud = 0,
		pauseAt = nil,
		placeByEntity = placeByEntity or {},
		newIdByRec = {},
		placeQueue = {},
		deadRecs = {},
	}
	ReplayCtx = ctx
	updateReplayStatus()
	task.spawn(function()
		while ReplayCtx == ctx and STATE.alive() and myGenAlive() do
			if ctx.paused then
				task.wait(0.1)
			elseif ctx.i > #ctx.events then
				if Toggles.LoopReplay.Value then
					ctx.i = 1
					ctx.t0 = os.clock()
					ctx.nextAt = os.clock()
						+ math.max(0, ctx.events[1].t or 0)
							* (Options.Tolerance.Value or ctx.tolerance)
					-- fresh loop, fresh towers: drop the old id mapping
					ctx.newIdByRec = {}
					ctx.placeQueue = {}
					task.wait(0.5)
				else
					break
				end
			else
				-- match-end guard: leaving the match stops the replay. The first
				-- seconds are a grace period so a HUD that appears slightly after
				-- MatchBegun does not kill an auto replay instantly.
				local checked = os.clock()
				if checked - ctx.t0 >= 3 and checked - ctx.lastHud >= 0.5 then
					ctx.lastHud = checked
					if Toggles.StopOnGameover.Value and not inMatchHud() then
						stopReplay("match ended")
						break
					end
				end
				-- tolerance is a SLOWDOWN factor: 1.05x = ~5% slower than recorded,
				-- so the server keeps up and the player never runs out of cash.
				local rec = ctx.events[ctx.i]
				local now = os.clock()
				if ctx.nextAt > now then
					ctx.waiting = { kind = "time", left = ctx.nextAt - now }
					updateReplayStatus()
					task.wait(math.min(ctx.nextAt - now, 0.05))
				elseif not ctx.paused and ReplayCtx == ctx then
					-- phantom UI mimicry (pre-place cursor moves) has no server
					-- effect in replay: recorded for the record, skipped here
					if PHANTOM_REMOTES[rec.name] then
						ctx.phantom = (ctx.phantom or 0) + 1
						advanceStep(ctx, rec)
						updateReplayStatus()
					else
					-- time arrived: if the step needs cash we don't have yet, hold.
					-- "Wait for Cash" toggle off = skip the gate entirely, fire the
					-- step right away (the server rejects it if you truly can't
					-- afford it) - for when a bad recorded cost would false-skip.
					local need = rec.cost
					if not (Toggles.CashWaitOn and Toggles.CashWaitOn.Value) then
						need = nil
					end
					if type(need) == "number" and need > 0 then
						local have = getCash() or 0
						if have < need then
							local maxWait = Options.CashWait.Value or 15
							ctx.cashWait += 0.1
							if maxWait > 0 and ctx.cashWait >= maxWait then
								-- gave up waiting, skip this step instead of stalling forever.
								-- A skipped place orphans its upgrades: mark it dead so
								-- their remap finds nothing and they skip cleanly
								-- instead of firing stale ids into the void.
								if rec.name == "PlayerPlaceTower" then
									ctx.deadRecs = ctx.deadRecs or {}
									ctx.deadRecs[rec] = true
								end
								ctx.noCash += 1
								ctx.cashWait = 0
								ctx.waiting = nil
								advanceStep(ctx, rec)
								updateReplayStatus()
							else
								ctx.waiting = {
									kind = "cash",
									need = need,
									have = have,
									left = maxWait > 0 and (maxWait - ctx.cashWait) or nil,
								}
								updateReplayStatus()
							end
							task.wait(0.1)
						else
							ctx.cashWait = 0
							ctx.waiting = nil
							paceFire(ctx)
							if fireRecorded(rec, ctx) then
								ctx.fired += 1
								-- spend check: server charged? Places get 2 refires
								-- (tower-id answer proves them); upgrades get 1 -
								-- a blind second upgrade would level twice.
								if not confirmSpend(rec, ctx, 2) then
									local maxTries = (rec.name == "PlayerPlaceTower") and 2 or 1
									local tries = 0
									while tries < maxTries and ReplayCtx == ctx and not ctx.paused do
										tries += 1
										paceFire(ctx)
										if not fireRecorded(rec, ctx) then
											break
										end
										if confirmSpend(rec, ctx, 2) then
											break
										end
									end
									if ReplayCtx == ctx and not ctx.paused then
										ctx.noConfirm += 1
									end
								end
							else
								ctx.skipped += 1
							end
							if ReplayCtx ~= ctx then
								break
							end
							advanceStep(ctx, rec)
							updateReplayStatus()
						end
					else
						ctx.cashWait = 0
						ctx.waiting = nil
						paceFire(ctx)
						if fireRecorded(rec, ctx) then
							ctx.fired += 1
						else
							ctx.skipped += 1
						end
						advanceStep(ctx, rec)
						updateReplayStatus()
					end
					end
				end
			end
		end
		if ReplayCtx == ctx then
			ReplayCtx = nil
			updateReplayStatus()
			local extra = ""
			if ctx.skipped > 0 then
				extra ..= string.format("\n%d skipped (remote gone)", ctx.skipped)
			end
			if ctx.noCash > 0 then
				extra ..= string.format("\n%d skipped (no cash)", ctx.noCash)
			end
			if ctx.noConfirm > 0 then
				extra ..= string.format("\n%d fired but no spend seen (server ignored?)", ctx.noConfirm)
			end
			if (ctx.phantom or 0) > 0 then
				extra ..= string.format("\n%d phantom step(s) skipped", ctx.phantom)
			end
			notify("Replay finished", ctx.fired .. " events fired" .. extra, 5)
		end
	end)
	return true
end

--// UI
-- sweep our own stale windows first: without this every reload stacks a new
-- copy on screen (the old instance's Unload only runs via onCleanup below)
pcall(function()
	for _, g in ipairs(game:GetService("CoreGui"):GetChildren()) do
		if g:IsA("ScreenGui") then
			for _, d in ipairs(g:GetDescendants()) do
				if d:IsA("TextLabel") and d.Text == "UTD Hub V2" then
					g:Destroy()
					break
				end
			end
		end
	end
end)

-- // PREMIUM SCHEME // CreateWindow'dan ÖNCE set edilir: registry string'leri
-- scheme'i dinamik okur, tum pencere (groupbox, toggle, notification dahil)
-- bu renklerle boyanir. Kullanici UI Settings'te tema secersen ThemeManager
-- override eder - biz sadece DEFAULT guzellestiriyoruz.
local Scheme = Library.Scheme
Scheme.BackgroundColor = Color3.fromRGB(11, 11, 20) -- gece-mor zemin (saf siyah degil)
Scheme.MainColor = Color3.fromRGB(20, 20, 34)       -- panel/kutu ici
Scheme.AccentColor = Color3.fromRGB(139, 92, 246)   -- electric violet (toggle/aktif vurgu)
Scheme.OutlineColor = Color3.fromRGB(38, 34, 63)    -- morumsu ince cerceveler
Scheme.FontColor = Color3.fromRGB(233, 228, 252)    -- sisli mor-beyaz yazi
Scheme.DarkColor = Color3.fromRGB(6, 6, 13)
Scheme.Font = Font.fromEnum(Enum.Font.Gotham)       -- premium sans-serif (mono Code yerine)
Library.CornerRadius = 8                            -- tum kartlarin kose yumusakligi

local Window = Library:CreateWindow({
	Title = "UTD Hub V2",
	Center = true,
	AutoShow = true,
	Font = Enum.Font.Gotham, -- title font'u (EnumItem'i library Font.fromEnum'a cevirir)
	CornerRadius = 8,
	-- pencere/element akisini yumusatan micro-animasyonlar (default hepsi kapali)
	Animations = {
		ToggleWindow = true,
		TabSwitch = true,
		Groupbox = true,
		Dropdown = true,
		KeyPicker = true,
	},
	-- secili tabda accent gosterge + yuvarlak tab butonlari
	TabButtonsStyle = {
		CornerRadius = 6,
		Indicator = true,
	},
	-- Obsidian kendi layout'unu kendi yonetir (icerik ScrollingFrame'de,
	-- sabit yukseklikli kolon yok) - Linoria'daki sides patch'i gereksiz.
	-- Yatay tercih: genislik > yukseklik (940 > 640); her sutun ~458px
	-- olur, slider/dropdown ferah. Obsidian min 480x360; 1366x768 ekranda
	-- bile clamp'e girmez (viewport - 64 siniri).
	Size = UDim2.fromOffset(940, 640),
})
-- next reload destroys this window instead of orphaning it
STATE.onCleanup(function()
	pcall(function()
		Library:Unload()
	end)
end)

-- Tab ikonlari: Obsidian kurulumda lucide setini kendisi fetch eder
-- (pcall'li; ikon servisi olmazsa sadece ikonsuz devam eder, tablar bozulmaz).
-- Adlar lucide kanonik adlaridir (bot/swords/fish/gift/skull/wrench/settings).
local Tabs = {
	Automation = Window:AddTab("Automation", "bot"),
	["Auto Match"] = Window:AddTab("Auto Match", "swords"),
	["Auto Fish"] = Window:AddTab("Auto Fish", "fish"),
	["Auto Banner"] = Window:AddTab("Auto Banner", "gift"),
	["Auto Dungeon"] = Window:AddTab("Auto Dungeon", "skull"),
	Misc = Window:AddTab("Misc", "wrench"),
	["UI Settings"] = Window:AddTab("UI Settings", "settings"),
}

--// Auto Match tab
-- map names pulled from the game's own loading list (ReplicatedFirst.ClientMain)
local CLASSIC_MAPS = {
	"LasNoches", "RubyPalace", "ValleyOfTheEnd", "KamiLookout",
	"Marineford", "PlanetNamek", "CostaSmeralda", "TrostDistrict",
	"Space", "MenosGarden", "KamiiUniversity", "Floria",
	"SkeletonHeelStone", "WisteriaForest", "OrangeTown", "EishuDetention",
	"KameIsland", "AntNest", "HiddenLeafVillage", "ChamberOfAgony",
	"KarakuraTown", "ShibuyaTrainStation",
}
local CLASSIC_DIFFS = {
	Easy = "EasyDifficulty",
	Normal = "NormalDifficulty",
	Hard = "HardDifficulty",
}
-- queue pad position (reported with +10 Y so the drop is safe)
local CLASSIC_POS = Vector3.new(-276.82, 13.41, -128.73)
local classicRun = 0
local dungeonClaimRun = 0
local rematchRun = 0

local function classicRemote(name)
	local RS = game:GetService("ReplicatedStorage")
	local m = RS:FindFirstChild("Modules")
	local g = m and m:FindFirstChild("GlobalInit")
	local re = g and g:FindFirstChild("RemoteEvents")
	return re and re:FindFirstChild(name) or nil
end

local function setClassicAutoStart(on)
	if Toggles.ClassicAutoStart then
		pcall(function()
			Toggles.ClassicAutoStart:SetValue(on)
		end)
	end
end

-- lobby gate: the game's own NetworkProxy table (serverType is "Lobby",
-- "Match", "Chamber", ...). The match-HUD check is only a fallback for the
-- loading window before that data exists.
local function inLobby()
	local ok, st = pcall(function()
		local rs = game:GetService("ReplicatedStorage")
		local gm = rs:FindFirstChild("GenericModules")
		local ob = gm and gm:FindFirstChild("Object")
		local mod = ob and ob:FindFirstChild("NetworkProxy")
		if not (mod and mod:IsA("ModuleScript")) then
			return nil
		end
		local np = require(mod)
		return np and np.root and np.root.serverType
	end)
	if ok and st ~= nil then
		return st == "Lobby"
	end
	return not inMatchHud()
end

-- the single Record check: is a match already running? MatchBegun only
-- exists while a match is live, so its presence means "begun already".
local function matchRunning()
	local RS = game:GetService("ReplicatedStorage")
	local m = RS:FindFirstChild("Modules")
	local g = m and m:FindFirstChild("GlobalInit")
	local re = g and g:FindFirstChild("RemoteEvents")
	return re and re:FindFirstChild("MatchBegun") ~= nil
end

-- bounded character wait: CharacterAdded:Wait() never times out, so poll
-- instead and give up after ~10s.
local function waitCharacter()
	local char = LocalPlayer.Character
	local waited = 0
	while not (char and char:FindFirstChild("HumanoidRootPart")) and waited < 10 do
		task.wait(0.5)
		waited += 0.5
		char = LocalPlayer.Character
	end
	return char and char:FindFirstChild("HumanoidRootPart") or nil
end

-- map -> waves -> difficulty -> quickstart, 1s between each step
local function runClassicAutoStart(id)
	local function alive()
		return id == classicRun and Toggles.ClassicAutoStart.Value and myGenAlive()
	end
	-- Auto Match runs in the lobby only: outside it we simply do nothing and
	-- stay armed (toggle stays ON)
	if not inLobby() then
		return
	end
	-- lobby settle delay so the queue pad and remotes are ready
	local delay = Options.ClassicStartDelay.Value or 4
	task.wait(delay)
	if not alive() then
		return
	end
	local map = Options.ClassicMap.Value
	local waves = tonumber(Options.ClassicWaves.Value) or 10
	local diffKey = Options.ClassicDifficulty.Value or "Normal"
	if not map then
		notify("Classic", "Pick a map first", 4)
		setClassicAutoStart(false)
		return
	end
	-- 1: teleport to the queue pad and settle
	local hrp = waitCharacter()
	if not hrp then
		notify("Classic", "No character", 4)
		setClassicAutoStart(false)
		return
	end
	pcall(function()
		hrp.CFrame = CFrame.new(CLASSIC_POS)
	end)
	task.wait(1)
	if not alive() then
		return
	end
	-- 2: map, one shot
	local rMap = classicRemote("PlayerSelectedMap")
	if not rMap then
		notify("Classic", "PlayerSelectedMap not found", 5)
		setClassicAutoStart(false)
		return
	end
	rMap:FireServer(map)
	task.wait(1)
	if not alive() then
		return
	end
	-- 3: wave count from the Waves dropdown
	local rWaves = classicRemote("PlayerSelectedWaveCount")
	if not rWaves then
		notify("Classic", "PlayerSelectedWaveCount not found", 5)
		setClassicAutoStart(false)
		return
	end
	rWaves:FireServer(waves)
	task.wait(1)
	if not alive() then
		return
	end
	-- 4: difficulty from the Difficulty dropdown
	local rDiff = classicRemote("PlayerSelectedDifficulty")
	if not rDiff then
		notify("Classic", "PlayerSelectedDifficulty not found", 5)
		setClassicAutoStart(false)
		return
	end
	rDiff:FireServer(CLASSIC_DIFFS[diffKey])
	task.wait(1)
	if not alive() then
		return
	end
	-- 5: quickstart teleport into the match
	local rGo = classicRemote("PlayerQuickstartTeleport")
	if not rGo then
		notify("Classic", "PlayerQuickstartTeleport not found", 5)
		setClassicAutoStart(false)
		return
	end
	rGo:FireServer()
	notify("Classic", map .. " | " .. waves .. " waves | " .. diffKey, 5)
end

local ClassicBox = Tabs["Auto Match"]:AddLeftGroupbox("Classic")

ClassicBox:AddDropdown("ClassicMap", {
	Values = CLASSIC_MAPS,
	Default = 1,
	Text = "Map",
})

ClassicBox:AddDropdown("ClassicWaves", {
	Values = { "10", "20", "30" },
	Default = 1,
	Text = "Waves",
})

ClassicBox:AddDropdown("ClassicDifficulty", {
	Values = { "Easy", "Normal", "Hard" },
	Default = 2,
	Text = "Difficulty",
})

ClassicBox:AddSlider("ClassicStartDelay", {
	Text = "Start Delay",
	Default = 4,
	Min = 0,
	Max = 30,
	Rounding = 0,
	Suffix = "s",
	Tooltip = "Wait this long after lobby confirm before teleporting to the queue pad.",
})

ClassicBox:AddToggle("ClassicAutoStart", {
	Default = false,
	Text = "Auto Start Match",
	Tooltip = "Teleport to queue, pick map/waves/difficulty, quickstart.",
	Callback = function(Value)
		if Value then
			classicRun += 1
			task.spawn(runClassicAutoStart, classicRun)
		else
			classicRun += 1 -- abort a run stuck between steps
		end
	end,
})

-- dungeon queue pad position (reported with +10 Y so the drop is safe)
local DUNGEON_POS = Vector3.new(0.12, -11.95, 3983.05)
local dungeonRun = 0

local function setDungeonAutoStart(on)
	if Toggles.DungeonAutoStart then
		pcall(function()
			Toggles.DungeonAutoStart:SetValue(on)
		end)
	end
end

-- gamemode -> quickstart, 1s between each step
-- hardcore/normal cannot be set by remote: press the actual GUI button.
-- firesignal replays the click exactly like a real press.
local function clickDungeonModeButton(hardcore)
	local ok, clicked = pcall(function()
		local pg = LocalPlayer.PlayerGui:FindFirstChild("MainGui")
		local mf = pg and pg:FindFirstChild("MainFrames")
		local fs = mf and mf:FindFirstChild("FloorSelection")
		local sm = fs and fs:FindFirstChild("SelectedMap")
		local btns = sm and sm:FindFirstChild("Buttons")
		local btn = btns and btns:FindFirstChild(hardcore and "HardcoreButton" or "NormalButton")
		if not btn then
			return false
		end
		firesignal(btn.Activated)
		return true
	end)
	return ok and clicked
end

local function runDungeonAutoStart(id)
	local function alive()
		return id == dungeonRun and Toggles.DungeonAutoStart.Value and myGenAlive()
	end
	-- Auto Match runs in the lobby only: outside it we simply do nothing and
	-- stay armed (toggle stays ON)
	if not inLobby() then
		return
	end
	local delay = Options.DungeonStartDelay.Value or 4
	task.wait(delay)
	if not alive() then
		return
	end
	-- 1: teleport to the dungeon queue pad and settle
	local hrp = waitCharacter()
	if not hrp then
		notify("Dungeon", "No character", 4)
		setDungeonAutoStart(false)
		return
	end
	pcall(function()
		hrp.CFrame = CFrame.new(DUNGEON_POS)
	end)
	local modeKey = Options.DungeonMode.Value or "Normal"
	task.wait(1)
	if not alive() then
		return
	end
	-- 2: gamemode via the GUI button (remote does not select it)
	if not clickDungeonModeButton(modeKey == "Hardcore") then
		notify("Dungeon", "Mode button not found", 5)
		setDungeonAutoStart(false)
		return
	end
	task.wait(1)
	if not alive() then
		return
	end
	-- 3: quickstart teleport into the match
	local rGo = classicRemote("PlayerQuickstartTeleport")
	if not rGo then
		notify("Dungeon", "PlayerQuickstartTeleport not found", 5)
		setDungeonAutoStart(false)
		return
	end
	rGo:FireServer()
	notify("Dungeon", modeKey .. " - entering match", 5)
end

local DungeonBox = Tabs["Auto Match"]:AddRightGroupbox("Dungeon")

DungeonBox:AddDropdown("DungeonMode", {
	Values = { "Normal", "Hardcore" },
	Default = 1,
	Text = "Mode",
})

DungeonBox:AddSlider("DungeonStartDelay", {
	Text = "Start Delay",
	Default = 4,
	Min = 0,
	Max = 30,
	Rounding = 0,
	Suffix = "s",
	Tooltip = "Wait this long after lobby confirm before teleporting to the queue pad.",
})

DungeonBox:AddToggle("DungeonAutoStart", {
	Default = false,
	Text = "Auto Start",
	Tooltip = "Teleport to dungeon queue, pick gamemode, quickstart.",
	Callback = function(Value)
		if Value then
			dungeonRun += 1
			task.spawn(runDungeonAutoStart, dungeonRun)
		else
			dungeonRun += 1 -- abort a run stuck between steps
		end
	end,
})

DungeonBox:AddToggle("DungeonAutoClaim", {
	Default = false,
	Text = "Auto Claim Rewards",
	Tooltip = "Fires PlayerClaimDungeonReward every 1 second.",
	Callback = function(Value)
		if Value then
			dungeonClaimRun += 1
			local id = dungeonClaimRun
			task.spawn(function()
				local warned = false
				while id == dungeonClaimRun and Toggles.DungeonAutoClaim.Value and STATE.alive() and myGenAlive() do
					local claim = classicRemote("PlayerClaimDungeonReward")
					if claim then
						warned = false
						pcall(function()
							claim:FireServer()
						end)
					elseif not warned then
						warned = true
						warn("[UTD] PlayerClaimDungeonReward not found")
					end
					task.wait(1)
				end
			end)
		else
			dungeonClaimRun += 1 -- abort the loop
		end
	end,
})

--// Autofish: fires PlayerCatchFish every 1s while the toggle is on
local fishRun = 0
local AutofishBox = Tabs["Auto Fish"]:AddLeftGroupbox("Autofish")

AutofishBox:AddToggle("Autofish", {
	Text = "Auto Fish",
	Default = false,
	Tooltip = "Fires PlayerCatchFish every 1 second.",
	Callback = function(Value)
		if Value then
			fishRun += 1
			local id = fishRun
			task.spawn(function()
				local warned = false
				while id == fishRun and Toggles.Autofish.Value and STATE.alive() and myGenAlive() do
					local rod = classicRemote("PlayerCatchFish")
					if rod then
						warned = false
						pcall(function()
							rod:FireServer()
						end)
					elseif not warned then
						warned = true
						warn("[UTD] PlayerCatchFish not found")
					end
					task.wait(1)
				end
			end)
		else
			fishRun += 1 -- abort the loop
		end
	end,
})

--// Auto Banner tab
-- banner ids follow the game's own pattern: Gold<Amateur|Intermediate|...|Experienced>Banner
-- MAINTENANCE: the summon loop was buggy, so it is parked - the button only
-- announces maintenance (the old pull loop lives in git history)
local BANNER_TIERS = { "Amateur", "Intermediate", "Advanced", "Experienced" }

local BannerBox = Tabs["Auto Banner"]:AddLeftGroupbox("Banner")
BannerBox:AddLabel("Maintenance - bakımda", true)

BannerBox:AddDropdown("BannerTier", {
	Values = BANNER_TIERS,
	Default = 1,
	Text = "Banner",
})

BannerBox:AddDropdown("BannerAmount", {
	Values = { "1", "10", "50", "100" },
	Default = 1,
	Text = "Amount",
})

BannerBox:AddDropdown("BannerCount", {
	Values = { "1", "2", "4", "8", "10" },
	Default = 1,
	Text = "Pulls",
})

BannerBox:AddButton({
	Text = "Summon",
	Func = function()
		notify("Banner", "Auto Banner bakımda (maintenance)", 3)
	end,
})

--// Automation tab
local RecordBox = Tabs.Automation:AddLeftGroupbox("Recording")

RecordBox:AddLabel("Capturing: place, upgrade, sell, target mode, move, path, ability", true)

-- wrap so the multi line recording status is actually visible
RecordLabel = RecordBox:AddLabel("Status: idle", true)

RecordBox:AddToggle("RecordUpgrades", {
	Default = true,
	Text = "Record Upgrades",
	Tooltip = "When off, tower upgrades are not captured.",
})

RecordBox:AddToggle("RecordSells", {
	Default = true,
	Text = "Record Sells",
	Tooltip = "When off, tower sells are not captured.",
})

RecordBox:AddToggle("RecordTarget", {
	Default = true,
	Text = "Record Target",
	Tooltip = "When off, target mode changes are not captured.",
})

RecordBox:AddToggle("RecordAbility", {
	Default = true,
	Text = "Record Ability",
	Tooltip = "When off, ability activations are not captured.",
})

-- cash-moving automations pollute the cash log, so a capture stops them
-- first (fish, dungeon claim, classic/dungeon join sequences spend or gain).
local function stopCashMovers()
	local stopped = {}
	local function off(toggleIdx, label)
		local t = Toggles[toggleIdx]
		if t and t.Value then
			pcall(function()
				t:SetValue(false)
			end)
			stopped[#stopped + 1] = label
		end
	end
	classicRun += 1
	dungeonRun += 1
	off("Autofish", "fish")
	off("DungeonAutoClaim", "claim")
	off("ClassicAutoStart", "classic")
	off("DungeonAutoStart", "dungeon")
	return stopped
end

local function beginCapture(mapName)
	if ReplayCtx then
		-- replay spends would land in this capture's cash log: refuse
		RecState = "idle"
		RECORD_MAP = nil
		updateRecordLabel()
		notify("Recording refused", "Stop the replay first", 4)
		return
	end
	RECORDS = {}
	RECORD_T0 = os.clock()
	RECORD_MAP = mapName or currentMapName()
	CashLog = {}
	PlaceQueue = {}
	PAUSE_AT = nil
	lastExtra = nil
	RecState = "recording"
	RECORDING = true
	attachCashWatcher()
	local stopped = stopCashMovers()
	updateRecordLabel()
	notify("Recording", "Capturing tower actions - Stop pauses, Finish ends", 4)
	if #stopped > 0 then
		notify("Automations stopped", table.concat(stopped, ", "), 4)
	end
end

local function startRecording()
	-- the one and only check: match already begun? MatchBegun existing means
	-- yes -> capture right away. Otherwise arm and wait for it; never report
	-- "stopped", the label says the match start is being awaited.
	if matchRunning() then
		beginCapture()
		return
	end
	RECORDS = {}
	RECORD_MAP = nil
	CashLog = {}
	PlaceQueue = {}
	PAUSE_AT = nil
	lastExtra = nil
	RecState = "armed"
	RECORDING = false
	updateRecordLabel()
	notify("Waiting", "Match has not started - capture begins at t=0", 4)
end

local function pauseRecording()
	if RecState ~= "recording" then
		return
	end
	PAUSE_AT = os.clock()
	RECORDING = false
	RecState = "paused"
	-- stop watching cash so idle cash changes do not pile into the log
	if CashConn then
		CashConn:Disconnect()
		CashConn = nil
	end
	updateRecordLabel()
	notify("Recording paused", #RECORDS .. " events held - Start continues, Finish ends", 4)
end

local function resumeRecording()
	if RecState ~= "paused" then
		return
	end
	-- slide the clock forward by the paused gap so paused time never lands
	-- in the recorded timeline
	RECORD_T0 = RECORD_T0 + (os.clock() - PAUSE_AT)
	PAUSE_AT = nil
	RECORDING = true
	RecState = "recording"
	attachCashWatcher()
	updateRecordLabel()
	notify("Recording resumed", "Capturing again", 3)
end

local function finishRecording(silent)
	if RecState == "armed" then
		-- arming cancelled before any match began: nothing was captured
		RecState = "idle"
		updateRecordLabel()
		if not silent then
			notify("Arming cancelled", "Press Record to arm again", 3)
		end
		return false
	end
	if RecState ~= "recording" and RecState ~= "paused" then
		if not silent then
			notify("Nothing to finish", "Press Record first", 3)
		end
		return false
	end
	if RecState == "recording" then
		PAUSE_AT = os.clock()
		RECORDING = false
		if CashConn then
			CashConn:Disconnect()
			CashConn = nil
		end
	end
	RecState = "finished"
	updateRecordLabel()
	if silent then
		return true
	end
	local counts = validateMacro(RECORDS)
	notify(
		"Recording finished",
		string.format(
			"%d events, %.1fs\n%s\nPress Save Macro to keep it",
			#RECORDS,
			recDuration(),
			summarizeCounts(counts)
		),
		6
	)
	return true
end

local function toggleRecording()
	if RecState == "recording" then
		pauseRecording()
	elseif RecState == "paused" then
		resumeRecording()
	elseif RecState == "armed" then
		-- disarm: back to idle, nothing captured
		RecState = "idle"
		updateRecordLabel()
		notify("Arming cancelled", "Press Record to arm again", 3)
	else
		startRecording()
	end
end

-- the button text follows the state (Record / Stop / Start); the label above
-- always shows the full step flow
RecordBtn = RecordBox:AddButton({
	Text = "Record",
	Func = toggleRecording,
})

RecordBox:AddButton({
	Text = "Finish",
	Func = function()
		finishRecording(false)
	end,
})

updateRecordLabel()

-- Toggle mode fires the callback on every press (same behavior as the
-- Linoria build; Obsidian also ships a Press mode - kept off for parity)
RecordBox:AddLabel("Hotkey"):AddKeyPicker("RecordKey", {
	Default = "F5",
	Mode = "Toggle",
	NoUI = true,
	Text = "Record / Stop / Start",
	Callback = toggleRecording,
})

RecordBox:AddDivider()
RecordBox:AddInput("MacroName", {
	Default = "",
	Text = "Macro Name",
	Placeholder = "my_macro",
	Finished = false,
})

RecordBox:AddButton({
	Text = "Save Macro",
	Func = function()
		-- the whole body is guarded: whatever breaks, the user SEES it
		-- instead of a dead-silent button
		local okAll, errAll = xpcall(function()
			-- Options.MacroName may be missing if the input failed to register;
			-- never let that crash the button silently (the SetValue write-back
			-- stays guarded so a failed registration is still best-effort)
			local raw = Options.MacroName and Options.MacroName.Value or nil
			local name = safeName(raw)
			if Options.MacroName and Options.MacroName.SetValue then
				pcall(function()
					Options.MacroName:SetValue(name)
				end)
			end
			if #RECORDS == 0 then
				notify("Error", "Nothing recorded yet", 3)
				return
			end
			local costed = computeCosts(RECORDS, CashLog)
			local pruned, dropped = pruneUnspent(costed, CashLog)
			local unwatched = #RECORDS > 0 and #CashLog == 0
			if #pruned == 0 then
				notify("Error", "Nothing to save - no step actually spent cash", 4)
				return
			end
			local mapName = RECORD_MAP or currentMapName()
			local ok, err = saveMacro(name, pruned, Options.Tolerance.Value, CashLog, mapName)
			if not ok then
				notify("Save failed", tostring(err), 5)
				return
			end
			local counts = validateMacro(pruned)
			local desc = name .. "\n" .. #pruned .. " events\n" .. summarizeCounts(counts)
			if mapName then
				desc ..= "\nMap: " .. tostring(mapName)
			else
				desc ..= "\nMap: unknown - Auto Name Replay cannot match this"
			end
			if dropped > 0 then
				desc ..= "\n" .. dropped .. " dead step(s) removed (no spend)"
			end
			if unwatched then
				desc ..= "\nNo cash watch - costs unverified"
			end
			notify("Saved", desc, 6)
			-- refresh AFTER the success is already reported, so a hiccup
			-- here can never swallow the confirmation
			pcall(function()
				refreshMacroList()
				if Options.MacroSelect then
					Options.MacroSelect:SetValue(name)
				end
			end)
		end, function(e)
			return tostring(e)
		end)
		if not okAll then
			notify("Save crashed", tostring(errAll), 8)
		end
	end,
})

-- the game's own "Replay" button on the round-over screen fires
-- PlayerVoteReplay to vote for the same map again; mirror that on match end
local RematchBox = Tabs.Automation:AddLeftGroupbox("Rematch")

RematchBox:AddToggle("AutoRematch", {
	Default = false,
	Text = "Auto Rematch",
	Tooltip = "Votes to replay the same map every 1 second while on.",
	Callback = function(Value)
		if Value then
			rematchRun += 1
			local id = rematchRun
			task.spawn(function()
				local warned = false
				while id == rematchRun and Toggles.AutoRematch.Value and STATE.alive() and myGenAlive() do
					local vote = classicRemote("PlayerVoteReplay")
					if vote then
						warned = false
						pcall(function()
							vote:FireServer()
						end)
					elseif not warned then
						warned = true
						warn("[UTD] PlayerVoteReplay not found")
					end
					task.wait(1)
				end
			end)
		else
			rematchRun += 1 -- abort the loop
		end
	end,
})

--// Anti AFK: Infinite Yield's antiidle (VirtualInputManager click on Idled)
local AntiAfkConn = nil

local function setAntiAfk(on)
	if on then
		if AntiAfkConn then
			return
		end
		AntiAfkConn = LocalPlayer.Idled:Connect(function()
			if not myGenAlive() then
				return
			end
			local okV, vim = pcall(Instance.new, "VirtualInputManager")
			if okV and vim then
				pcall(function()
					vim:SendMouseButtonEvent(0, 0, 0, true, game, 0)
					vim:SendMouseButtonEvent(0, 0, 0, false, game, 0)
				end)
				vim:Destroy()
			else
				-- fallback for executors where VirtualInputManager is blocked
				local okU, vu = pcall(function()
					return game:GetService("VirtualUser")
				end)
				if okU and vu then
					pcall(function()
						vu:CaptureController()
						vu:ClickButton2(Vector2.new(0, 0))
					end)
				end
			end
		end)
	elseif AntiAfkConn then
		AntiAfkConn:Disconnect()
		AntiAfkConn = nil
	end
end

--// Misc tab: quality-of-life toggles that belong to no single farm
local MiscBox = Tabs.Misc:AddLeftGroupbox("General")

MiscBox:AddToggle("AntiAfk", {
	Default = true,
	Text = "Anti AFK",
	Tooltip = "Infinite Yield antiidle: clicks on the Idled event so Roblox does not kick you. Off = normal AFK behavior.",
	Callback = function(Value)
		setAntiAfk(Value)
	end,
})

local MiscInfoBox = Tabs.Misc:AddRightGroupbox("Info")
local MiscPlayerLabel = MiscInfoBox:AddLabel("Player: ...", true)
local MiscWhereLabel = MiscInfoBox:AddLabel("Where: ...", true)
local MiscJobLabel = MiscInfoBox:AddLabel("JobId: ...", true)
-- refreshed on a timer; every read is pcall-wrapped so a hiccup cannot
-- kill the loop (serverInfo() lives further down, so it is not used here)
task.spawn(function()
	while STATE.alive() do
		pcall(function()
			MiscPlayerLabel:SetText("Player: " .. LocalPlayer.Name)
		end)
		pcall(function()
			local rs = game:GetService("ReplicatedStorage")
			local gm = rs:FindFirstChild("GenericModules")
			local ob = gm and gm:FindFirstChild("Object")
			local mod = ob and ob:FindFirstChild("NetworkProxy")
			local where = "?"
			if mod and mod:IsA("ModuleScript") then
				local np = require(mod)
				local root = np and np.root
				if root then
					where = tostring(root.serverType or "?")
					local md = root.matchData
					if md and md.mapId then
						where ..= " | " .. tostring(md.mapId)
					end
				end
			end
			MiscWhereLabel:SetText("Where: " .. where)
		end)
		pcall(function()
			MiscJobLabel:SetText("JobId: " .. tostring(game.JobId))
		end)
		task.wait(5)
	end
end)

-- apply the default now; restoreUI overrides it with the saved value
setAntiAfk(Toggles.AntiAfk.Value)

-- rewards accumulated across every finished match this session. The webhook
-- reports the TOTALS, not just the last match. Fed by the GlobalInit/Gameover
-- channel, which carries the full reward table (watchRemote keeps that hook
-- alive across the lobby/match remote swaps).
-- The numbers live in getgenv on purpose: the script is re-run by
-- queue_on_teleport after every teleport (and by live-reload), and plain
-- locals would zero the report on each of those - the webhook would only ever
-- show the matches since the last reload.
-- one shared table = the getgenv() store itself (same reference), so mutating
-- it persists across reload/teleport with no explicit copy-back. Kept as a
-- single local to stay under Luau's 200-register top-level limit.
local Totals = getgenv().__UTD_TOTALS
if type(Totals) ~= "table" then
	Totals = { gold = 0, exp = 0, matches = 0, extra = {} }
	getgenv().__UTD_TOTALS = Totals
end
if type(Totals.extra) ~= "table" then
	Totals.extra = {}
end
-- reward names as they should read on Discord
local EXTRA_NAME = {
	DungeonToken = "Rubies",
}
local function extraLabel(key)
	return EXTRA_NAME[key] or tostring(key)
end
local webhookRun = 0

-- where the player is right now (Lobby / Match + map + wave)
local function currentWaveNum()
	local gui = LocalPlayer.PlayerGui:FindFirstChild("MainGui")
	local frames = gui and gui:FindFirstChild("MainFrames")
	local wv = frames and frames:FindFirstChild("Wave")
	local idx = wv and wv:FindFirstChild("WaveIndex")
	if idx and idx:IsA("TextLabel") then
		return tonumber(tostring(idx.Text):match("Wave%s*(%d+)"))
	end
	return nil
end

local function serverInfo()
	local info = { where = "Unknown", map = "-", wave = "-" }
	pcall(function()
		local rs = game:GetService("ReplicatedStorage")
		local gm = rs:FindFirstChild("GenericModules")
		local ob = gm and gm:FindFirstChild("Object")
		local mod = ob and ob:FindFirstChild("NetworkProxy")
		if mod and mod:IsA("ModuleScript") then
			local np = require(mod)
			local root = np and np.root
			if root then
				info.where = tostring(root.serverType or "Unknown")
				local md = root.matchData
				if md then
					if md.gamemode then
						info.where ..= " (" .. tostring(md.gamemode) .. ")"
					end
					if md.mapId then
						info.map = tostring(md.mapId)
					end
				end
			end
		end
	end)
	local w = currentWaveNum()
	if w then
		info.wave = tostring(w)
	end
	return info
end

local function sendEarnings(test)
	local url = Options.WebhookURL and Options.WebhookURL.Value or ""
	if url == "" then
		notify("Webhook", "Paste a webhook URL first", 4)
		return false
	end
	local info = serverInfo()
	local who = LocalPlayer.Name
	pcall(function()
		if LocalPlayer.DisplayName and LocalPlayer.DisplayName ~= "" then
			who ..= " (@" .. LocalPlayer.DisplayName .. ")"
		end
	end)
	local botName = Options.BotName and Options.BotName.Value or ""
	if botName == "" then
		botName = "UTD Bot"
	end
	-- compact top row (side by side), then a single stacked rewards block at
	-- the bottom: a code block keeps the arrows aligned and reads cleanly
	local fields = {
		{ name = "Player", value = who, inline = true },
		{ name = "Status", value = info.where .. " | " .. info.map .. " | Wave " .. info.wave, inline = true },
		{ name = "Matches", value = tostring(Totals.matches), inline = true },
	}
	local lines
	if Totals.matches == 0 then
		lines = { "no match finished yet" }
	else
		-- Gold / Rubies / Exp lead; every other extra reward sits below a blank
		-- line so the main currencies stay easy to read
		local top = {
			{ "Gold", formatCash(Totals.gold) },
		}
		if Totals.extra.DungeonToken then
			top[#top + 1] = { extraLabel("DungeonToken"), tostring(Totals.extra.DungeonToken) }
		end
		top[#top + 1] = { "Exp", tostring(Totals.exp) }
		-- every other extra reward, alphabetically
		local rest = {}
		local keys = {}
		for k in pairs(Totals.extra) do
			if k ~= "DungeonToken" then
				keys[#keys + 1] = k
			end
		end
		table.sort(keys, function(a, b)
			return extraLabel(a) < extraLabel(b)
		end)
		for _, k in ipairs(keys) do
			rest[#rest + 1] = { extraLabel(k), tostring(Totals.extra[k]) }
		end
		-- one shared pad so the arrows line up across BOTH groups
		local pad = 0
		for _, r in ipairs(top) do
			pad = math.max(pad, #r[1])
		end
		for _, r in ipairs(rest) do
			pad = math.max(pad, #r[1])
		end
		local function line(r)
			return r[1] .. string.rep(" ", pad - #r[1]) .. " -> " .. r[2]
		end
		lines = {}
		for _, r in ipairs(top) do
			lines[#lines + 1] = line(r)
		end
		if #rest > 0 then
			lines[#lines + 1] = "" -- spacer between the two groups
			for _, r in ipairs(rest) do
				lines[#lines + 1] = line(r)
			end
		end
	end
	table.insert(fields, {
		name = "Totals",
		value = "```" .. table.concat(lines, "\n") .. "```",
		inline = false,
	})
	local payload = {
		username = botName,
		embeds = { {
			title = "Rewards" .. (test and " (Test)" or ""),
			color = 3066993,
			fields = fields,
			timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		} },
	}
	local ok, res = pcall(function()
		return request({
			Url = url,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode(payload),
		})
	end)
	if not ok then
		notify("Webhook failed", tostring(res):sub(1, 80), 5)
	end
	return ok
end

local WebhookBox = Tabs.Automation:AddLeftGroupbox("Discord")

WebhookBox:AddToggle("DiscordWebhook", {
	Default = false,
	Text = "Send Discord Webhook",
	Tooltip = "Reports earnings (matches x 18,750) on an interval.",
	Callback = function(Value)
		if Value then
			webhookRun += 1
			local id = webhookRun
			task.spawn(function()
				local first = true
				while id == webhookRun and Toggles.DiscordWebhook.Value and STATE.alive() and myGenAlive() do
					if not first then
						local interval = tonumber(Options.WebhookInterval.Value) or 300
						if interval < 10 then
							interval = 10
						end
						task.wait(interval)
					end
					first = false
					if id ~= webhookRun or not Toggles.DiscordWebhook.Value then
						break
					end
					sendEarnings(false)
				end
			end)
		else
			webhookRun += 1 -- abort the loop
		end
	end,
})

WebhookBox:AddInput("WebhookURL", {
	Default = "",
	Text = "Webhook URL",
	Placeholder = "https://discord.com/api/webhooks/...",
	Finished = false,
})

WebhookBox:AddInput("BotName", {
	Default = "UTD Bot",
	Text = "Bot Name",
	Placeholder = "UTD Bot",
	Finished = false,
})

WebhookBox:AddSlider("WebhookInterval", {
	Text = "Report Every",
	Default = 300,
	Min = 10,
	Max = 3600,
	Rounding = 0,
	Suffix = "s",
	Tooltip = "Seconds between earnings reports.",
})

WebhookBox:AddButton({
	Text = "Test Webhook",
	Func = function()
		task.spawn(function()
			sendEarnings(true)
		end)
	end,
})

--// RE EXECUTE: teleport sonrasi scripti executorun queue_on_teleport'u ile
-- yeniden calistirir. Hedef dosyada tutulur; URL degisince yeniden queue
-- cagirmak gerekmez. (Synapse, Wave, Delta, Arceus, Xeno, ...)
local ReExec = {
	file = "FallyoUTD/reexec.txt",
	queued = false,
	restoring = false,
}

-- queued loader runs in the NEW game session, so it reads the target fresh
ReExec.loader = [==[
do
	local okF, target = pcall(readfile, "FallyoUTD/reexec.txt")
	if okF and type(target) == "string" then
		target = target:gsub("^%s+", ""):gsub("%s+$", "")
		if target ~= "" then
			local key = tostring(game.PlaceId) .. ":" .. tostring(game.JobId)
			local g = (getgenv and getgenv()) or _G
			if g.__UTD_REEXEC_KEY ~= key then
				g.__UTD_REEXEC_KEY = key
				pcall(function()
					if target:lower():match("^https?://") then
						loadstring(game:HttpGet(target))()
					else
						loadstring(readfile(target))()
					end
				end)
			end
		end
	end
end
]==]

function ReExec.trim(value)
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function ReExec.writeTarget(value)
	local target = ReExec.trim(value)
	if target == "" then
		return false
	end
	return (pcall(writefile, ReExec.file, target))
end

function ReExec.clearTarget()
	pcall(writefile, ReExec.file, "")
end

function ReExec.hasTarget()
	local ok, content = pcall(readfile, ReExec.file)
	return ok and type(content) == "string" and content:match("%S") ~= nil
end

-- best effort for "execute file" users: the chunk source is often the path
-- the executor opened. Vanilla loadstring chunks resolve to (loadstring),
-- which fails isfile and is ignored.
function ReExec.detectSource()
	local okS, src = pcall(function()
		return debug.info(1, "s")
	end)
	if not okS or type(src) ~= "string" then
		return nil
	end
	src = src:gsub("^[@=]", "")
	if src == "" or src:match("^%[") or src:match("^%(") then
		return nil
	end
	local okF, isFile = pcall(isfile, src)
	if okF and isFile then
		return src
	end
	return nil
end

function ReExec.findQueue()
	local list, seen = {}, {}
	local function add(fn)
		if type(fn) == "function" and not seen[fn] then
			seen[fn] = true
			list[#list + 1] = fn
		end
	end
	local function scan(env)
		if type(env) ~= "table" then
			return
		end
		add(rawget(env, "queue_on_teleport"))
		add(rawget(env, "queueonteleport"))
		for _, ns in ipairs({ "syn", "http", "fluxus", "krnl", "wearedevs", "arceus", "xeno", "delta" }) do
			local t = rawget(env, ns)
			if type(t) == "table" then
				add(rawget(t, "queue_on_teleport"))
				add(rawget(t, "queueonteleport"))
			end
		end
	end
	scan(_G)
	local okF, env = pcall(getfenv)
	if okF then
		scan(env)
	end
	local okG, genv = pcall(getgenv)
	if okG then
		scan(genv)
	end
	return list
end

function ReExec.queue(silent)
	if ReExec.queued then
		return true
	end
	for _, fn in ipairs(ReExec.findQueue()) do
		if pcall(fn, ReExec.loader) then
			ReExec.queued = true
			if not silent then
				notify("Reexecute", "Queued - runs again after teleport", 4)
			end
			return true
		end
	end
	if not silent then
		notify("Reexecute", "This executor has no queue_on_teleport", 6)
	end
	return false
end

function ReExec.apply(silent)
	if not (Toggles.Reexecute and Toggles.Reexecute.Value) then
		return false
	end
	local target = Options.ReExecTarget and Options.ReExecTarget.Value or ""
	target = ReExec.trim(target)
	if target == "" then
		target = ReExec.detectSource() or ""
	end
	if target ~= "" then
		ReExec.writeTarget(target)
	end
	if not ReExec.hasTarget() then
		if not silent then
			notify("Reexecute", "Fill Script URL / File first", 5)
		end
		return false
	end
	return ReExec.queue(silent)
end

local ReExecBox = Tabs.Automation:AddRightGroupbox("RE EXECUTE")

do
	local title = ReExecBox:AddLabel("RE EXECUTE")
	title.TextLabel.TextSize = 22
	title.TextLabel.Size = UDim2.new(1, -4, 0, 30)
	-- Obsidian renkleri Library.Scheme altinda tutar (Linoria'daki gibi
	-- ayri bir Library.AccentColor yok); registry string'i de onu cozer
	title.TextLabel.TextColor3 = Library.Scheme.AccentColor
	Library:RemoveFromRegistry(title.TextLabel)
	Library:AddToRegistry(title.TextLabel, { TextColor3 = "AccentColor" })
	ReExecBox:Resize()
end

ReExecBox:AddLabel("Teleport sonrasi bu scripti yeniden calistirir (executor queue_on_teleport).", true)

ReExecBox:AddInput("ReExecTarget", {
	Text = "Script URL / File",
	Default = "https://raw.githubusercontent.com/fayysterlyy/utd-macro-v2/main/utdV2.luau",
	Placeholder = "https://... veya script yolu",
	Finished = false,
	Tooltip = "Raw script URL (http/https) or a file path in the executor workspace. The queued loader reads this at teleport time, so edits apply without another queue.",
	Callback = function(Value)
		local target = ReExec.trim(Value)
		if target == "" then
			ReExec.clearTarget()
		else
			ReExec.writeTarget(target)
			if not ReExec.restoring and Toggles.Reexecute and Toggles.Reexecute.Value then
				ReExec.apply(true)
			end
		end
	end,
})

ReExecBox:AddToggle("Reexecute", {
	Text = "Reexecute",
	Default = false,
	Tooltip = "Queues this script with the executor's queue_on_teleport so it runs again after a teleport. Fill Script URL / File first. Needs an executor with queue_on_teleport (Synapse, Wave, Delta, Arceus, Xeno, ...).",
	Callback = function(Value)
		if ReExec.restoring then
			return
		end
		if Value then
			ReExec.apply(false)
		else
			ReExec.clearTarget()
			ReExec.queued = false
		end
	end,
})

local MacroBox = Tabs.Automation:AddRightGroupbox("Replay")

do
	local initial = refreshMacroList()
	if #initial == 0 then
		initial = { "-" }
	end
	MacroBox:AddDropdown("MacroSelect", {
		Values = initial,
		Default = 1,
		Text = "Macro",
	})
end

MacroBox:AddSlider("Tolerance", {
	Text = "Slowdown",
	Default = 1.05,
	Min = 1,
	Max = 5,
	Rounding = 2,
	Suffix = "x",
	Tooltip = "1.00x = exactly the recorded speed. 1.05x = 95% speed. Higher values wait longer so the server keeps up and you don't run out of cash.",
})

MacroBox:AddSlider("CashWait", {
	Text = "Max Cash Wait",
	Default = 15,
	Min = 0,
	Max = 120,
	Rounding = 0,
	Suffix = "s",
	Tooltip = "When a step needs money you don't have yet, hold for this long for cash to arrive. 0 = wait forever.",
})

MacroBox:AddToggle("CashWaitOn", {
	Text = "Wait for Cash",
	Default = true,
	Tooltip = "ON: if a step costs more than you have, hold up to Max Cash Wait for cash. OFF: never wait - fire every step immediately (a bad recorded cost won't false-skip a tower).",
})

MacroBox:AddToggle("AutoReplay", {
	Text = "Auto Replay (on match start)",
	Default = false,
	Tooltip = "Waits until MatchBegun fires, then plays the selected macro.",
})

MacroBox:AddToggle("AutoMapReplay", {
	Text = "Auto Name Replay",
	Default = false,
	Tooltip = "On match start, scans ALL saved macros and plays the newest one saved for this map. Ignores the Macro dropdown. Falls back to Auto Replay (selected macro) when no map match exists.",
})

MacroBox:AddToggle("LoopReplay", {
	Text = "Loop Replay",
	Default = false,
	Tooltip = "Restarts the macro when it finishes.",
})

MacroBox:AddToggle("StopOnGameover", {
	Text = "Stop When Match Ends",
	Default = true,
	Tooltip = "Stops the replay if the match HUD disappears (game over / left match).",
})

ReplayStatusLabel = MacroBox:AddLabel("Replay: idle", true)

ReplayStepLabel = MacroBox:AddLabel("", true)

MacroBox:AddButton({
	Text = "Validate Macro",
	Func = function()
		local sel = Options.MacroSelect.Value
		if not sel then
			notify("Validate", "Select a macro first", 3)
			return
		end
		local data = loadMacro(sel)
		if not data or not data.events then
			notify("Validate", "Could not load " .. sel, 4)
			return
		end
		local counts, missing = validateMacro(data.events)
		local missingList = {}
		for name in pairs(missing) do
			missingList[#missingList + 1] = name
		end
		table.sort(missingList)
		if #missingList > 0 then
			notify("Missing remotes", #missingList .. " not loaded: " .. table.concat(missingList, ", "), 6)
		else
			notify("Macro OK", #data.events .. " events, " .. summarizeCounts(counts), 6)
		end
	end,
})

MacroBox:AddButton({
	Text = "Pause / Resume",
	Func = function()
		togglePause()
	end,
})

MacroBox:AddButton({
	Text = "Replay",
	Func = function()
		if ReplayCtx then
			return
		end
		local sel = Options.MacroSelect.Value
		if not sel then
			notify("Error", "Select a macro first", 3)
			return
		end
		local data, err = loadMacro(sel)
		if not data or not data.events then
			notify("Error", tostring(err), 4)
			return
		end
		if #data.events == 0 then
			notify("Error", "Macro has no valid events", 4)
			return
		end
		local counts, missing = validateMacro(data.events)
		local missingCount = 0
		for _ in pairs(missing) do
			missingCount += 1
		end
		local tol = Options.Tolerance.Value
		if startReplay(data.events, tol, data.placeByEntity) then
			local desc = sel .. " @ " .. tol .. "x"
			if missingCount > 0 then
				desc ..= "\n" .. missingCount .. " remote type(s) not loaded, will skip"
			end
			desc ..= "\n" .. summarizeCounts(counts)
			notify("Replaying", desc, 5)
		end
	end,
})
MacroBox:AddButton({
	Text = "Stop Replay",
	Func = function()
		stopReplay("stopped by user")
	end,
})

MacroBox:AddDivider()
MacroBox:AddButton({
	Text = "Delete Macro",
	Func = function()
		local sel = Options.MacroSelect.Value
		if not sel or sel == "-" then
			notify("Delete", "Select a macro first", 3)
			return
		end
		local okDel = pcall(function()
			delfile(MACRO_DIR .. "/" .. sel .. ".json")
		end)
		if not okDel then
			notify("Delete failed", sel, 4)
			return
		end
		refreshMacroList()
		local rest = listMacros()
		if Options.MacroSelect then
			pcall(function()
				Options.MacroSelect:SetValue(#rest > 0 and rest[1] or "-")
			end)
		end
		notify("Deleted", sel, 3)
	end,
})

MacroBox:AddInput("ImportPath", {
	Default = "",
	Text = "Import (path or URL)",
	Placeholder = "name.json or https://...",
	Finished = false,
})

MacroBox:AddButton({
	Text = "Import Macro",
	Func = function()
		local src = Options.ImportPath.Value
		if not src or src == "" then
			return
		end
		local content
		if src:match("^https?://") then
			local ok, res = pcall(game.HttpGet, game, src)
			if not ok then
				notify("Import failed", tostring(res), 4)
				return
			end
			content = res
		else
			local ok, res = pcall(readfile, src)
			if not ok then
				notify("Import failed", tostring(res), 4)
				return
			end
			content = res
		end
		local okD, data = pcall(HttpService.JSONDecode, HttpService, content)
		if not okD or not data or not data.events then
			notify("Import failed", "Not a valid macro file", 4)
			return
		end
		local base = safeName(src:match("([^/\\]+)%.json$") or "")
		local evs = computeCosts(normalizeEvents(data.events), data.cashLog)
		evs = pruneUnspent(evs, data.cashLog)
		local okS, errS = saveMacro(base, evs, data.tolerance or 1.05, data.cashLog, data.map)
		if not okS then
			notify("Import failed", tostring(errS), 4)
			return
		end
		refreshMacroList()
		if Options.MacroSelect then
			Options.MacroSelect:SetValue(base)
		end
		notify("Imported", base, 3)
	end,
})

MacroBox:AddButton({
	Text = "Export Macro",
	Func = function()
		local sel = Options.MacroSelect.Value
		if not sel then
			return
		end
		local ok, content = pcall(readfile, MACRO_DIR .. "/" .. sel .. ".json")
		if not ok then
			notify("Export failed", tostring(content), 4)
			return
		end
		local okW, errW = pcall(writefile, EXPORT_DIR .. "/" .. sel .. ".json", content)
		if not okW then
			notify("Export failed", tostring(errW), 4)
			return
		end
		notify("Exported", EXPORT_DIR .. "/" .. sel .. ".json", 5)
	end,
})

--// Tower id tracking: the server answers every placed tower with its fresh
-- entity id on TowerPlacedSuccessfully(a1=entityId, a2="asset:tower" - the
-- exact type string from the place args, verified live).
-- Recording side stamps the place step; replay side builds old-step ->
-- new-id so upgrade-like steps get rewritten.
local tpsMissStreak = 0
local function takePlace(queue, typ)
	if #queue == 0 then
		return nil
	end
	if typ then
		for i, rec in ipairs(queue) do
			local a = rec.args
			local t = a and tostring(a["1"] ~= nil and a["1"] or a[1])
			if t == typ then
				tpsMissStreak = 0
				return table.remove(queue, i)
			end
		end
	end
	return nil
end
--// Dynamic remote watcher. TowerPlacedSuccessfully and the GlobalInit remotes
-- are created and destroyed by the game as it moves between lobby and match, so
-- a one-shot attach either misses the first event (the old 1s poll lost the very
-- first placement's id reply, leaving that tower without entityId - and an
-- ability/upgrade step on it could never be remapped) or dies silently later and
-- the rewards totals stop accumulating. This keeps a live hook instead:
--   * ChildAdded catches a fresh remote the moment it exists - no poll race for
--     the first event of a match,
--   * a slow poll is the fallback for loading between states (folder missing),
--   * a weak "already hooked" set turns a re-parent of the SAME instance into a
--     no-op instead of a second connection firing the handler twice,
--   * every instance is hooked at most once, so totals can never double-count.
local function watchRemote(getFolder, remoteName, handler, onHook)
	local hooked = setmetatable({}, { __mode = "k" })
	local connFolder
	local function hook(remote)
		if not remote or hooked[remote] then
			return
		end
		hooked[remote] = true
		if onHook then
			pcall(onHook, remote)
		end
		STATE.connect(remote.OnClientEvent, handler)
	end
	while STATE.alive() and myGenAlive() do
		local folder = getFolder()
		if folder then
			if folder ~= connFolder then
				connFolder = folder
				STATE.connect(folder.ChildAdded, function(child)
					if child.Name == remoteName then
						hook(child)
					end
				end)
			end
			hook(folder:FindFirstChild(remoteName))
			task.wait(1)
		else
			task.wait(0.1)
		end
	end
end

task.spawn(function()
	local function onTps(a1, a2)
		if not myGenAlive() then
			return
		end
		local eid = a1 ~= nil and tostring(a1) or nil
		if not eid then
			return
		end
		local typ = a2 ~= nil and tostring(a2) or nil
		local function fallbackShift(queue)
			if #queue == 0 then
				return nil
			end
			tpsMissStreak += 1
			if tpsMissStreak >= 3 then
				tpsMissStreak = 0
				warn("[UTD] tower id/type mismatch 3x - order fallback")
				return table.remove(queue, 1)
			end
			return nil
		end
		if RECORDING and #PlaceQueue > 0 then
			local rec = takePlace(PlaceQueue, typ) or fallbackShift(PlaceQueue)
			if rec then
				rec.entityId = eid
				if a2 ~= nil then
					rec.entityId2 = tostring(a2)
				end
			end
		end
		local ctx = ReplayCtx
		if ctx and ctx.placeQueue and #ctx.placeQueue > 0 then
			local rec = takePlace(ctx.placeQueue, typ) or fallbackShift(ctx.placeQueue)
			if rec then
				ctx.newIdByRec[rec] = eid
			end
		end
	end
	watchRemote(function()
	local m = game:GetService("ReplicatedStorage"):FindFirstChild("Modules")
	local g = m and m:FindFirstChild("GlobalInit")
	return g and g:FindFirstChild("RemoteEvents")
end, "TowerPlacedSuccessfully", onTps, function()
		tpsMissStreak = 0 -- a fresh instance is a fresh match context
	end)
end)

--// Auto replay trigger: server fires MatchBegun(mapName) when the match starts
-- recording ticker: repaint from OUR thread twice a second while capturing
-- or replaying, so the labels visibly tick even though game-thread paints
-- are refused (see updateRecordLabel note)
task.spawn(function()
	while STATE.alive() and myGenAlive() do
		task.wait(0.5)
		if RecState == "recording" then
			updateRecordLabel(lastExtra)
		end
		if ReplayCtx then
			updateReplayStatus()
		end
	end
end)
--// Auto Dungeon tab: match-flow automation (back-from-11, auto next),
-- Forsaken Prison auto-place, and best-challenge voting. The flow callbacks
-- at the bottom of this block are invoked from onMatchStart/onMatchEnd, which
-- are declared much further down.
local DungeonFlowBox = Tabs["Auto Dungeon"]:AddLeftGroupbox("Dungeon Flow")
local DungeonChallengeBox = Tabs["Auto Dungeon"]:AddLeftGroupbox("Challenge")

-- run counters: bumping one aborts every thread still holding the old value
local autoNextRun = 0
local challengeRun = 0
-- last time ANY challenge vote went out; the screen fallback uses this to
-- stand down while the primary (authoritative, correct) remote path is live,
-- so a scrambled screen title->id guess can never override a good pick.
local lastChallengeVoteAt = 0

-- Auto Back from 10: armed only for a "Forsaken Prison - Floor 10" match
local backFrom10Armed = false
local backFrom10Fired = false

-- last named MatchBegun, so a duplicate begun cannot restart a live sequence
local dungeonLastNamedStart = 0

-- called from onMatchStart / onMatchEnd; assigned at the bottom of this block
local dungeonOnMatchStart
local dungeonOnMatchEnd

local DungeonChallengeLabel = DungeonChallengeBox:AddLabel("Challenge: idle", true)

local function setChallengeLabel(text)
	if DungeonChallengeLabel then
		pcall(function()
			DungeonChallengeLabel:SetText("Challenge: " .. text)
		end)
	end
end

-- fire a GlobalInit RemoteEvents remote by name. Resolved fresh on every shot
-- (the instances rotate with the match server) and always pcall-wrapped.
local function fireGlobalEvent(name, arg)
	local re = resolvePath("ReplicatedStorage.Modules.GlobalInit.RemoteEvents")
	local remote = re and re:FindFirstChild(name)
	if not remote then
		return false
	end
	local ok
	if arg ~= nil then
		ok = pcall(function()
			remote:FireServer(arg)
		end)
	else
		ok = pcall(function()
			remote:FireServer()
		end)
	end
	return ok
end


--// Challenge priority: top = best. The offered trio is scored 1..26 and the
-- lowest score wins. (Ported from the removed Auto Dungeon block.)
local CHALLENGE_RANK = {
	BleedingImmunity = 1,
	BurningImmunity = 2,
	PoisonImmunity = 3,
	TimestopImmunity = 4,
	SlowImmunity = 5,
	DoubleBosses = 6,
	Healer = 7,
	NoRefunds = 8,
	Tank = 9,
	EnemyHealth = 10,
	EnemySpeed = 11,
	EnemySpawnCount = 12,
	TowerDamage = 13,
	TowerDegrading = 14,
	TowerRange = 15,
	Explosive = 16,
	NoSelling = 17,
	ShieldHealth = 18,
	Shielded = 19,
	UselessArtifacts = 20,
	UselessFarms = 21,
	SinglePlacement = 22,
	UselessTraits = 23,
	ElementalShield = 24,
	Stealth = 25,
	DoubleTowerCosts = 26,
}

local dungLastScreenSig = nil
local dungLastUnknownSig = nil
local dungLastUnreadable = nil

-- Challenge vote sender: fires the pick ONCE, then waits for the server's
-- "Challenge Selected" confirmation (the ServerSendMessage listener below bumps
-- challengeRun when it lands) and only re-fires if nothing came back. Max 2
-- shots - no blind x4 spam; repeat votes for the same slot were harmless but
-- just noise.
local function fireChallengeVote(pick, tag)
	local myRun = challengeRun
	lastChallengeVoteAt = os.clock()
	task.spawn(function()
		for i = 1, 2 do
			if myRun ~= challengeRun then
				break -- server confirmed the pick (listener bumped challengeRun)
			end
			if not (Toggles.AutoBestChallenge and Toggles.AutoBestChallenge.Value) then
				break
			end
			if not (STATE.alive() and myGenAlive()) then
				break
			end
			if i > 1 then
				task.wait(1.5)
			end
			if myRun ~= challengeRun then
				break -- confirmed while waiting: skip the retry
			end
			if not (Toggles.AutoBestChallenge and Toggles.AutoBestChallenge.Value) then
				break
			end
			if not fireGlobalEvent("PlayerVoteForChallenge", pick) then
				warn("[UTD] PlayerVoteForChallenge not found")
				break
			end
			print("[UTD] challenge vote shot " .. i .. " sent: " .. tostring(pick) .. " (" .. tostring(tag) .. ")")
		end
	end)
end

-- Challenge screen fallback: if the vote remote is ever missed, read the open
-- "Select a Challenge" cards and vote the best. Title->id pairs are LEARNED
-- whenever remote + screen coincide (exact, no guessing); unknown titles are
-- reported, never guessed.
local function readChallengeTitles()
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	local mg = pg and pg:FindFirstChild("MainGui")
	local cc = mg and mg:FindFirstChild("ChallengeCardSelection")
	if not cc or not cc.Visible then
		return nil
	end
	local function cardsOf(listName)
		local list = cc:FindFirstChild(listName)
		if not list then
			return nil
		end
		local out = {}
		for i = 1, 3 do
			local card = list:FindFirstChild(tostring(i))
			if not card or not card.Visible then
				return nil
			end
			-- the real card title (game code writes it to Foreground.PathName)
			local title = nil
			local pn = card:FindFirstChild("PathName", true)
			if pn and (pn:IsA("TextLabel") or pn:IsA("TextButton")) then
				local t = tostring(pn.Text or "")
				if t ~= "" then
					title = t
				end
			end
			if not title then
				-- fallback: first sensible label (skip counters/rewards)
				for _, d in ipairs(card:GetDescendants()) do
					if d:IsA("TextLabel") then
						local t = tostring(d.Text or "")
						if t ~= "" and t ~= "Rubies" and not t:match("^x%d+$")
							and not t:match("^[%+%-]%d+$")
							and not t:find("Time Remaining", 1, true) and #t < 40 then
							title = t
							break
						end
					end
				end
			end
			if not title then
				return nil
			end
			out[#out + 1] = title
		end
		return out
	end
	return cardsOf("NormalChallengeList") or cardsOf("HardcoreChallengeList") or false
	-- false = the screen is open but the card layout is not understood
	-- (nil = the screen is simply closed)
end

-- fuzzy title -> id for unlearned cards: stem both sides the same way and
-- count shared tokens. Returns the id only on a STRICTLY unique best, else
-- nil (a wrong vote is worse than no vote).
local function stemWord(w)
	w = w:lower()
	w = w:gsub("ing$", "")
	if #w > 4 and not w:match("ss$") then
		w = w:gsub("s$", "")
	end
	return w
end

local function fuzzyChallengeId(title)
	local titleToks = {}
	for w in tostring(title):gmatch("%w+") do
		titleToks[#titleToks + 1] = stemWord(w)
	end
	local best, bestScore, bestCount = nil, 0, 0
	for id in pairs(CHALLENGE_RANK) do
		local score = 0
		for iw in tostring(id):gmatch("%u%l*") do
			local sw = stemWord(iw)
			for _, tw in ipairs(titleToks) do
				if sw == tw then
					score += 1
					break
				end
			end
		end
		if score > bestScore then
			best, bestScore, bestCount = id, score, 1
		elseif score == bestScore and score > 0 then
			bestCount += 1
		end
	end
	if best and bestCount == 1 then
		return best
	end
	return nil
end

-- resolve a card title to its internal id: exact table first, fuzzy fallback.
-- Everything else lives inside this do-block so only resolveChallengeId counts
-- as a top-level local (register budget is tight at ~200).
local resolveChallengeId
do
	-- normalize (lowercase, strip non-alphanumerics) so spacing/case never
	-- matters when matching a card title to its id
	local function normTitle(t)
		return (tostring(t):lower():gsub("[^%w]", ""))
	end
	-- "normalizedTitle=InternalId" pairs in ONE string, parsed once at load.
	local RAW = "bleedingimmunity=BleedingImmunity,bleedimmunity=BleedingImmunity,burnimmunity=BurningImmunity,burningimmunity=BurningImmunity,poisonimmunity=PoisonImmunity,timestopimmunity=TimestopImmunity,slowimmunity=SlowImmunity,doublebossespawns=DoubleBosses,doublebossespawn=DoubleBosses,doublebosses=DoubleBosses,healingenemies=Healer,healer=Healer,norefunds=NoRefunds,tankenemies=Tank,tank=Tank,enemyhealth=EnemyHealth,toughenemies=EnemyHealth,enemyspeed=EnemySpeed,fastenemies=EnemySpeed,enemyspawncount=EnemySpawnCount,moreenemies=EnemySpawnCount,towerdamage=TowerDamage,weakenedtowers=TowerDamage,towerdegrading=TowerDegrading,degradingtowers=TowerDegrading,towerrange=TowerRange,reducedrange=TowerRange,explosiveenemies=Explosive,explosive=Explosive,noselling=NoSelling,shieldhealth=ShieldHealth,shieldedenemies=Shielded,armoredenemies=Shielded,shielded=Shielded,uselessartifacts=UselessArtifacts,uselessfarms=UselessFarms,farmsgive50cash=UselessFarms,singleplacementtowers=SinglePlacement,singleplacement=SinglePlacement,uselesstraits=UselessTraits,elementalenemies=ElementalShield,elementalshield=ElementalShield,stealthenemies=Stealth,stealth=Stealth,doubletowercosts=DoubleTowerCosts,doubletowercost=DoubleTowerCosts"
	local map = {}
	for pair in RAW:gmatch("[^,]+") do
		local key, val = pair:match("^([^=]+)=(.+)$")
		if key and val then
			map[key] = val
		end
	end
	function resolveChallengeId(title)
		local id = map[normTitle(title)]
		if id then
			return id
		end
		return fuzzyChallengeId(title)
	end
end

--// Auto Dungeon toggles
DungeonFlowBox:AddToggle("BackFrom10", {
	Default = false,
	Text = "Auto Back from 10",
	Tooltip = "The instant a Forsaken Prison Floor 10 match starts, teleports back to the lobby.",
	Callback = function(Value)
		if not Value then
			backFrom10Armed = false
			backFrom10Fired = false
		end
	end,
})

DungeonFlowBox:AddToggle("AutoNext", {
	Default = false,
	Text = "Auto Next",
	Tooltip = "Votes PlayerVoteReplay 3x (0.5s apart) after every match end.",
	Callback = function(Value)
		if not Value then
			autoNextRun += 1 -- abort
		end
	end,
})

DungeonChallengeBox:AddToggle("AutoBestChallenge", {
	Default = false,
	Text = "Auto Select Best Challenge",
	Tooltip = "Votes the best-ranked of the three offered challenges.",
	Callback = function(Value)
		if Value then
			setChallengeLabel("waiting for challenge screen...")
		else
			challengeRun += 1 -- abort
			dungLastScreenSig = nil
			dungLastUnknownSig = nil
			dungLastUnreadable = nil
			setChallengeLabel("off")
		end
	end,
})

--// Challenge screen poll: fast, so the pick lands the moment the cards show
task.spawn(function()
	while STATE.alive() and myGenAlive() do
		task.wait(0.5)
		if not (Toggles.AutoBestChallenge and Toggles.AutoBestChallenge.Value) then
			dungLastScreenSig = nil
			dungLastUnreadable = nil
		else
			local titles = readChallengeTitles()
			if titles == false then
				-- screen open, cards unreadable: shout ONCE instead of silence
				dungLastScreenSig = nil
				if not dungLastUnreadable then
					dungLastUnreadable = true
					warn("[UTD] challenge screen is open but the cards could not be read")
					setChallengeLabel("screen open, cards unreadable!")
				end
			elseif not titles then
				dungLastScreenSig = nil
				dungLastUnreadable = nil
			else
				dungLastUnreadable = nil
				local sig = table.concat(titles, "|")
				if sig ~= dungLastScreenSig then
					-- resolve all three: hand-mapped table first, fuzzy match
					-- (unique best only) as backup
					local ids, okAll = {}, true
					for _, title in ipairs(titles) do
						local id = resolveChallengeId(title)
						if not id then
							okAll = false
							if sig ~= dungLastUnknownSig then
								dungLastUnknownSig = sig
								print("[UTD] screen vote: unknown title '" .. title .. "' (waiting remote)")
							end
							break
						end
						ids[#ids + 1] = id
					end
					if okAll then
						local pick, pickScore = 1, math.huge
						for i, name in ipairs(ids) do
							local score = CHALLENGE_RANK[name] or math.huge
							if score < pickScore then
								pick, pickScore = i, score
							end
						end
						dungLastScreenSig = sig
						-- stand down while the primary (authoritative) path is
						-- live: if it voted in the last few seconds its pick is
						-- correct and this screen guess must not override it.
						if os.clock() - lastChallengeVoteAt < 3 then
							print("[UTD] screen vote suppressed (primary just voted)")
						else
							print("[UTD] screen vote: " .. table.concat(titles, ", ") .. " -> picking " .. pick)
							setChallengeLabel("picked " .. pick .. " (" .. ids[pick] .. ") [screen]")
							fireChallengeVote(pick, ids[pick] .. " screen")
						end
					end
				end
			end
		end
	end
end)

--// Challenge vote (primary): server opens ServerStartChallengeVote(options);
-- while the toggle is on, answer with the best-ranked slot. The listener
-- re-attaches whenever the remote instance rotates, so no vote is missed.
task.spawn(function()
	local connected = nil
	while STATE.alive() and myGenAlive() do
		local re = resolvePath("ReplicatedStorage.Modules.GlobalInit.RemoteEvents")
		local voteRemote = re and re:FindFirstChild("ServerStartChallengeVote")
		if voteRemote and voteRemote ~= connected then
			connected = voteRemote
			STATE.connect(voteRemote.OnClientEvent, function(options)
				if not myGenAlive() then
					return
				end
				if not (Toggles.AutoBestChallenge and Toggles.AutoBestChallenge.Value) then
					return
				end
				local names = {}
				if type(options) == "table" then
					for _, v in ipairs(options) do
						names[#names + 1] = tostring(v)
					end
				end
				if #names == 0 then
					return
				end
				-- lowest rank wins; unknown names sort last and never win
				-- against a known one
				local pick, pickScore = 1, math.huge
				for i, name in ipairs(names) do
					local score = CHALLENGE_RANK[name] or math.huge
					if score < pickScore then
						pick, pickScore = i, score
					end
				end
				print("[UTD] challenge vote: " .. table.concat(names, ", ") .. " -> picking " .. pick .. " (" .. names[pick] .. ")")
				setChallengeLabel("picked " .. pick .. " (" .. names[pick] .. ")")
				fireChallengeVote(pick, names[pick])
			end)
		end
		task.wait(1) -- re-check fast: the remote appears only at match start
	end
end)

--// Challenge confirmation: the server broadcasts "Challenge Selected: <font>NAME</font>"
-- on ServerSendMessage once a pick is locked in. Catch it, bump challengeRun so
-- any in-flight fireChallengeVote retry stops (no extra votes), and log the
-- resolved title so we can see (and verify) which challenge actually won.
task.spawn(function()
	local connected
	while STATE.alive() and myGenAlive() do
		local re = resolvePath("ReplicatedStorage.Modules.GlobalInit.RemoteEvents")
		local send = re and re:FindFirstChild("ServerSendMessage")
		if send and send ~= connected then
			connected = send
			STATE.connect(send.OnClientEvent, function(...)
				if not myGenAlive() then
					return
				end
				for _, a in ipairs({ ... }) do
					local s = tostring(a)
					if s:find("Challenge Selected", 1, true) then
						-- strip RichText tags ("<font ...>" / "</font>") first
						local clean = s:gsub("<[^>]+>", "")
						local title = clean:match("Challenge Selected:%s*(.+)")
						if title then
							title = title:gsub("^%s+", ""):gsub("%s+$", "")
							local id = resolveChallengeId(title)
							challengeRun += 1 -- stop any pending retry (vote landed)
							print("[UTD] challenge confirmed: '" .. title .. "'"
								.. (id and (" = " .. id .. " (rank " .. tostring(CHALLENGE_RANK[id] or "?") .. ")") or " (unresolved)"))
							setChallengeLabel("confirmed: " .. title)
						end
					end
				end
			end)
		end
		task.wait(1)
	end
end)

--// Auto Dungeon flow hooks (invoked from onMatchStart / onMatchEnd below).
-- Only the NAMED MatchBegun event carries a map: the nameless poll/attach
-- retries must not restart or kill a running sequence.
dungeonOnMatchStart = function(mapName)
	-- a named MatchBegun is canonical; the attach/poll retries carry no name
	-- (they fire when the script loaded AFTER the event), so fall back to the
	-- live proxy - without this the sequence never starts on a mid-match load
	local name
	if mapName ~= nil and tostring(mapName) ~= "" then
		name = tostring(mapName)
	else
		name = tostring(currentMapName(true) or currentMapName() or "")
		if name == "" and matchRunning() then
			-- live seen on floor 1: the one-shot MatchBegun fires the instant
			-- the remote is (re)created, i.e. before the listener can attach,
			-- and the proxy mapId is not filled yet - so the nameless retry
			-- returned and the flow only started at floor 2 where the remote
			-- rotates again and the reconnect wins the race. A nameless LIVE
			-- match is therefore treated as Forsaken Prison (this toggle is
			-- only used inside the dungeon queue).
			name = "Forsaken Prison"
		end
	end
	if name == "" then
		return
	end
	-- display and queue spell the map differently ("Forsaken Prison - Floor 3"
	-- vs "ForsakenPrison" / "Forsaken_Prison"): compare ignoring case and
	-- every non-letter/number character
	local flat = name:lower():gsub("[^%w]", "")
	local isForsaken = flat:find("forsakenprison", 1, true) ~= nil
	local isFloor10 = flat:find("floor10", 1, true) ~= nil
	local namedStart = mapName ~= nil and tostring(mapName) ~= ""
	local now = os.clock()
	-- the debounce only guards duplicate starts of the SAME match: it must
	-- never be armed by a nameless attach (proxy guess), or the real named
	-- MatchBegun that follows would be debounced away and the sequence skipped
	if isForsaken and now - dungeonLastNamedStart < 2 then
		return -- duplicate begun for the same match
	end
	if isForsaken then
		dungeonLastNamedStart = now
	end

	-- Auto Back from 10: the instant a Floor 10 match starts, teleport straight
	-- back to the lobby - no waiting for the match to end. backFrom10Armed
	-- still keeps Auto Next from firing a replay vote on this match's end.
	if Toggles.BackFrom10 and Toggles.BackFrom10.Value then
		if isForsaken and isFloor10 then
			backFrom10Armed = true
			if not backFrom10Fired then
				-- the shot goes out immediately; retry briefly because a
				-- match-scoped remote can be a beat behind the started event
				if fireGlobalEvent("PlayerRequestTeleportToLobby") then
					backFrom10Fired = true
					notify("Auto Back from 10", "Floor 10 - back to lobby", 3)
				else
					task.spawn(function()
						for _ = 1, 8 do
							task.wait(0.5)
							if not (STATE.alive() and myGenAlive()) then
								return
							end
							if fireGlobalEvent("PlayerRequestTeleportToLobby") then
								backFrom10Fired = true
								notify("Auto Back from 10", "Floor 10 - back to lobby", 3)
								return
							end
						end
					end)
				end
			end
		else
			backFrom10Armed = false
			backFrom10Fired = false -- re-arm for a future Floor 10
		end
	else
		backFrom10Armed = false
		backFrom10Fired = false
	end
end

dungeonOnMatchEnd = function()
	-- Auto Next: 3 replay votes, 0.5s apart. Skipped on a Floor 10 (armed for
	-- lobby return): a replay vote here could swallow the lobby teleport.
	if Toggles.AutoNext and Toggles.AutoNext.Value and not backFrom10Armed then
		autoNextRun += 1
		local id = autoNextRun
		task.spawn(function()
			for _ = 1, 3 do
				task.wait(0.5)
				if id ~= autoNextRun then
					return
				end
				if not (Toggles.AutoNext and Toggles.AutoNext.Value) then
					return
				end
				if not (STATE.alive() and myGenAlive()) then
					return
				end
				fireGlobalEvent("PlayerVoteReplay")
			end
		end)
	end

	-- Auto Back from 10: safety net only - the instant shot on MatchBegun is
	-- the normal path, this catches the rare case where that shot never went
	-- out (backFrom10Fired stays false).
	if Toggles.BackFrom10 and Toggles.BackFrom10.Value and backFrom10Armed and not backFrom10Fired then
		backFrom10Fired = true
		backFrom10Armed = false
		if fireGlobalEvent("PlayerRequestTeleportToLobby") then
			notify("Auto Back from 10", "Return vote sent", 3)
		end
	end

end

-- forward declarations: the poll below fires before these are defined, and
-- Lua only sees locals declared ABOVE the caller - so declare first, assign
-- at their original spots.
local onMatchEnd
local matchEndHandled = false

-- match-start hub: capture + auto replay. (Dungeon reset lived here while
-- the Auto Dungeon tab existed - removed with it.)
local lastMatchStart = 0
-- invalidates deferred map lookups when a newer match start arrives
local autoPickRun = 0

-- starts the dropdown-selected macro (old Auto Replay behavior)
local function startSelectedMacro(mapName)
	local sel = Options.MacroSelect and Options.MacroSelect.Value
	if not sel then
		return false
	end
	local data = loadMacro(sel)
	if not (data and data.events and #data.events > 0) then
		return false
	end
	if startReplay(data.events, Options.Tolerance.Value, data.placeByEntity) then
		notify("Auto Replay", sel .. (mapName and (" on " .. tostring(mapName)) or " (match start)"), 4)
		return true
	end
	return false
end

-- Auto Name Replay: scan ALL macros, pick the newest one saved for this map.
-- Auto Replay (selected macro) is the fallback when no map match exists.
-- attachLate: the MatchBegun listener just attached and the event was
-- probably already missed - keep only a tiny grace for an in-flight event.
local function maybeAutoReplay(mapName, attachLate)
	if RecState == "recording" or RecState == "paused" or ReplayCtx then
		return
	end
	local mapOn = Toggles.AutoMapReplay and Toggles.AutoMapReplay.Value
	local selOn = Toggles.AutoReplay and Toggles.AutoReplay.Value
	if not mapOn and not selOn then
		return
	end
	autoPickRun += 1
	local runId = autoPickRun

	local function tryMap(name)
		if not name or name == "" or ReplayCtx then
			return false
		end
		local pickedName, data = findMacroByMap(name)
		if not (pickedName and data and data.events and #data.events > 0) then
			return false
		end
		if startReplay(data.events, Options.Tolerance.Value, data.placeByEntity) then
			notify("Auto Replay (map)", pickedName .. " on " .. tostring(name), 5)
			return true
		end
		return false
	end

	if not mapOn then
		startSelectedMacro(mapName or freshMatchMap())
		return
	end

	-- canonical name arrived with MatchBegun: decide immediately
	if mapName then
		if tryMap(mapName) then
			return
		end
		if selOn then
			startSelectedMacro(mapName)
		end
		return
	end

	-- a recent event already named this match (script attached a bit late)
	local fresh = freshMatchMap()
	if fresh then
		if tryMap(fresh) then
			return
		end
		if selOn then
			startSelectedMacro(fresh)
		end
		return
	end

	-- the HUD poll claimed the start before MatchBegun delivered the name.
	-- A live match means the proxy already knows its map: try it at once so
	-- a missed event never delays the start.
	local proxyTried = false
	if matchRunning() then
		local proxyNow = currentMapName(true)
		if proxyNow and proxyNow ~= "" then
			proxyTried = true
			if tryMap(proxyNow) then
				return
			end
		end
	end

	-- short grace window for an in-flight MatchBegun, then the proxy again
	-- (map data can land a beat after the HUD) and finally the fallback
	task.spawn(function()
		local t0 = os.clock()
		local grace = attachLate and 0.3 or 1
		while os.clock() - t0 < grace and runId == autoPickRun and not ReplayCtx and STATE.alive() and myGenAlive() do
			if RecState == "recording" or RecState == "paused" then
				return
			end
			local live = freshMatchMap()
			if live then
				if tryMap(live) then
					return
				end
				if selOn then
					startSelectedMacro(live)
				end
				return
			end
			task.wait(0.05)
		end
		if runId ~= autoPickRun or ReplayCtx then
			return
		end
		local proxyName
		if matchRunning() then
			proxyName = currentMapName(true)
		end
		if not proxyTried and proxyName and proxyName ~= "" then
			if tryMap(proxyName) then
				return
			end
		end
		if selOn then
			startSelectedMacro(proxyName)
		end
	end)
end

local function onMatchStart(source, mapName)
	if not myGenAlive() then
		return
	end
	--// Auto Dungeon: fires the instant MatchBegun lands. Called FIRST, before
	-- anything that could yield (beginCapture / maybeAutoReplay can task.wait
	-- up to ~1.5s in waitForStepRemotes), so the instant place is never late.
	-- Named-event only: the nameless poll/attach retries no-op on nil mapName.
	if dungeonOnMatchStart then
		dungeonOnMatchStart(mapName)
	end
	-- learn the map BEFORE the debounce: the poll may already have started
	-- the capture, and this event still owns the canonical map name
	noteMatchMap(mapName)
	local now = os.clock()
	local firstForMatch = now - lastMatchStart >= 2
	if firstForMatch then
		lastMatchStart = now
		matchEndHandled = false -- next end may trigger again
	end
	-- capture: t=0 is the real match start (no settle delay)
	if firstForMatch and RecState == "armed" then
		beginCapture(mapName or currentMapName())
	end
	-- auto replay is idempotent (ReplayCtx guard), so the event can retry
	-- the picker even when the poll already claimed this match
	maybeAutoReplay(mapName, source == "attach")
end

-- RoundOver screen = the match ended (visible even if both Gameover signals
-- were missed). Polled, so it cannot be missed like a one-shot event.
local function roundOverVisible()
	local gui = LocalPlayer.PlayerGui:FindFirstChild("MainGui")
	local frames = gui and gui:FindFirstChild("MainFrames")
	local ro = frames and frames:FindFirstChild("RoundOver")
	return ro ~= nil and ro.Visible == true
end

-- match-start poll: presence + HUD transitions catch every start even when
-- the one-shot begun signal fires before our listener attaches.
-- (wasOver starts false on purpose: loading straight into an ended match
-- also triggers the end path below.)
task.spawn(function()
	local wasRun, wasHud, wasOver = matchRunning(), inMatchHud(), false
	while STATE.alive() and myGenAlive() do
		task.wait(0.25)
		local nowRun, nowHud, nowOver = matchRunning(), inMatchHud(), roundOverVisible()
		if (nowRun and not wasRun) or (nowHud and not wasHud) then
			onMatchStart("poll")
		end
		if nowOver and not wasOver and not matchEndHandled then
			matchEndHandled = true
			onMatchEnd("poll")
		end
		wasRun, wasHud, wasOver = nowRun, nowHud, nowOver
	end
end)
task.spawn(function()
	-- MatchBegun (and the tower remotes) are created when the match loads, so keep
	-- looking until the remote shows up instead of giving up.
	local MatchBegunRemote
	while not MatchBegunRemote and STATE.alive() and myGenAlive() do
		local RS = game:GetService("ReplicatedStorage")
		local m = RS:FindFirstChild("Modules")
		local g = m and m:FindFirstChild("GlobalInit")
		local r = g and g:FindFirstChild("RemoteEvents")
		MatchBegunRemote = r and r:FindFirstChild("MatchBegun")
		if not MatchBegunRemote then
			task.wait(0.1)
		end
	end
	if MatchBegunRemote then
		STATE.connect(MatchBegunRemote.OnClientEvent, function(mapName)
			onMatchStart("begun", mapName)
		end)
		-- the event may have fired while we were still polling for the
		-- remote: if a match is already live, claim the start now (short
		-- delay so an in-flight event still wins with its canonical name)
		if matchRunning() then
			task.delay(0.25, function()
				if STATE.alive() and myGenAlive() and not ReplayCtx then
					onMatchStart("attach")
				end
			end)
		end
	else
		warn("[UTD] MatchBegun remote not found")
	end
end)

--// Match end: the server announces the decided round on TWO channels - the
-- Network/Gameover event and the GlobalInit RemoteEvents/Gameover remote.
-- Either one stops an active replay. (Auto-finish of recordings was removed
-- per user request - Finish is manual via the Finish button.)
onMatchEnd = function()
	if not myGenAlive() then
		return -- stale copy's handler: the live copy owns this event
	end
	-- the match map is dead; a new match must provide its own MatchBegun
	-- name before the auto picker trusts a map again
	LAST_MATCH_MAP = nil
	LAST_MATCH_MAP_AT = 0
	if ReplayCtx then
		stopReplay("match ended")
	end
	--// Auto Dungeon: match end drives auto-next / back-from-11 (block above)
	if dungeonOnMatchEnd then
		dungeonOnMatchEnd()
	end
end

task.spawn(function()
	local GameoverRemote
	while not GameoverRemote and STATE.alive() and myGenAlive() do
		local RS = game:GetService("ReplicatedStorage")
		local gm = RS:FindFirstChild("GenericModules")
		local sv = gm and gm:FindFirstChild("Service")
		local net = sv and sv:FindFirstChild("Network")
		GameoverRemote = net and net:FindFirstChild("Gameover")
		if not GameoverRemote then
			task.wait(1)
		end
	end
	if GameoverRemote then
		STATE.connect(GameoverRemote.OnClientEvent, function(victory)
			onMatchEnd(victory, "Network/Gameover")
		end)
	else
		warn("[UTD] Network/Gameover remote not found")
	end
end)

task.spawn(function()
	-- This channel carries the full reward table (goldReward, expReward,
	-- ExtraReward); Network/Gameover only carries a victory flag. The GlobalInit
	-- remotes are rebuilt by the game between lobby and match, so a one-shot
	-- attach dies silently and the totals stop accumulating - watchRemote keeps
	-- the hook alive (and its once-per-instance rule keeps a reward event from
	-- ever being counted twice).
	local function onGameover(result)
		if not myGenAlive() then
			return
		end
		-- fold it into the running totals the webhook reports (Totals IS the
		-- getgenv() store, so these writes persist on their own)
		if type(result) == "table" then
			Totals.matches += 1
			Totals.gold += tonumber(result.goldReward) or 0
			Totals.exp += tonumber(result.expReward) or 0
			local extra = result.ExtraReward
			if type(extra) == "table" then
				for k, v in pairs(extra) do
					local n = tonumber(v)
					if n then
						local key = tostring(k)
						Totals.extra[key] = (Totals.extra[key] or 0) + n
					end
				end
			end
		end
		onMatchEnd(result, "GlobalInit/Gameover")
	end
	watchRemote(function()
	local m = game:GetService("ReplicatedStorage"):FindFirstChild("Modules")
	local g = m and m:FindFirstChild("GlobalInit")
	return g and g:FindFirstChild("RemoteEvents")
end, "Gameover", onGameover)
end)


--// UI Settings tab
local MenuGroup = Tabs["UI Settings"]:AddLeftGroupbox("Menu")

MenuGroup:AddToggle("CustomCursor", {
	Text = "Custom Cursor",
	Default = false,
	Tooltip = "Linoria's triangle cursor while the menu is open. Off = stock Roblox cursor.",
	Callback = function(Value)
		Library.ShowCustomCursor = Value
	end,
})
MenuGroup:AddButton("Unload", function()
	Library:Unload()
end)
MenuGroup:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", { Default = "LeftControl", NoUI = true, Text = "Menu keybind" })

Library.ToggleKeybind = Options.MenuKeybind

--// Config + theme managers (both Linoria stock)
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
SaveManager:SetFolder("FallyoUTD")
ThemeManager:SetFolder("FallyoUTD/themes")
SaveManager:BuildConfigSection(Tabs["UI Settings"])
ThemeManager:ApplyToTab(Tabs["UI Settings"])
SaveManager:LoadAutoloadConfig()
-- the config can restore a stale macro selection, so rebuild the list after it
refreshMacroList()

--// Silent auto-persist: everything the user sets survives reloads with zero
-- config fiddling. Toggles + dropdowns/sliders/inputs are snapshotted to one
-- file on every change (debounced) and re-applied on the next load, so the
-- menu always reopens exactly how it was left.
local AUTO_FILE = "FallyoUTD/auto.json"
local persistQueued = false

-- keypicker values have their own shape - never persist or restore those
local PERSIST_SKIP = { RecordKey = true, MenuKeybind = true }

local function persistUI()
	local data = { toggles = {}, options = {}, v = 2 }
	for idx, t in pairs(Toggles) do
		if type(t) == "table" and type(t.Value) == "boolean" then
			data.toggles[idx] = t.Value
		end
	end
	for idx, o in pairs(Options) do
		if not PERSIST_SKIP[idx] and type(o) == "table" then
			local v = o.Value
			if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then
				data.options[idx] = v
			end
		end
	end
	local ok, json = pcall(HttpService.JSONEncode, HttpService, data)
	if ok then
		pcall(writefile, AUTO_FILE, json)
	end
end

local function persistSoon()
	if persistQueued then
		return
	end
	persistQueued = true
	task.delay(1, function()
		persistQueued = false
		persistUI()
	end)
end

local function restoreUI()
	local ok, content = pcall(readfile, AUTO_FILE)
	if not ok then
		return
	end
	local okD, data = pcall(HttpService.JSONDecode, HttpService, content)
	if not okD or type(data) ~= "table" then
		return
	end
	if type(data.toggles) == "table" then
		for idx, v in pairs(data.toggles) do
			local t = Toggles[idx]
			if t and type(v) == "boolean" then
				pcall(function()
					t:SetValue(v)
				end)
			end
		end
	end
	if type(data.options) == "table" then
		local cfgV = tonumber(data.v) or 0
		for idx, v in pairs(data.options) do
			-- v1 configs carry the old 1.2x slowdown default, which made
			-- every replay 20% slower than the recording: nudge to 1.05x once
			if cfgV < 2 and idx == "Tolerance" and v == 1.2 then
				v = 1.05
			end
			local o = Options[idx]
			if o and not PERSIST_SKIP[idx] and (type(v) == "string" or type(v) == "number" or type(v) == "boolean") then
				pcall(function()
					o:SetValue(v)
				end)
			end
		end
	end
end

for _, t in pairs(Toggles) do
	if type(t) == "table" and t.OnChanged then
		t:OnChanged(persistSoon)
	end
end
for _, o in pairs(Options) do
	if type(o) == "table" and o.OnChanged then
		o:OnChanged(persistSoon)
	end
end
ReExec.restoring = true
restoreUI()
ReExec.restoring = false
if Toggles.Reexecute and Toggles.Reexecute.Value then
	ReExec.apply(true)
end

Library:OnUnload(function()
	persistUI() -- one last snapshot on the way out
	ReExec.clearTarget() -- cancel a queued re-execute on manual unload
	setAntiAfk(false)
	RECORDING = false
	RecState = "idle"
	PAUSE_AT = nil
	ReplayCtx = nil
end)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

if RunService:IsClient() then
	return {} :: DataServiceServer
end

local Packages = script.Parent.Parent
local Signal = require(Packages.Signal)
local Networker = require(Packages.Networker)
local ProfileStore = require(Packages.ProfileStore)

local DEFAULT_PLAYER_STORE_NAME = "PlayerStore"
local DEFAULT_DATA_PREFIX = "PLAYER_"

type Profile = ProfileStore.Profile<any>

export type Options = {
	template: any,
	globalData: { any }?,
	useMock: boolean?,
	onPlayerInit: (Player, any) -> ()?,
	onPlayerRemoving: (Player, any) -> ()?,
	debug: boolean?,
	playerStoreName: string?,
	dataPrefix: string?,
}

type Path = string | { string }

local DataServiceServer = {
	_profiles = {} :: { [Player]: Profile? },
}

function DataServiceServer.init(self: DataServiceServer, options: Options)
	if not RunService:IsServer() then
		warn("DataServiceServer can only be used on server!")
		return
	end
	if self.playerStore then
		warn("DataServiceServer has already been initialized!")
		return
	end

	self._changedSignals = {}
	self._waitSignals = {}
	self._globalChangedSignals = {}

	self.options = options
	self.globalData = self.options.globalData or {}
	self.playerStore = ProfileStore.New(options.playerStoreName or DEFAULT_PLAYER_STORE_NAME, options.template)
	self.networker = Networker.server.new("DataService", self, {
		self.get,
		self.getGlobal,
	})

	for _, player: Player in Players:GetPlayers() do
		task.spawn(function()
			self:_playerAdded(player)
		end)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		self:_playerAdded(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_playerRemoving(player)
	end)
end

local function playerStoreCancel(player: Player)
	return {
		Cancel = function()
			return player.Parent ~= Players
		end,
	}
end

function DataServiceServer._playerAdded(self: DataServiceServer, player: Player)
	if self._profiles[player] then
		warn("Player already initialized!")
		return
	end

	local userId = player.UserId
	local index = self:_getProfileIndex(userId)

	local profile = if self.options.useMock
		then self.playerStore.Mock:StartSessionAsync(index, playerStoreCancel(player))
		else self.playerStore:StartSessionAsync(index, playerStoreCancel(player)) :: Profile

	if not profile then
		player:Kick(`Profile load fail - Please rejoin`)
		return
	end

	profile:AddUserId(userId)
	profile:Reconcile()
	profile.OnSessionEnd:Connect(function()
		self._profiles[player] = nil
		player:Kick(`Profile session end - Please rejoin`)
	end)

	if not player:IsDescendantOf(Players) then
		player:Kick(`Profile load fail - Please rejoin`)
		return
	end

	if self.options.debug then
		print(`[{script.Name}.Debug]: ({player.Name}) joined with data:\n`, profile.Data)
	end

	if self.options.onPlayerInit then
		self.options.onPlayerInit(player, profile.Data)
		local success, errorMessage = pcall(self.options.onPlayerInit, player, profile.Data)
		if not success and self.options.debug then
			warn(`[{script.Name}.Debug]: Error calling onPlayerInit for ({player.Name})\nError: `, errorMessage)
		end
	end

	if player and player:IsDescendantOf(Players) and profile then
		self._profiles[player] = profile

		if self._waitSignals[player] then
			self._waitSignals[player]:Fire()
			self._waitSignals[player]:Destroy()
			self._waitSignals[player] = nil
		end

		self.networker:fire(player, "dataLoaded", profile.Data)
	end
end

function DataServiceServer._getProfileIndex(self: DataServiceServer, userId: number)
	return (self.options.dataPrefix or DEFAULT_DATA_PREFIX) .. userId
end

function DataServiceServer._playerRemoving(self: DataServiceServer, player: Player)
	local profile = self._profiles[player]

	if not profile then
		return
	end

	if self.options.debug then
		print(`[{script.Name}.Debug]: ({player.Name}) left with data:\n`, profile.Data)
	end

	if self.options.onPlayerRemoving then
		local success, errorMessage = pcall(self.options.onPlayerRemoving, player, profile.Data)
		if not success and self.options.debug then
			warn(`[{script.Name}.Debug]: Error calling onPlayerRemoving for ({player.Name})\nError: `, errorMessage)
		end
	end

	profile:EndSession()
	self._profiles[player] = nil

	if self._waitSignals[player] then
		self._waitSignals[player]:Destroy()
		self._waitSignals[player] = nil
	end

	if self._changedSignals[player] then
		for _, signal: Signal.Signal<any> in self._changedSignals[player] do
			signal:Destroy()
		end
		self._changedSignals[player] = nil
	end
end

function DataServiceServer.getProfile(self: DataServiceServer, player: Player): Profile?
	return self._profiles[player]
end

local function pathToString(path: string | { string })
	if type(path) == "string" then
		return path
	end

	return table.concat(path, "/")
end

function DataServiceServer.get(self: DataServiceServer, player: Player, path: Path?): any
	local profile = self:getProfile(player)
	if not profile then
		return
	end

	local data = profile.Data

	if not path then
		return data
	end

	if type(path) == "string" then
		return data[path]
	end

	for _, key in ipairs(path) do
		data = data[key]
	end

	return data
end

function DataServiceServer.set(
	self: DataServiceServer,
	player: Player,
	path: Path,
	newValue: any,
	dontReplicate: boolean?
)
	local profile = self:getProfile(player)
	if not profile then
		return
	end

	local data = profile.Data
	if not path then
		return
	end

	local stringPath = pathToString(path)
	if type(path) == "string" then
		local oldValue = data[path]
		if oldValue ~= newValue then
			data[path] = newValue

			if self._changedSignals[player] and self._changedSignals[player][stringPath] then
				self._changedSignals[player][stringPath]:Fire(newValue, oldValue)
			end

			if not dontReplicate then
				self.networker:fire(player, "dataChanged", path, newValue, oldValue)
			end
		end
		return
	end

	for i = 1, #path - 1 do
		data = data[path[i]]
	end

	local lastKey = path[#path]
	local oldValue = data[lastKey]
	if oldValue ~= newValue then
		data[lastKey] = newValue

		if self._changedSignals[player] and self._changedSignals[player][stringPath] then
			self._changedSignals[player][stringPath]:Fire(newValue, oldValue)
		end

		if not dontReplicate then
			self.networker:fire(player, "dataChanged", path, newValue, oldValue)
		end
	end
end

function DataServiceServer.setPlayers(
	self: DataServiceServer,
	players: { Player } | "all",
	path: Path,
	newValue: any,
	dontReplicate: boolean?
)
	players = (players == "all" and Players:GetPlayers()) or players
	for _, player: Player in players do
		self:set(player, path, newValue, dontReplicate)
	end
end

function DataServiceServer.getGlobal(self: DataServiceServer, path: Path?): any
	local data = self.globalData or {}

	if not path then
		return data
	end

	if type(path) == "string" then
		return data[path]
	end

	for _, key in ipairs(path) do
		data = data[key]
	end

	return data
end

function DataServiceServer.setGlobal(self: DataServiceServer, path: Path, newValue: any, dontReplicate: boolean?)
	local data = self.globalData
	if not path then
		return
	end

	local stringPath = pathToString(path)
	if type(path) == "string" then
		local oldValue = data[path]
		if oldValue ~= newValue then
			data[path] = newValue

			if self._globalChangedSignals[stringPath] then
				self._globalChangedSignals[stringPath]:Fire(newValue, oldValue)
			end

			if not dontReplicate then
				self.networker:fireAll("globalDataChanged", path, newValue)
			end
		end
		return
	end

	for i = 1, #path - 1 do
		data = data[path[i]]
	end

	local lastKey = path[#path]
	local oldValue = data[lastKey]
	if oldValue ~= newValue then
		data[lastKey] = newValue

		if self._globalChangedSignals[stringPath] then
			self._globalChangedSignals[stringPath]:Fire(newValue, oldValue)
		end

		if not dontReplicate then
			self.networker:fireAll("globalDataChanged", path, newValue)
		end
	end
end

function DataServiceServer.increment(
	self: DataServiceServer,
	player: Player,
	path: Path,
	amount: number,
	dontReplicate: boolean?
)
	local profile = self:getProfile(player)
	if not profile then
		return
	end

	local data = profile.Data
	if not path then
		return
	end

	local stringPath = pathToString(path)
	if type(path) == "string" then
		local oldValue = data[path]
		local newValue = oldValue + amount
		data[path] = newValue

		if self._changedSignals[player] and self._changedSignals[player][stringPath] then
			self._changedSignals[player][stringPath]:Fire(newValue, oldValue)
		end

		if not dontReplicate then
			self.networker:fire(player, "dataChanged", path, newValue, oldValue)
		end

		return newValue, oldValue
	end

	for i = 1, #path - 1 do
		data = data[path[i]]
	end

	local lastKey = path[#path]
	local oldValue = data[lastKey]
	local newValue = oldValue + amount
	data[lastKey] = newValue

	if self._changedSignals[player] and self._changedSignals[player][stringPath] then
		self._changedSignals[player][stringPath]:Fire(newValue, oldValue)
	end

	if not dontReplicate then
		self.networker:fire(player, "dataChanged", path, newValue, oldValue)
	end

	return newValue, oldValue
end

function DataServiceServer.update(
	self: DataServiceServer,
	player: Player,
	path: Path,
	callback: (any) -> any,
	dontReplicate: boolean?
)
	local profile = self:getProfile(player)
	if not profile then
		return
	end

	local data = profile.Data
	if not path then
		return
	end

	local stringPath = pathToString(path)
	if type(path) == "string" then
		local oldValue = data[path]
		local newValue = callback(oldValue)
		if newValue ~= oldValue then
			data[path] = newValue
			if self._changedSignals[player] and self._changedSignals[player][stringPath] then
				self._changedSignals[player][stringPath]:Fire(newValue, oldValue)
			end
			if not dontReplicate then
				self.networker:fire(player, "dataChanged", path, newValue, oldValue)
			end
		end
		return newValue, oldValue
	end

	for i = 1, #path - 1 do
		data = data[path[i]]
	end

	local lastKey = path[#path]
	local oldValue = data[lastKey]
	local newValue = callback(oldValue)
	if newValue ~= oldValue then
		data[lastKey] = newValue
		if self._changedSignals[player] and self._changedSignals[player][stringPath] then
			self._changedSignals[player][stringPath]:Fire(newValue, oldValue)
		end
		if not dontReplicate then
			self.networker:fire(player, "dataChanged", path, newValue, oldValue)
		end
	end

	return newValue, oldValue
end

function DataServiceServer.tableInsert(
	self: DataServiceServer,
	player: Player,
	path: Path,
	newValue: any,
	index: number?,
	dontReplicate: boolean?
)
	local tbl = self:get(player, path)
	if type(tbl) ~= "table" then
		return
	end

	if index then
		table.insert(tbl, index, newValue)
	else
		table.insert(tbl, newValue)
	end

	if self._changedSignals[player] then
		local stringPath = pathToString(path)
		if self._changedSignals[player][stringPath] then
			self._changedSignals[player][stringPath]:Fire(newValue, index or #tbl)
		end
	end

	if not dontReplicate then
		self.networker:fire(player, "tableInserted", path, newValue, index)
	end
end

function DataServiceServer.tableRemove(
	self: DataServiceServer,
	player: Player,
	path: Path,
	index: number,
	dontReplicate: boolean?
)
	local tbl = self:get(player, path)
	if type(tbl) ~= "table" then
		return
	end

	local removedValue = table.remove(tbl, index)

	if self._changedSignals[player] then
		local stringPath = pathToString(path)
		if self._changedSignals[player][stringPath] then
			self._changedSignals[player][stringPath]:Fire(removedValue, index)
		end
	end

	if not dontReplicate then
		self.networker:fire(player, "tableRemoved", path, index, removedValue)
	end

	return removedValue
end

function DataServiceServer.tableInsertPlayers(
	self: DataServiceServer,
	players: { Player } | "all",
	path: Path,
	newValue: any,
	index: number?,
	dontReplicate: boolean?
)
	players = (players == "all" and Players:GetPlayers()) or players
	for _, player: Player in players do
		self:tableInsert(player, path, newValue, index, dontReplicate)
	end
end

function DataServiceServer.tableRemovePlayers(
	self: DataServiceServer,
	players: { Player } | "all",
	path: Path,
	index: number,
	dontReplicate: boolean?
)
	players = (players == "all" and Players:GetPlayers()) or players
	for _, player: Player in players do
		self:tableRemove(player, path, index, dontReplicate)
	end
end

function DataServiceServer.tableInsertGlobal(
	self: DataServiceServer,
	path: Path,
	newValue: any,
	index: number?,
	dontReplicate: boolean?
)
	local tbl = self:getGlobal(path)
	if type(tbl) ~= "table" then
		return
	end

	if index then
		table.insert(tbl, index, newValue)
	else
		table.insert(tbl, newValue)
	end

	local stringPath = pathToString(path)
	if self._globalChangedSignals[stringPath] then
		self._globalChangedSignals[stringPath]:Fire(newValue, index or #tbl)
	end

	if not dontReplicate then
		self.networker:fireAll("tableInserted", path, newValue, index, true)
	end
end

function DataServiceServer.tableRemoveGlobal(
	self: DataServiceServer,
	path: Path,
	index: number,
	dontReplicate: boolean?
)
	local tbl = self:getGlobal(path)
	if type(tbl) ~= "table" then
		return
	end

	local removedValue = table.remove(tbl, index)

	local stringPath = pathToString(path)
	if self._globalChangedSignals[stringPath] then
		self._globalChangedSignals[stringPath]:Fire(removedValue, index)
	end

	if not dontReplicate then
		self.networker:fireAll("tableRemoved", path, index, removedValue, true)
	end

	return removedValue
end

function DataServiceServer.waitForData(self: DataServiceServer, player: Player): any
	if not player or not player:IsDescendantOf(Players) then
		if self.options.debug then
			print(
				`[{script.Name}.Debug]: Player doesn't exist or not descendant of game.Players {player and `({player.Name})`}`
			)
		end
		return
	end

	local profile = self:getProfile(player)
	if profile then
		return profile.Data
	else
		local signal = self._waitSignals[player]
		if not signal then
			signal = Signal.new()
			self._waitSignals[player] = signal
		end
		signal:Wait()
		profile = self:getProfile(player)
		return profile and profile.Data
	end
end

function DataServiceServer.getDataChangedSignal(
	self: DataServiceServer,
	player: Player,
	path: Path
): Signal.Signal<any, any>
	local stringPath = pathToString(path)
	if self._changedSignals[player] and self._changedSignals[player][stringPath] then
		return self._changedSignals[player][stringPath]
	else
		if not self._changedSignals[player] then
			self._changedSignals[player] = {}
		end
		local signal = Signal.new()
		self._changedSignals[player][stringPath] = signal
		return signal
	end
end

function DataServiceServer.getGlobalDataChangedSignal(self: DataServiceServer, path: Path): Signal.Signal<any, any>
	local stringPath = pathToString(path)
	if self._globalChangedSignals[stringPath] then
		return self._globalChangedSignals[stringPath]
	else
		local signal = Signal.new()
		self._globalChangedSignals[stringPath] = signal
		return signal
	end
end

export type DataServiceServer = typeof(DataServiceServer) & {
	playerStore: ProfileStore.ProfileStore<any>,
	networker: Networker.Server,
	_profiles: { [Player]: Profile? },
	options: Options,
	_changedSignals: { [Player]: { [string]: Signal.Signal<any, any> } },
	_waitSignals: { [Player]: Signal.Signal<any> },
	_globalChangedSignals: { [string]: Signal.Signal<any, any> },
	globalData: { any },
}

return DataServiceServer :: DataServiceServer

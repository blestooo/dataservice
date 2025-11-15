local RunService = game:GetService("RunService")

if RunService:IsServer() then
	return {} :: DataServiceClient
end

local Packages = script.Parent.Parent
local Networker = require(Packages.Networker)
local Signal = require(Packages.Signal)

type Path = string | { string }
type Data = { [any]: any }

local waitSignal = Signal.new()

local DataServiceClient = {
	_changedSignals = {} :: { [string]: Signal.Signal<any, any> },
	_globalChangedSignals = {} :: { [string]: Signal.Signal<any, any> },
}

function DataServiceClient.init(self: DataServiceClient)
	self.networker = Networker.client.new("DataService", self)

	self:waitForData()
end

function DataServiceClient.dataLoaded(self: DataServiceClient, data: Data)
	if not self._data then
		self._data = data
	end
	if waitSignal then
		waitSignal:Fire(data)
		waitSignal:Destroy()
		waitSignal = nil
	end
end

function DataServiceClient.waitForData(self: DataServiceClient)
	self._data = self._data or self.networker:fetch("get") :: Data
	if not self._data and waitSignal then
		waitSignal:Wait()
	end
	return self._data
end

local function pathToString(path: string | { string })
	if type(path) == "string" then
		return path
	end

	return table.concat(path, "/")
end

function DataServiceClient.get(self: DataServiceClient, path: Path)
	local data = self:waitForData()

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

function DataServiceClient.getGlobal(self: DataServiceClient, path: Path)
	local globalData = self._globalData
	if not globalData then
		globalData = self.networker:fetch("getGlobal") :: { any }
		self._globalData = globalData
	end

	if not path then
		return globalData
	end

	if type(path) == "string" then
		return globalData[path]
	end

	for _, key in ipairs(path) do
		globalData = globalData[key]
	end

	return globalData
end

function DataServiceClient._set(self: DataServiceClient, path: Path, newValue: any)
	local data = self._data
	if type(path) == "string" then
		local oldValue = data[path]
		data[path] = newValue
		return oldValue
	end

	for i = 1, #path - 1 do
		data = data[path[i]]
	end

	local lastKey = path[#path]
	local oldValue = data[lastKey]
	data[lastKey] = newValue
	return oldValue
end

function DataServiceClient._setGlobal(self: DataServiceClient, path: Path, newValue: any)
	local globalData = self._globalData
	if type(path) == "string" then
		local oldValue = globalData[path]
		globalData[path] = newValue
		return oldValue
	end

	for i = 1, #path - 1 do
		globalData = globalData[path[i]]
	end

	local lastKey = path[#path]
	local oldValue = globalData[lastKey]
	globalData[lastKey] = newValue
	return oldValue
end

function DataServiceClient._tableInsert(
	self: DataServiceClient,
	path: Path,
	newValue: any,
	index: number?,
	global: boolean?
)
	local tbl = (global and self:getGlobal(path)) or self:get(path)
	if type(tbl) ~= "table" then
		return
	end

	local oldValue
	if index then
		oldValue = tbl[index]
		table.insert(tbl, index, newValue)
	else
		table.insert(tbl, newValue)
	end

	return oldValue
end

function DataServiceClient._tableRemove(self: DataServiceClient, path: Path, index: number, global: boolean?)
	local tbl = (global and self:getGlobal(path)) or self:get(path)
	if type(tbl) ~= "table" then
		return
	end

	local removedValue = table.remove(tbl, index)
	return removedValue
end

function DataServiceClient.tableInserted(
	self: DataServiceClient,
	path: Path,
	newValue: any,
	index: number?,
	global: boolean?
)
	local oldValue = self:_tableInsert(path, newValue, index, global)
	local signalTarget = (global and self._globalChangedSignals) or self._changedSignals

	local stringPath = pathToString(path)
	if signalTarget[stringPath] then
		signalTarget[stringPath]:Fire(newValue, oldValue, index)
	end
end

function DataServiceClient.tableRemoved(self: DataServiceClient, path: Path, index: number, global: boolean?)
	local removedValue = self:_tableRemove(path, index, global)
	local signalTarget = (global and self._globalChangedSignals) or self._changedSignals

	local stringPath = pathToString(path)
	if signalTarget[stringPath] then
		signalTarget[stringPath]:Fire(index, removedValue)
	end
end

function DataServiceClient.dataChanged(self: DataServiceClient, path: Path, newValue: any)
	local oldValue = self:_set(path, newValue)

	local stringPath = pathToString(path)
	if self._changedSignals[stringPath] then
		self._changedSignals[stringPath]:Fire(newValue, oldValue)
	end
end

function DataServiceClient.getDataChangedSignal(self: DataServiceClient, path: Path): Signal.Signal<any, any>
	local stringPath = pathToString(path)
	if self._changedSignals[stringPath] then
		return self._changedSignals[stringPath]
	else
		local signal = Signal.new()
		self._changedSignals[stringPath] = signal
		return signal
	end
end

function DataServiceClient.globalDataChanged(self: DataServiceClient, path: Path, newValue: any)
	if not self._globalData then
		self._globalData = self.networker:fetch("getGlobal") :: { any }
	end
	local oldValue = self:_setGlobal(path, newValue)

	local stringPath = pathToString(path)
	if self._globalChangedSignals[stringPath] then
		self._globalChangedSignals[stringPath]:Fire(newValue, oldValue)
	end
end

function DataServiceClient.getGlobalDataChangedSignal(self: DataServiceClient, path: Path): Signal.Signal<any, any>
	local stringPath = pathToString(path)
	if self._globalChangedSignals[stringPath] then
		return self._globalChangedSignals[stringPath]
	else
		local signal = Signal.new()
		self._globalChangedSignals[stringPath] = signal
		return signal
	end
end

export type DataServiceClient = typeof(DataServiceClient) & {
	networker: Networker.Client,
	_data: Data,
	_globalData: { any },
	_changedSignals: { [string]: Signal.Signal<any, any> },
	_globalChangedSignals: { [string]: Signal.Signal<any, any> },
}

return DataServiceClient :: DataServiceClient

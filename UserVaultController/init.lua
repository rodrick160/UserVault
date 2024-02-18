-- UserVaultController
-- Quantum Maniac
-- Feb 17 2024

--\\ Dependencies //--

local RunService = game:GetService("RunService")
if not RunService:IsClient() then
	return {}
end

local Fusion = require(script.Parent.Fusion)
local Knit = require(script.Parent.Knit)
local Signal = require(script.Parent.Signal)

local UserVaultService

local Computed = Fusion.Computed
local Value = Fusion.Value

--\\ Constants //--

--[[
	Prints debug information
	Level 0: Disabled
	Level 1: Prints info when updating data
	Level 2: Prints info when data is accessed externally
	Level 3: Prints local data state object changes
]]
local DEBUG_VERBOSE_LEVEL = 0

--\\ Module //--

local UserVaultController = Knit.CreateController {
	Name = "UserVaultController"
}

--\\ Init //--

function UserVaultController:KnitInit()
	UserVaultService = Knit.GetService("UserVaultService")
end

--\\ Types //--

type Signal = Signal.Signal
type Computed<T> = Fusion.Computed<T>
type Value<T> = Fusion.Value<T>

--\\ Private //--

local playerDataReady = Value(false)
local playerData = {}
local dataStateValues: {[string]: Value<any>} = {}

local function debugPrint(level: number, ...: any...)
	if level > DEBUG_VERBOSE_LEVEL then return end

	local scriptName, lineNumber = debug.info(coroutine.running(), 1, "sl")
	scriptName = scriptName:match("%w+$")

	print(`[{scriptName}: {lineNumber}]:\n`, ...)
end

--\\ Public //--

--[[
	Returns a read-only accessor version of the player data table.
	This table is automatically replicated from the server.

		local playerData = UserVaultController:GetPlayerData()
		print("I have " .. playerData.Coins .. " coins!)
]]
function UserVaultController:GetPlayerData<T>(key: string, defaultValue: T): Computed<T>
	debugPrint(2, `Getting player data (key = {key}, defaultValue = {defaultValue})`)
	local value = dataStateValues[key] or Value(playerData[key])
	dataStateValues[key] = value

	return Computed(function(use)
		return if use(playerDataReady) then use(value) else defaultValue
	end)
end

function UserVaultController:KnitStart()
	debugPrint(1, `Retrieving player data`)
	-- Get client copy of the player data table and maintain it
	UserVaultService:GetPlayerData()
	:andThen(function(retrievedPlayerData)
		playerData = retrievedPlayerData

		debugPrint(1, `Player data retrieved:`, playerData)
		UserVaultService.DataChanged:Connect(function(changes)
			for key, newValue in changes do
				debugPrint(1, `Player data changed: (index = {key}, newValue = {newValue})`)
				playerData[key] = newValue
				if dataStateValues[key] then
					debugPrint(3, `Data state value updated`)
					dataStateValues[key]:set(newValue)
				end
			end
		end)

		for key, stateValue in dataStateValues do
			stateValue:set(playerData[key])
		end

		debugPrint(1, `Player data ready`)
		playerDataReady:set(true)
	end)
end

--\\ Return //--

return UserVaultController
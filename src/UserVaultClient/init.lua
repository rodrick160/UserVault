-- UserVaultClient
-- Quantum Maniac
-- Feb 19 2024

--[[
	 ____ ___                  ____   ____            .__   __
	|    |   \______ __________\   \ /   /____   __ __|  |_/  |
	|    |   /  ___// __ \_  __ \   Y   /\__  \ |  |  \  |\   __\
	|    |  /\___ \\  ___/|  | \/\     /  / __ \|  |  /  |_|  |
	|______//____  >\___  >__|    \___/  (____  /____/|____/__|
	             \/     \/                    \/

	===============================================
		https://github.com/rodrick160/UserVault
	===============================================

	UserVaultClient allows the client to access their own player data and interact with it in various ways.
]]

--\\ Dependencies //--

local RunService = game:GetService("RunService")
if not RunService:IsClient() then
	return {}
end

local Comm = require(script.Parent.Parent.Comm).ClientComm
local Fusion2 = require(script.Parent.Parent.Fusion2)
local Fusion3 = require(script.Parent.Parent.Fusion3)
local Promise = require(script.Parent.Parent.Promise)
local Signal = require(script.Parent.Parent.Signal)
local TableUtil = require(script.Parent.Parent.TableUtil)

--\\ Constants //--

local DEFAULT_CONFIG: UserVaultConfig = {
	VerboseLevel = 0,
	UseFusion3 = false,
}

--\\ Module //--

local UserVaultClient = {}

--\\ Types //--

type UserVaultConfig = {
	VerboseLevel: number,
	UseFusion3: boolean,
}

type Computed<T> = Fusion2.Computed<T> | Fusion3.Computed<T>
type Value<T> = Fusion2.Value<T> | Fusion3.Value<T>

type Promise = typeof(Promise.new())

type Signal = Signal.Signal

--\\ Private //--

local currentConfig: UserVaultConfig

local dataReady = false
local dataReadyValue: Value<boolean>
local dataReadySignal = Signal.new()
local dataReadySignalExternal = Signal.new()
dataReadySignal:Connect(function()
	dataReadySignalExternal:Fire()	-- Make sure the data ready signal cant be fired from outside the module
end)
local dataChangedSignals: {[string]: Signal} = {}

local data = {}
local dataStateValues = {}
local dataStateComputeds = {}
local started = false

local function debugPrint(level: number, ...: any...)
	if level > currentConfig.VerboseLevel then return end

	local scriptName, lineNumber = debug.info(coroutine.running(), 2, "sl")
	scriptName = scriptName:match("%w+$")

	print(`[{scriptName}: {lineNumber}]:\n`, ...)
end

local function checkStarted()
	if not started then
		error("Must call UserVaultClient.Start() first.", 3)
	end
end

local function waitForDataReady()
	if not dataReady then
		debugPrint(3, `Waiting for data ready`)
		dataReadySignal:Wait()
	end
	debugPrint(3, `Data ready`)
end

--\\ Public //--

--[[
	# [GetState](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultClient/DOCUMENTATION.md#getstate)

	## Description
	Returns a read-only state object representing a value in the player's data profile.
	The value of the state object is updated automatically.

	## Parameters
	- `key: string` - The key of the value to retrieve.
	- `defaultValue: any` (optional) - A default value for the state object to resolve to.
		This value will be used until the player profile has been loaded and received by the client, at which time the true value will take its place.

	## Return Value
	Returns a `Computed` state object from the [Fusion](https://elttob.uk/Fusion) library.

	## Usage Examples
	```lua
		local coinsValue = UserVault.GetState("Coins", 0)
		local coinsLabel = Fusion.New "TextLabel" {
			Text = coinsValue
		}
	```
]]
function UserVaultClient.GetState(key: string, defaultValue: any): Computed<any>
	checkStarted()

	local Value = if currentConfig.UseFusion3 then Fusion3.Value else Fusion2.Value

	debugPrint(2, `Getting state (key = {key}, defaultValue = {defaultValue})`)
	local value = dataStateValues[key] or Value(data[key])
	dataStateValues[key] = value

	if defaultValue == nil then
		debugPrint(3, `No default value provided`)
		local computed = dataStateComputeds[key]
		if not computed then
			debugPrint(3, `Generating new Computed`)
			if currentConfig.UseFusion3 then
				debugPrint(3, `Generating Fusion 0.3 Computed`)
				computed = Fusion3.Computed(function(use)
					return use(value)
				end)
			else
				debugPrint(3, `Generating Fusion 0.2 Computed`)
				computed = Fusion2.Computed(function()
					return value:get()
				end)
			end
			dataStateComputeds[key] = computed
		end
		return computed
	else
		debugPrint(3, `Default value provided, generating new Computed`)
		if currentConfig.UseFusion3 then
			debugPrint(3, `Returning Fusion 0.3 Computed`)
			return Fusion3.Computed(function(use)
				return if use(dataReadyValue) then use(value) else defaultValue
			end)
		else
			debugPrint(3, `Returning Fusion 0.2 Computed`)
			return Fusion2.Computed(function()
				return if dataReadyValue:get() then value:get() else defaultValue
			end)
		end
	end
end

--[[
	# [GetValue](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultClient/DOCUMENTATION.md#getvalue)

	## Description
	Retrieves specified values from the client's profile.

	## Parameters
	This function supports three parameter formats:

	- `GetValue(keys: {string})`: Uses an array of keys to retrieve specific values.
		- `keys: {string}` - The data keys to retrieve.

	- `GetValue(...: string)`: Uses a variable number of arguments to specify the data keys.
		- `...: string` - The data keys to retrieve.

	- `GetValue()`: Does not retrieve any values, but can be used to check if the profile has loaded.

	## Return Value
	Returns a `Promise` that resolves with the requested values.
	When `keys` is an array, the promise resolves with a dictionary mapping each key to its value.
	When using varargs, the promise resolves with the values directly.

	## Usage Examples

	### Array Example
	Retrieve values using an array of keys `"Coins"` and `"Level"`.
	The promise resolves with a dictionary containing the values for these keys.
	```lua
	UserVault.GetValue({"Coins", "Level"}):andThen(function(data)
		print(`Local player has {data.Coins} coins and is level {data.Level}.`)
	end)
	```

	### Vararg Example
	Retrieve values using varargs `"Coins"` and `"Level"`.
	The promise resolves with the values for these keys in order.
	```lua
	UserVault.GetValue("Coins", "Level"):andThen(function(coins, level)
		print(`Local player has {coins} coins and is level {level}.`)
	end)
	```

	> [!TIP]
	> GetValues() is a valid alias for GetValue()
]]
function UserVaultClient.GetValue(...: {string} | string): Promise
	checkStarted()

	debugPrint(2, `Getting values:`, ...)
	local args = {...}

	local isTable = typeof(args[1]) == "table"
	local keys = if isTable then args[1] else args
	return Promise.new(function(resolve)
		waitForDataReady()

		local values = {}
		for _, key in keys do
			if isTable then
				values[key] = data[key]
			else
				values[#values + 1] = data[key]
			end
		end

		if isTable then
			debugPrint(3, `Returning table`)
			resolve(values)
		else
			debugPrint(3, `Returning tuple`)
			resolve(table.unpack(values))
		end
	end)
end
UserVaultClient.GetValues = UserVaultClient.GetValue

--[[
	# [GetValueChangedSignal](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultClient/DOCUMENTATION.md#getvaluechangedsignal)

	## Description
	Creates and returns a `Signal` that is fired when a specified key's value changes in the client's profile.
	The signal passes the new and previous values of the observed key.

	## Parameters
	- `key: string` - The profile key to monitor for changes.

	## Return Value
	Returns a `Promise` that resolves with a `Signal` object.
	The resolved signal can then be connected to functions that will be called with the new and previous values of the key whenever it changes.

	## Usage Examples
	```lua
	UserVault.GetValueChangedSignal("Coins")
	:andThen(function(signal)
		signal:Connect(function(newValue, oldValue)
			print(`Local player's coins changed from {oldValue} to {newValue}!`)
		end)
	end)
	```

	> [!NOTE]
	> The Signal is only available after the player's profile has been successfully loaded.
	> It does not fire for the initial load of the profile's data.
	> For initial data handling, other methods like `BindToValue()` should be considered.
]]
function UserVaultClient.GetValueChangedSignal(key: string): Signal
	checkStarted()

	debugPrint(2, `Getting value changed signal for {key}`)

	local signal = dataChangedSignals[key]
	if not signal then
		debugPrint(3, `Creating new data changed signal`)
		signal = Signal.new()
		dataChangedSignals[key] = signal
	end

	return signal
end

--[[
	# [BindToValue](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultClient/DOCUMENTATION.md#bindtovalue)

	## Description
	Invokes a callback function with the current value of a specified key immediately upon binding, and then again each time that key's value
	updates in the client's profile.

	## Parameters
	- `key: string` - The key within the client's profile to watch for changes.
	- `callback: (newValue: any, oldValue: any?) -> ()` - A callback function that is executed with the new value of the key and,
		for updates after the initial call, the previous value. For the initial invocation, `oldValue` will not be provided.

	## Return Value
	Returns a `Promise` that resolves once the callback has been registered and invoked with the current value of the key.

	## Usage Examples
	```lua
	-- Bind to monitor and reflect changes in 'Coins' in a `TextLabel`.
	UserVault.BindToValue("Coins", function(newValue, oldValue)
		if oldValue then
			print(`Coins updated from {oldValue} to {newValue}`)
		else
			print(`Initial coin value: {newValue}`)
		end
		textLabel.Text = newValue
	end)
	```

	> [!NOTE]
	> The immediate invocation of the callback provides an opportunity to initialize any dependent data or UI elements with the current value of the
	> specified key. Subsequent invocations facilitate real-time updates, enabling dynamic content adjustments based on the player's data changes.
]]
function UserVaultClient.BindToValue(key: string, callback: (any) -> ())
	checkStarted()

	debugPrint(2, `Binding to value {key}`)

	UserVaultClient.GetValue(key)
	:andThen(function(value)
		UserVaultClient.GetValueChangedSignal(key):Connect(callback)
		callback(value)
	end)
end

--[[
	# [DataReady](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultClient/DOCUMENTATION.md#dataready)

	## Description
	Returns a boolean flag indicating if the client's data is ready for consumption.

	> [!TIP]
	> Pairs well with `GetDataReadySignal()`
]]
function UserVaultClient.DataReady(): boolean
	checkStarted()

	debugPrint(3, `Getting data ready flag`)
	return dataReady
end

--[[
	# [GetDataReadySignal](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultClient/DOCUMENTATION.md#getdatareadysignal)

	## Description
	Returns a `Signal` which fires when the client's data becomes ready for consuption.

	> [!WARNING]
	> The returned signal will not fire if the function is called after the data is already ready.
	> Use `DataReady()` before waiting for this signal.
]]
function UserVaultClient.GetDataReadySignal(): Signal
	return dataReadySignalExternal
end

--[[
	# [Start](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultClient/DOCUMENTATION.md#start)

	## Description
	Initializes UserVaultClient with the provided configuration. This function is essential for setting up the module's behavior according to your game's
	needs and should be called once before starting Knit.

	## Parameters
	- `config: table` - Configuration options for UserVaultClient.
		- `VerboseLevel: number` (optional) - Controls the level of debug information output by the module. Useful for debugging and monitoring module
			operations.
			- `0` - No debug information. Use this level for production environments to keep the logs clean.
			- `1` - Logs updates to data, useful for tracking dynamic changes during development.
			- `2` - Logs external data access, helping identify unexpected interactions.
			- `3` - The most verbose level, logging all code paths taken within the module. Best used for troubleshooting specific issues.
		- `UseFusion3: boolean` (optional) - Determines whether Fusion objects adhere to v0.3.0 (true) or default to v0.2.0 (false).
			Choosing v0.3.0 may offer enhanced features or performance improvements tailored to specific project requirements.

	## Usage Examples
	```lua
	UserVaultClient.Start({
		VerboseLevel = 2,
		UseFusion3 = true
	})
	```

	> [!WARNING]
	> It's critical to invoke `Start()` before initializing other modules, such as Knit, to ensure UserVault is fully configured and operational,
	> preventing dependency or initialization conflicts.
	> This order is crucial for maintaining a stable and predictable initialization sequence for your game's services.

	> [!IMPORTANT]
	> If you are utilizing Fusion in your project, it's crucial to configure the UserVaultClient to use the same Fusion version as your project.
	> This ensures compatibility and prevents issues related to version mismatches. Use the `UseFusion3` configuration option to specify whether
	> Fusion v0.3.0 or an earlier version is in use. Failing to align the Fusion version used by UserVault with your project's Fusion version
	> can lead to errors.
]]
function UserVaultClient.Start(config: UserVaultConfig)
	if started then
		error("Cannot call UserVaultClient.Start() more than once.", 2)

	elseif config == nil then
		error("UserVaultClient.Start() must be given a config table.", 2)
	elseif typeof(config) ~= "table" then
		error("config must be a table.", 2)

	elseif config.UseFusion3 ~= nil and typeof(config.UseFusion3) ~= "boolean" then
		error("config.UseFusion3 must be nil or a boolean.", 2)

	elseif config.VerboseLevel ~= nil then
		if typeof(config.VerboseLevel) ~= "number" or
		math.floor(config.VerboseLevel) ~= config.VerboseLevel or
		config.VerboseLevel < 1 then
			error("config.VerboseLevel must be nil or a positive integer.", 2)
		end
	end

	started = true

	currentConfig = TableUtil.Reconcile(config, DEFAULT_CONFIG)
	TableUtil.Lock(currentConfig)

	local userVaultComm = Comm.new(game.ReplicatedStorage, true, "UserVaultComm")
	userVaultComm:BuildObject()

	dataReadyValue = if currentConfig.UseFusion3 then Fusion3.Value(false) else Fusion2.Value(false)

	debugPrint(1, `Retrieving player data`)
	userVaultComm:GetFunction("GetPlayerData")()
	:andThen(function(retrievedPlayerData)
		data = retrievedPlayerData

		debugPrint(1, `Player data retrieved:`, data)
		userVaultComm:GetSignal("DataChanged"):Connect(function(changes)
			for key, newValue in changes do
				debugPrint(1, `Player data changed: (index = {key}, newValue = {newValue})`)
				local oldValue = data[key]
				data[key] = newValue
				if dataStateValues[key] then
					debugPrint(3, `Data state value updated`)
					dataStateValues[key]:set(newValue)
				end
				if dataChangedSignals[key] then
					dataChangedSignals[key]:Fire(newValue, oldValue)
				end
			end
		end)

		for key, stateValue in dataStateValues do
			stateValue:set(data[key])
		end

		debugPrint(1, `Player data ready`)
		dataReady = true
		dataReadyValue:set(true)
		dataReadySignal:Fire()
	end)
end

--\\ Return //--

return UserVaultClient
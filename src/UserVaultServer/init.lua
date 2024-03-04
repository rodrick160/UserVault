-- UserVaultServer
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

	UserVaultServer is responsible for loading, releasing, and accessing player data on the server.
	It should be started before any dependent modules (see `UserVaultServer.Start()`).
]]

--\\ Dependencies //--

local RunService = game:GetService("RunService")

local Comm = require(script.Parent.Parent.Comm).ServerComm
local ProfileService = require(script.Parent.Parent.ProfileService)
local Promise = require(script.Parent.Parent.Promise)
local Signal = require(script.Parent.Parent.Signal)
local TableUtil = require(script.Parent.Parent.TableUtil)
local Trove = require(script.Parent.Parent.Trove)

--\\ Constants //--

local DEFAULT_CONFIG: UserVaultConfig = {
	VerboseLevel = 0,
	DebugUseMock = true,
	WarnNilUpdate = true,
	ProfileStoreIndex = "PlayerData",
}

local PROFILE_KEY_FORMAT = "Player_%d"

--\\ Module //--

local UserVaultServer = {}

--\\ Types //--

type UserVaultConfig = {
	VerboseLevel: number,
	DebugUseMock: boolean,
	WarnNilUpdate: boolean,
	ProfileStoreIndex: string,
	PlayerDataTemplate: {Version: number, Shared: table, Server: table},
	PlayerDataUpdateFunctions: {[number]: (table) -> ()},
}

type PlayerCache = {
	Player: Player,
	Profile: Profile,
	ValueChangedSignals: {[string]: Signal},
	DataChangeQueue: {[string]: DataChange},
	ProcessDataQueueSignal: Signal,
	ReadyForHop: boolean,
}
type DataChange = {
	Old: any,
	New: any,
}

type Profile = ProfileService.Profile<table>
type ProfileStore = ProfileService.ProfileStore

type Promise = typeof(Promise)
type Signal = Signal.Signal

--\\ Private //--

local currentConfig: UserVaultConfig
local profileStore: ProfileStore
local started = false

local playerCaches: {[Player]: PlayerCache} = {}
local playerLoadedSignals: {[Player]: Signal} = {}
local hopReadySignal = Signal.new()

local userVaultComm
local dataChangedRemoteSignal

--[[
	Prints if and only if the passed level is not greater than the currently set verbose level
]]
local function debugPrint(level: number, ...: any...)
	if level > currentConfig.VerboseLevel then return end

	local scriptName, lineNumber = debug.info(coroutine.running(), 2, "sl")
	scriptName = scriptName:match("%w+$")

	print(`[{scriptName}: {lineNumber}]:\n`, ...)
end

local function checkStarted()
	if not started then
		error("Must call UserVaultServer.Start() first.", 3)
	end
end

--[[
	Yields until the given player's profile loads or until they are no longer in the game.
	Returns immediately if either of these conditions are already true.
]]
local function waitForPlayerLoaded(player: Player)
	debugPrint(4, `Waiting for {player} to load`)

	-- Return immediately if the player is not in the game or if their cache already exists
	if not player or not player.Parent then
		debugPrint(5, `Player not in-game`)
		return
	end
	if playerCaches[player] then
		debugPrint(5, `Player data already loaded.`)
		return
	end

	-- Create a player loaded signal and wait for it
	local signal = playerLoadedSignals[player]
	if not signal then
		debugPrint(5, `Creating player loaded signal.`)
		signal = Signal.new()
		playerLoadedSignals[player] = signal
	end
	signal:Wait()
end

--[[
	Wrapper function.
	Errors if the callback function yields.
]]
local function assertNoYield(callback: (any...) -> any..., ...: any...): any...
	debugPrint(4, `Callback running with no-yield assertion`)

	local thread = coroutine.create(callback)
	local returnValues = table.pack(coroutine.resume(thread, ...))
	table.remove(returnValues, 1)

	if coroutine.status(thread) ~= "dead" then
		task.cancel(thread)
		debugPrint(4, `Failed`)
		error("Callback function illegally yielded while attempting to modify data.", 3)
	end

	debugPrint(4, `Success`)
	return table.unpack(returnValues)
end

--[[
	Retrives a value from the player profile.
]]
local function getValue(playerCache: PlayerCache, key: string, readOnly: boolean?): Promise
	debugPrint(4, `Getting value`)

	return Promise.new(function(resolve, reject)
		local value
		if currentConfig.PlayerDataTemplate.Shared[key] ~= nil then
			value = playerCache.Profile.Data.Shared[key]
			debugPrint(5, `Shared value: {value}`)
		elseif currentConfig.PlayerDataTemplate.Server[key] ~= nil then
			value = playerCache.Profile.Data.Server[key]
			debugPrint(5, `Server value: {value}`)
		else
			debugPrint(4, `Failed`)
			reject(`Attempt to index profile with invalid key '{key}'`)
			return
		end
		if readOnly and typeof(value) == "table" then
			value = TableUtil.Lock(TableUtil.Copy(value, true))
			debugPrint(5, `table value detected, made read-only copy`)
		end
		debugPrint(4, `Success`)
		resolve(value)
	end)
end

--[[
	Assigns a value in the player profile.
]]
local function setValue(playerCache: PlayerCache, key: string, value: any): Promise
	debugPrint(4, `Setting value`)

	return Promise.new(function(resolve, reject)
		local oldValue
		if currentConfig.PlayerDataTemplate.Shared[key] ~= nil then
			oldValue = playerCache.Profile.Data.Shared[key]
			playerCache.Profile.Data.Shared[key] = value
			debugPrint(5, `Shared value: {oldValue}`)

			local change = playerCache.DataChangeQueue[key]
			if change then
				debugPrint(5, `Existing change replication found`)
				if change.Old == value then
					debugPrint(5, `Removing existing change replication`)
					playerCache.DataChangeQueue[key] = nil
				else
					debugPrint(5, `Modifying exising change replication`)
					change.New = value
				end
			else
				debugPrint(5, `Queueing new change replication`)
				if not next(playerCache.DataChangeQueue) then
					playerCache.ProcessDataQueueSignal:FireDeferred()
				end

				change = {Old = oldValue, New = value}
				playerCache.DataChangeQueue[key] = change
			end

		elseif currentConfig.PlayerDataTemplate.Server[key] ~= nil then
			oldValue = playerCache.Profile.Data.Server[key]
			playerCache.Profile.Data.Server[key] = value
			debugPrint(5, `Server value: {oldValue}`)
		else
			debugPrint(4, `Failed`)
			reject(`Attempt to index profile with invalid key '{key}'`)
			return
		end

		if playerCache.ValueChangedSignals[key] then
			debugPrint(5, `Firing data changed signal`)
			playerCache.ValueChangedSignals[key]:Fire(value, oldValue)
		end

		debugPrint(4, `Success`)
		resolve(value)
	end)
end

--[[
	Updates the data table to the newest version using the update functions, one version at a time.
]]
local function updateProfileData(data: table)
	while currentConfig.PlayerDataTemplate.Version > data.Version do
		local updateFunction = currentConfig.PlayerDataUpdateFunctions[data.Version]
		if not updateFunction then
			error(`Missing update function for player data version {data.Version}`)
		end

		local oldVersion = data.Version
		updateFunction(data)
		data.Version = oldVersion + 1
	end
end

--[[
	Loads the player's profile upon joining the game.
]]
local function loadProfile(player: Player)
	debugPrint(1, `Loading profile for {player} ({player.UserId})`)

	local profile = profileStore:LoadProfileAsync(PROFILE_KEY_FORMAT:format(player.UserId))

	if profile ~= nil then
		debugPrint(1, `Profile loaded`)

		updateProfileData(profile.Data)
		profile:AddUserId(player.UserId) -- GDPR compliance
		profile:Reconcile() -- Fill in missing variables from ProfileTemplate

		profile:ListenToRelease(function()
			debugPrint(1, `Profile released for player {player}`)
			local playerCache = playerCaches[player]
			if playerCache then
				debugPrint(5, `Player cache found`)
				for _, signal in playerCache.ValueChangedSignals do
					signal:Destroy()
				end
				playerCache.ProcessDataQueueSignal:Destroy()
				playerCaches[player] = nil
			end

			-- The profile could've been loaded on another Roblox server:
			if player.Parent and not player:GetAttribute("DontKickOnRelease") then
				debugPrint(5, `Kicking player {player}`)
				player:Kick()
			end
		end)

		profile:ListenToHopReady(function()
			debugPrint(1, `Hop ready for player {player}`)
			local playerCache = playerCaches[player]
			if playerCache then
				debugPrint(4, `Player cache found`)
				playerCache.ReadyForHop = true
			end
			hopReadySignal:Fire()
		end)

		if player.Parent then
			debugPrint(5, `Player still in-game`)
			-- A profile has been successfully loaded:
			local playerCache: PlayerCache = {
				Player = player,
				Profile = profile,
				ValueChangedSignals = {},
				DataChangeQueue = {},
				ProcessDataQueueSignal = Signal.new(),
				ReadyForHop = false
			}

			playerCache.ProcessDataQueueSignal:Connect(function()
				debugPrint(5, `Processing data queue for player {player}`)
				local changes = {}
				for key, change in playerCache.DataChangeQueue do
					changes[key] = change.New
				end
				dataChangedRemoteSignal:Fire(player, changes)
				playerCache.DataChangeQueue = {}
			end)

			playerCaches[player] = playerCache
		else
			debugPrint(5, `Player no longer in-game`)
			-- Player left before the profile loaded:
			profile:Release()
		end
	else
		debugPrint(1, `Failed to load profile`)
		-- The profile couldn't be loaded possibly due to other
		-- Roblox servers trying to load this profile at the same time:
		player:Kick()
	end

	-- Release any threads waiting for the player data to load.
	if playerLoadedSignals[player] then
		debugPrint(5, `Firing player loaded signal`)
		playerLoadedSignals[player]:Fire()
		task.defer(function()
			playerLoadedSignals[player]:Destroy()
			playerLoadedSignals[player] = nil
		end)
	end
end

--\\ Public //--

--[[
	# [GetValue](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultServer/DOCUMENTATION.md#getvalue)

	## Description
	Retrieves specified values from the player's profile.

	## Parameters
	This function supports two parameter formats:

	- `GetValue(player: Player, keys: {string})`: Uses an array of keys to retrieve specific player data.
		- `player: Player` - The target player.
		- `keys: {string}` - The data keys to retrieve.

	- `GetValue(player: Player, ...: string)`: Uses a variable number of arguments to specify the data keys.
		- `player: Player` - The target player.
		- `...: string` - The data keys to retrieve.

	## Return Value
	Returns a `Promise` that:
	- Resolves with the requested player data on success. When `keys` is an array, the promise resolves with a dictionary mapping each key to its value.
		When using varargs, the promise resolves with the values directly.
	- Rejects if the player profile cannot be loaded.

	## Usage Examples

	### Array Example
	Retrieve values using an array of keys `"Coins"` and `"Level"`.
	The promise resolves with a dictionary containing the values for these keys.
	```lua
	UserVault.GetValue(player, {"Coins", "Level"}):andThen(function(data)
		print(`Player {player.DisplayName} has {data.Coins} coins and is level {data.Level}.`)
	end, function()
		print(`Player {player.DisplayName}'s data failed to load!`)
	end)
	```

	### Vararg Example
	Retrieve values using varargs `"Coins"` and `"Level"`.
	The promise resolves with the values for these keys in order.
	```lua
	UserVault.GetValue(player, "Coins", "Level"):andThen(function(coins, level)
		print(`Player {player.DisplayName} has {coins} coins and is level {level}.`)
	end, function()
		print(`Player {player.DisplayName}'s data failed to load!`)
	end)
	```

	> [!TIP]
	> GetValues() is a valid alias for GetValue()
]]
function UserVaultServer.GetValue(player: Player, ...: {string} | string): Promise
	checkStarted()
	assert(typeof(player) == "Instance" and player:IsA("Player"), "player must be a Player.")

	local args = {...}
	local isTable = typeof(args[1]) == "table"
	local keys = if isTable then args[1] else args
	assert(keys[1] ~= nil, "must pass at least one key.")

	for _, key in keys do
		assert(typeof(key) == "string", "keys must be strings.")
	end

	debugPrint(3, `Getting values for {player}:`, ...)

	return Promise.new(function(resolve, reject)
		debugPrint(5, `Waiting for player data`)
		waitForPlayerLoaded(player)

		local playerCache = playerCaches[player]
		if playerCache and playerCache.Profile:IsActive() then
			debugPrint(5, `Player data found`)
			local values = {}
			for _, key in keys do
				local value = getValue(playerCache, key, true):expect()
				if isTable then
					values[key] = value
				else
					values[#values + 1] = value
				end
			end
			if isTable then
				debugPrint(5, `Returning table`)
				resolve(values)
			else
				debugPrint(5, `Returning tuple`)
				resolve(table.unpack(values))
			end
		else
			debugPrint(5, `Player data not found`)
			reject(`Failed to retrieve profile for player {player}.`)
		end
	end)
end
UserVaultServer.GetValues = UserVaultServer.GetValue

--[[
	# [SetValue](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultServer/DOCUMENTATION.md#setvalue)

	## Description
	Sets a specified value for a key in the player's profile.

	## Parameters
	- `player: Player` - The player whose profile is being modified.
	- `key: string` - The key within the profile to update.
	- `value: any` - The new value to assign to the key.

	## Return Value
	Returns a `Promise` that:
	- Resolves when the value is successfully updated in the player's profile.
	- Rejects if updating the player profile fails.

	## Usage Examples
	```lua
	UserVault.SetValue(player, "Coins", 500):andThen(function()
		print(`Successfully updated {player.DisplayName}'s coins to 500.`)
	end, function()
		print(`Failed to update {player.DisplayName}'s coins to 500.`)
	end)
	```
]]
function UserVaultServer.SetValue(player: Player, key: string, value: any): Promise
	checkStarted()
	assert(typeof(player) == "Instance" and player:IsA("Player"), "player must be a Player.")
	assert(typeof(key) == "string", "key must be a string.")

	debugPrint(2, `Setting value for {player} ({key} = {value})`)

	return Promise.new(function(resolve, reject)
		debugPrint(5, `Waiting for player data`)
		waitForPlayerLoaded(player)

		local playerCache = playerCaches[player]
		if playerCache and playerCache.Profile:IsActive() then
			debugPrint(5, `Player data found`)
			resolve(setValue(playerCache, key, value))
		else
			debugPrint(5, `Player data not found`)
			reject(`Failed to retrieve profile for player {player}.`)
		end
	end)
end

--[[
	# [UpdateValue](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultServer/DOCUMENTATION.md#updatevalue)

	## Description
	Updates a specified value for a key in the player's profile by applying a callback function.
	This function allows for complex transformations of existing data.

	## Parameters
	- `player: Player` - The player whose profile is being updated.
	- `key: string` - The key to be updated within the profile.
	- `callback: (value: any) -> any` - A function that receives the current value and returns the updated value.
		This callback is used to transform the value.

	> [!CAUTION]
	> When working with table values, ensure to return the modified table from the callback to avoid unintended `nil` assignments.

	> [!CAUTION]
	> The callback function cannot yield under any circumstances, as this could create a race condition. If the callback function yields,
	> the thread will be killed and the promise will reject.

	## Return Value
	Returns a `Promise` that:
	- Resolves with the newly computed value after successfully updating it in the player's profile.
		This ensures that the calling code can immediately use the updated value.
	- Rejects if the update process fails.

	## Usage Examples
	```lua
	UserVault.UpdateValue(player, "Coins", function(coins)
		return coins + 500
	end):andThen(function(newCoins)
		print(`Successfully increased {player.DisplayName}'s coins to {newCoins}.`)
	end, function()
		print(`Failed to update {player.DisplayName}'s coins.`)
	end)
	```
]]
function UserVaultServer.UpdateValue(player: Player, key: string, callback: (value: any) -> any): Promise
	checkStarted()
	assert(typeof(player) == "Instance" and player:IsA("Player"), "player must be a Player.")
	assert(typeof(key) == "string", "key must be a string.")
	assert(typeof(callback) == "function", "callback must be a function.")

	debugPrint(2, `Updating value for {player} ({key})`)

	return Promise.new(function(resolve, reject)
		debugPrint(5, `Waiting for player data`)
		waitForPlayerLoaded(player)

		local playerCache = playerCaches[player]
		if playerCache and playerCache.Profile:IsActive() then
			debugPrint(5, `Player data found`)
			resolve(getValue(playerCache, key, false)
			:andThen(function(oldValue)
				local newValue = assertNoYield(callback, oldValue)
				if currentConfig.WarnNilUpdate and newValue == nil then
					warn("UpdateValue callback returned a nil value\n", debug.traceback())
				end
				return setValue(playerCache, key, newValue)
			end))
		else
			debugPrint(5, `Player data not found`)
			reject(`Failed to retrieve profile for player {player}.`)
		end
	end)
end

--[[
	# [IncrementValue](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultServer/DOCUMENTATION.md#incrementvalue)

	## Description
	Increments a specified value for a key in the player's profile by a specific amount.
	Sugar for:
	```lua
	UserVault.UpdateValue(player, key, function(value)
		return value + increment
	end)
	```

	## Parameters
	- `player: Player` - The player whose profile is being updated.
	- `key: string` - The key to be updated within the profile.
	- `increment: number` - The amount to increment the value by.

	## Return Value
	Returns a `Promise` that:
	- Resolves with the newly computed value after successfully updating it in the player's profile.
	This ensures that the calling code can immediately use the updated value.
	- Rejects if the increment process fails.

	## Usage Examples
	```lua
	UserVault.IncrementValue(player, "Coins", 500):andThen(function(newCoins)
		print(`Successfully increased {player.DisplayName}'s coins to {newCoins}.`)
	end, function()
		print(`Failed to update {player.DisplayName}'s coins.`)
	end)
	```
]]
function UserVaultServer.IncrementValue(player: Player, key: string, increment: number): Promise
	checkStarted()
	assert(typeof(player) == "Instance" and player:IsA("Player"), "player must be a Player.")
	assert(typeof(key) == "string", "key must be a string.")
	assert(typeof(increment) == "number", "increment must be a number.")

	debugPrint(2, `Incrementing value for {player} ({key} += {increment})`)

	return UserVaultServer.UpdateValue(player, key, function(value)
		return value + increment
	end)
end

--[[
	# [GetValueChangedSignal](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultServer/DOCUMENTATION.md#getvaluechangedsignal)

	## Description
	Creates and returns a `Signal` that is fired when a specified key's value changes in the player's profile.
	This operation is dependent on the successful loading of the player's profile.
	The signal passes the new and previous values of the observed key.

	## Parameters
	- `player: Player` - The player whose profile changes are to be monitored.
	- `key: string` - The profile key to monitor for changes.

	## Return Value
	Returns a `Promise` that resolves with a `Signal` object.
	The resolved signal can then be connected to functions that will be called with the new and previous values of the key whenever it changes.
	The promise is rejected if the player's profile cannot be loaded.

	## Usage Examples
	```lua
	UserVault.GetValueChangedSignal(player, "Coins")
	:andThen(function(signal)
		signal:Connect(function(newValue, oldValue)
			print(`Player {player.DisplayName}'s coins changed from {oldValue} to {newValue}!`)
		end)
	end)
	:catch(function(error)
		print(`Player {player.DisplayName}'s data failed to load!`)
	end)
	```

	> [!NOTE]
	> The `Signal` only fires after the client's data has been successfully loaded.
	> It does not fire for the initial load of the client's data.
	> For initial data handling, other methods like directly retrieving the player's data upon profile load should be considered.
]]
function UserVaultServer.GetValueChangedSignal(player: Player, key: string): Promise
	checkStarted()
	assert(typeof(player) == "Instance" and player:IsA("Player"), "player must be a Player.")
	assert(typeof(key) == "string", "key must be a string.")

	debugPrint(3, `Getting value changed signal for {player} ({key})`)

	return Promise.new(function(resolve, reject)
		debugPrint(5, `Waiting for player data`)
		waitForPlayerLoaded(player)

		local playerCache = playerCaches[player]
		if playerCache and playerCache.Profile:IsActive() then
			debugPrint(5, `Player data found`)
			local signal = playerCache.ValueChangedSignals[key]
			if not signal then
				debugPrint(5, `Creating new data changed signal`)
				signal = Signal.new()
				playerCache.ValueChangedSignals[key] = signal
			end
			resolve(signal)
		else
			debugPrint(5, `Player data not found`)
			reject(`Failed to retrieve profile for player {player}.`)
		end
	end)
end

--[[
	# [BindToValue](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultServer/DOCUMENTATION.md#bindtovalue)

	## Description
	Invokes a callback function with the current value of a specified key immediately upon binding, and then again each time that key's value
	updates in the player's profile.

	## Parameters
	- `player: Player` - The player whose data is being monitored.
	- `key: string` - The key within the player's profile to watch for changes.
	- `callback: (newValue: any, oldValue: any?) -> ()` - A callback function that is executed with the new value of the key and,
		for updates after the initial call, the previous value. For the initial invocation, `oldValue` will not be provided.

	## Return Value
	Returns a `Promise` that:
	- Resolves once the callback has been successfully registered and invoked with the current value of the key.
	- Rejects if the player's profile cannot be loaded or the key does not exist.

	## Usage Examples
	```lua
	-- Bind to monitor and reflect changes in 'Coins' within the player's leaderstats.
	UserVault.BindToValue(player, "Coins", function(newValue, oldValue)
		if oldValue then
			print(`Coins updated from {oldValue} to {newValue}`)
		else
			print(`Initial coin value: {newValue}`)
		end
		player.leaderstats.Coins.Value = newValue
	end)
	```

	> [!NOTE]
	> The immediate invocation of the callback provides an opportunity to initialize any dependent data or UI elements with the current value of the
	> specified key. Subsequent invocations facilitate real-time updates, enabling dynamic content adjustments based on the player's data changes.
]]
function UserVaultServer.BindToValue(player: Player, key: string, callback: (newValue: any, oldValue: any?) -> ()): Promise
	checkStarted()
	assert(typeof(player) == "Instance" and player:IsA("Player"), "player must be a Player.")
	assert(typeof(key) == "string", "key must be a string.")
	assert(typeof(callback) == "function", "callback must be a function.")

	debugPrint(3, `Binding to {player}'s data ({key})`)

	return UserVaultServer.GetValue(player, key)
	:andThen(function(value)
		UserVaultServer.GetValueChangedSignal(player, key)
		:andThen(function(dataChangedSignal)
			dataChangedSignal:Connect(callback)
		end)
		callback(value)
	end)
end

--[[
	# [OnHopClear](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultServer/DOCUMENTATION.md#onhopclear)

	## Description
	Prepares a player's profile for teleportation by ensuring it is properly released and ready to be loaded in a new game instance. `OnHopClear` utilizes
	`Profile:ListenToHopReady()` from the ProfileService module to monitor and manage the profile's readiness for a hop. This function returns a promise that
	resolves once the profile is adequately prepared, optimizing the teleportation process, especially useful when navigating noticeable delays in profile
	loading after universe teleports.

	## Parameters
	- `player: Player` - The player whose profile is to be prepared for a hop.

	## Return Value
	Returns a `Promise` that:
	- Resolves when the player's profile has been successfully released and is ready for loading in a new game instance, facilitating seamless teleportation.
	- Rejects if the player leaves the game before the promise resolves. It is recommended to account for this scenario in your implementation to handle
		potential errors gracefully.

	## Usage Examples
	```lua
	UserVault.OnHopClear(player)
	:andThen(function()
		TeleportService:Teleport(placeId, {player})
	end, function()
		print("Player left before the profile could be cleared for hop.")
	end)
	```

	> [!TIP]
	> `OnHopClear` is particularly beneficial for managing profile readiness in scenarios with noticeable delays during teleportation between universe places.
	> The promise returned by this function not only signifies that the player's profile is ready for a new game instance but also provides a mechanism to
	> handle cases where a player may leave the game before teleportation can occur. Implementing error handling for promise rejection is crucial for
	> maintaining a robust teleportation process.
]]
function UserVaultServer.OnHopClear(player: Player): Promise
	checkStarted()
	assert(typeof(player) == "Instance" and player:IsA("Player"), "player must be a Player.")

	debugPrint(3, `Getting hop clear promise for {player}`)

	return Promise.new(function(resolve, reject, onCancel)
		local trove = Trove.new()
		if onCancel(function()
			debugPrint(5, `Canceling hop clear promise`)
			trove:Destroy()
		end) then
			return
		end

		local waitSignal = Signal.new()
		trove:Add(waitSignal)
		trove:Connect(hopReadySignal, function()
			waitSignal:Fire()
		end)
		trove:Connect(game.Players.PlayerRemoving, function(playerWhoLeft)
			waitSignal:Fire(playerWhoLeft)
		end)

		local playerCache = playerCaches[player]
		while not playerCache.ReadyForHop do
			local playerWhoLeft = waitSignal:Wait()
			if playerWhoLeft == player then
				debugPrint(5, `Player left while waiting for hop`)
				reject()
				trove:Destroy()
				return
			end
		end

		debugPrint(5, `Success`)
		trove:Destroy()
		resolve()
	end)
end

--[[
	# [ReleaseProfile](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultServer/DOCUMENTATION.md#releaseprofile)

	## Description
	Provides an option to release a player's profile with a parameter that can prevent the player from being automatically kicked from the game.
	This is useful for scenarios like teleportation, where the player needs to remain in the game until the teleportation process begins.

	## Parameters
	- `player: Player` - The player whose profile needs to be released.
	- `dontKick: boolean?` (optional) - If true, the player is not automatically kicked from the game when their profile is released.
		Useful for managing teleportation without interrupting the player's session.

	## Usage Examples
	### Basic
	```lua
	-- Wait for the profile to be ready for a hop
	UserVault.OnHopClear(player)
	:andThen(function()
		TeleportService:TeleportAsync(placeId, {player})
	end)
	:catch(function(e)
		print(`Something went wrong when teleporting`)
	end)

	-- Release the player's profile without kicking them, in anticipation of teleportation
	UserVault.ReleaseProfile(player, true)
	```

	### Using `Promise:timeout()`
	```lua
	-- Wait for the profile to be ready for a hop, with a timeout to handle edge cases
	UserVault.OnHopClear(player):timeout(5) -- Timeout after 5 seconds
	:andThen(function()
		-- Proceed with teleportation upon successful readiness confirmation
		TeleportService:TeleportAsync(placeId, {player})
	end)
	:catch(function(e)
		-- Handle timeout or other errors
		if Promise.Error.isKind(e, Promise.Error.Kind.TimedOut) then
			print(`Timeout occurred while waiting for {player.DisplayName}'s profile to be ready for hop.`)
		else
			print(`An error occurred while preparing {player.DisplayName} for teleportation: {e}`)
		end
		-- Fallback logic for errors, such as kicking or retrying the teleportation process
		if player.Parent then
			player:Kick()
		end
	end)

	-- Once the teleportation is set up, release the player's profile without kicking them
	UserVault.ReleaseProfile(player, true)
	```
	> [!TIP]
	> Utilizing `dontKick` with `true` is essential for teleportation scenarios, ensuring players aren't forcibly exited from the game after their profile
	> release. To handle edge cases, such as players not leaving after a certain period or teleportation failing, it's advisable to use `Promise:timeout()`
	> with this process. This approach allows for the implementation of a fallback mechanism, ensuring that if the player does not leave the game within a
	> specified timeout period, the game can take appropriate action, such as forcibly removing the player or logging an error for further investigation.
]]
function UserVaultServer.ReleaseProfile(player: Player, dontKick: boolean?)
	checkStarted()
	assert(typeof(player) == "Instance" and player:IsA("Player"), "player must be a Player.")
	assert(dontKick == nil or typeof(dontKick) == "boolean", "dontKick must be nil or boolean.")

	debugPrint(3, `Externally releasing profile for {player} (dontKick = {dontKick})`)

	local playerCache = playerCaches[player]
	if playerCache then
		debugPrint(5, `Player cache found`)
		if dontKick then
			debugPrint(5, `Setting DontKickOnRelease attribute`)
			player:SetAttribute("DontKickOnRelease", true)
		end
		playerCache.Profile:Release()
	end
end

--[[
	# [ResetProfile](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultServer/DOCUMENTATION.md#resetprofile)

	## Description
	Deletes all data stored in a player's profile.

	## Parameters
	- `userId: number` - The user ID of the target player.
	- `profileStoreIndex: string` (optional) - If provided, overrides the default profile store index.
		Only needed if using a profile store index other than the default.

	## Return Value
	Returns a boolean indicating if the profile was wiped successfully.

	## Usage Examples
	```lua
	UserVault.ResetProfile(123456789)
	```

	> [!IMPORTANT]
	> ResetProfile can only be called from Roblox Studio. This is to prevent accidental data deletion.

	> [!CAUTION]
	> Resetting a profile is permanent and cannot be undone.
]]
function UserVaultServer.ResetProfile(userId: number, profileStoreIndex: string?): boolean
	if not RunService:IsStudio() then
		error("ResetProfile() must be called from Roblox Studio.")
	end
	assert(typeof(userId) == "number", "userId must be a number.")
	assert(profileStoreIndex == nil or typeof(profileStoreIndex) == "string", "profileStoreIndex must be nil or string.")

	profileStoreIndex = profileStoreIndex or DEFAULT_CONFIG.ProfileStoreIndex

	local store = ProfileService.GetProfileStore(profileStoreIndex, {})
	store:WipeProfileAsync(PROFILE_KEY_FORMAT:format(userId))
end

--[[
	# [PlayerReady](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultServer/DOCUMENTATION.md#playerready)

	## Description
	Returns a promise which resolves when the player's data is ready.

	## Parameters
	- `player: Player` - The target player.

	## Return Value
	Returns a `Promise` that:
	- Resolves upon successfully loading the player profile.
	- Rejects if the player profile cannot be loaded.
]]
function UserVaultServer.PlayerReady(player: Player): Promise
	checkStarted()
	assert(typeof(player) == "Instance" and player:IsA("Player"), "player must be a Player.")

	debugPrint(5, `Waiting for {player} ready`)

	return Promise.new(function(resolve, reject)
		debugPrint(5, `Waiting for player data`)
		waitForPlayerLoaded(player)

		local playerCache = playerCaches[player]
		if playerCache and playerCache.Profile:IsActive() then
			debugPrint(5, `Player data found`)
			resolve()
		else
			debugPrint(5, `Player data not found`)
			reject(`Failed to retrieve profile for player {player}.`)
		end
	end)
end

--[[
	# [Start](https://github.com/rodrick160/UserVault/blob/main/src/UserVaultServer/DOCUMENTATION.md#start)

	## Description
	Initializes UserVaultServer with the provided configuration. This function is essential for setting up the module's behavior according to your game's
	needs and should be called once before starting Knit.

	## Parameters
	- `config: table` - Configuration options for UserVaultServer.
		- `VerboseLevel: number` (optional) - Controls the level of debug information output by the module. Useful for debugging and monitoring module
			operations.
			- `0` - No debug information. Use this level for production environments to keep the logs clean.
			- `1` - Logs basic events like profile loading and releasing. Good for initial testing and verification of module setup.
			- `2` - Includes logs for external data modifications, helping to track unexpected changes or interactions.
			- `3` - Expands logging to include data access events, aiding in debugging data flow and access patterns.
			- `4` - Provides detailed logs on all function calls, useful for in-depth debugging of module operations.
			- `5` - The most verbose level, logging all code paths taken within the module. Best used for troubleshooting specific issues.
		- `DebugUseMock: boolean` (optional) - Enables the use of a mock profile store in Studio, allowing for safe testing without affecting live data.
			Defaults to true.
		- `WarnNilUpdate: boolean` (optional) - Emits warnings when callbacks in `UpdateValue()` return `nil` values, helping identify unintended data
			erasures. Defaults to true.
		- `ProfileStoreIndex: string` (optional) - Custom identifier for the profile store, overriding the default. Useful for differentiating between
			multiple stores or testing environments.
		- `PlayerDataUpdateFunctions: table` - Contains functions for updating player data between versions. Each function should convert data from its index
			version to the next, ensuring smooth transitions during updates.
			- Functions are indexed corresponding to the version they update from (e.g., function at index 1 updates from Version 1 to 2).
				This allows for sequential data transformations across multiple versions.
		- `PlayerDataTemplate: table` - Defines the default data structure for new player profiles. Critical for establishing initial data states and
			versioning.
			- `Version: number` - Indicates the template version, used to trigger data updates via `PlayerDataUpdateFunctions` for existing profiles.
			- `Shared: table` and `Server: table` - Dictate the data accessible on both client and server (`Shared`), and server-only (`Server`), ensuring
				clear data separation and security.

	## Usage Examples
	```lua
	UserVaultServer.Start({
		VerboseLevel = 2,
		DebugUseMock = true,
		WarnNilUpdate = true,
		ProfileStoreIndex = "PlayerData",
		PlayerDataUpdateFunctions = { 
			[1] = function(data) ... end, -- Example update function from Version 1 to 2
		},
		PlayerDataTemplate = {
			Version = 1,
			Shared = { Coins = 0 },
			Server = { Inventory = {} },
		}
	})
	```

	> [!WARNING]
	> It's critical to invoke `Start()` before initializing other modules, such as Knit, to ensure UserVault is fully configured and operational,
	> preventing dependency or initialization conflicts.
	> This order is crucial for maintaining a stable and predictable initialization sequence for your game's services.

	> [!IMPORTANT]
	> Ensure all keys in the PlayerDataTemplate are unique across the Shared and Server categories.
	> If there is a conflict, an error will be thrown.

	> [!NOTE]
	> The default profile store key is `"PlayerData"`
]]
function UserVaultServer.Start(config: UserVaultConfig)
	if started then
		error("Cannot call UserVaultServer.Start() more than once.", 2)

	elseif config == nil then
		error("UserVaultServer.Start() must be given a config table.", 2)
	elseif typeof(config) ~= "table" then
		error("config must be a table.", 2)

	elseif config.VerboseLevel ~= nil then
		if typeof(config.VerboseLevel) ~= "number" or
		math.floor(config.VerboseLevel) ~= config.VerboseLevel or
		config.VerboseLevel < 0 then
			error("config.VerboseLevel must be nil or a non-negative integer.", 2)
		end

	elseif typeof(config.PlayerDataTemplate) ~= "table" then
		error("config.PlayerDataTemplate must be a table.", 2)
	elseif typeof(config.PlayerDataTemplate.Version) ~= "number" or
	math.floor(config.PlayerDataTemplate.Version) ~= config.PlayerDataTemplate.Version or
	config.PlayerDataTemplate.Version < 1 then
		error("config.PlayerDataTemplate.Version must be a positive integer.", 2)
	elseif typeof(config.PlayerDataTemplate.Server) ~= "table" then
		error("config.PlayerDataTemplate.Server must be a table.", 2)
	elseif typeof(config.PlayerDataTemplate.Shared) ~= "table" then
		error("config.PlayerDataTemplate.Shared must be a table.", 2)
	elseif config.PlayerDataTemplate.Version > 1 and config.PlayerDataUpdateFunctions == nil then
		error("Must provide config.PlayerDataUpdateFunctions if config.PlayerDataTemplate.Version is greater than 1.", 2)

	elseif config.PlayerDataUpdateFunctions ~= nil then
		if typeof(config.PlayerDataUpdateFunctions) ~= "table" then
			error("config.PlayerDataUpdateFunctions must be a table.", 2)
		end

		for i = 1, config.PlayerDataTemplate.Version do
			if config.PlayerDataUpdateFunctions[i] == nil then
				error(`config.PlayerDataUpdateFunctions is missing function for Version {i}.`, 2)
			elseif typeof(config.PlayerDataUpdateFunctions[i]) ~= "function" then
				error(`config.PlayerDataUpdateFunctions has non-function value for Version {i}.`, 2)
			end
		end
	end

	for key in config.PlayerDataTemplate.Shared do
		if config.PlayerDataTemplate.Server[key] ~= nil then
			error("config.PlayerDataTemplate contains duplicate fields. Keys must be unique across Shared and Server realms.", 2)
		end
	end

	started = true

	currentConfig = TableUtil.Reconcile(config, DEFAULT_CONFIG)
	TableUtil.Lock(currentConfig)

	profileStore = ProfileService.GetProfileStore(currentConfig.ProfileStoreIndex, currentConfig.PlayerDataTemplate)
	if currentConfig.DebugUseMock and RunService:IsStudio() then
		profileStore = profileStore.Mock
	end

	userVaultComm = Comm.new(game.ReplicatedStorage, "UserVaultComm")
	dataChangedRemoteSignal = userVaultComm:CreateSignal("DataChanged")

	--[[
		Returns a copy of the Shared portion of the player's profile data.
	]]
	userVaultComm:BindFunction("GetPlayerData", function(player: Player): table?
		debugPrint(3, `Player {player} requested their player data`)
		waitForPlayerLoaded(player)
		local playerCache = playerCaches[player]
		if not playerCache or not playerCache.Profile:IsActive() then
			debugPrint(5, `Failed`)
			return
		end

		debugPrint(5, `Success`)
		return playerCache.Profile.Data.Shared
	end)

	local function releasePlayer(player)
		local playerCache = playerCaches[player]
		if playerCache then
			playerCache.Profile:Release()
		end
	end

	game.Players.PlayerRemoving:Connect(releasePlayer)
	game.Players.PlayerAdded:Connect(loadProfile)
	for _, player in game.Players:GetPlayers() do
		loadProfile(player)
	end
end

--\\ Return //--

return UserVaultServer
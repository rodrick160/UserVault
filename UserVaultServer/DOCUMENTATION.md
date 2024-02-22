![UserVault Logo](/logo/Small/UserVault.png)

# UserVaultServer

UserVaultServer is responsible for loading, releasing, and accessing player profiles on the server.
It should be started before any dependent modules (see [`UserVaultServer.Start()`](./DOCUMENTATION.md#start)).

# Docs

## GetValue

### Description
Retrieves specified data from the player's profile.

### Parameters
This function supports three parameter formats:

- `GetValue(player: Player, keys: {string})`: Uses an array of keys to retrieve specific player data.
	- `player: Player` - The target player.
	- `keys: {string}` - The data keys to retrieve.

- `GetValue(player: Player, ...: string)`: Uses a variable number of arguments to specify the data keys.
	- `player: Player` - The target player.
	- `...: string` - The data keys to retrieve.

- `GetValue(player: Player)`: Does not retrieve any values, but can be used to check if the profile has loaded.
	- `player: Player` - The target player.

### Return Value
Returns a [`Promise`](https://eryn.io/roblox-lua-promise/api/Promise/) that:
- Resolves with the requested player data on success. When `keys` is an array, the promise resolves with a dictionary mapping each key to its value.
	When using varargs, the promise resolves with the values directly.
- Rejects if the player profile cannot be loaded.

### Usage Examples

#### Array Example
Retrieve player data using an array of keys `"Coins"` and `"Level"`.
The promise resolves with a dictionary containing the values for these keys.
```lua
UserVaultServer.GetValue(player, {"Coins", "Level"}):andThen(function(data)
	print("Player " .. player.DisplayName .. " has " .. data.Coins .. " coins and is level " .. data.Level)
end, function()
	print("Player " .. player.DisplayName .. "'s data failed to load!")
end)
```

#### Vararg Example
Retrieve player data using varargs `"Coins"` and `"Level"`.
The promise resolves with the values for these keys in order.
```lua
UserVaultServer.GetValue(player, "Coins", "Level"):andThen(function(coins, level)
	print("Player " .. player.DisplayName .. " has " .. coins .. " coins and is level " .. level)
end, function()
	print("Player " .. player.DisplayName .. "'s data failed to load!")
end)
```

> [!TIP]
> GetValues() is a valid alias for GetValue()

## SetValue

### Description
Sets a specified value for a key in the player's profile.

### Parameters
- `player: Player` - The player whose profile is being modified.
- `key: string` - The key within the profile to update.
- `value: any` - The new value to assign to the key.

### Return Value
Returns a [`Promise`](https://eryn.io/roblox-lua-promise/api/Promise/) that:
- Resolves when the value is successfully updated in the player's profile.
- Rejects if updating the player profile fails.

### Usage Examples
```lua
UserVaultServer.SetValue(player, "Coins", 500):andThen(function()
	print("Successfully updated " .. player.DisplayName .. "'s coins to 500")
end, function()
	print("Failed to update " .. player.DisplayName .. "'s coins to 500!")
end)
```

## UpdateValue

### Description
Updates a specified value for a key in the player's profile by applying a callback function.
This function allows for complex transformations of existing data.

### Parameters
- `player: Player` - The player whose profile is being updated.
- `key: string` - The key to be updated within the profile.
- `callback: (value: any) -> any` - A function that receives the current value and returns the updated value.
	This callback is used to transform the value.

> [!CAUTION]
> When working with table values, ensure to return the modified table from the callback to avoid unintended `nil` assignments.

> [!CAUTION]
> The callback function cannot yield under any circumstances, as this could create a race condition. If the callback function yields,
> the thread will be killed and the promise will reject.

### Return Value
Returns a [`Promise`](https://eryn.io/roblox-lua-promise/api/Promise/) that:
- Resolves with the newly computed value after successfully updating it in the player's profile.
	This ensures that the calling code can immediately use the updated value.
- Rejects if the update process fails.

### Usage Examples
```lua
UserVaultServer.UpdateValue(player, "Coins", function(coins)
	return coins + 500
end):andThen(function(newCoins)
	print("Successfully increased " .. player.DisplayName .. "'s coins to " .. newCoins)
end, function()
	print("Failed to update " .. player.DisplayName .. "'s coins!")
end)
```

## IncrementValue

### Description
Increments a specified value for a key in the player's profile by a specific amount.
Sugar for:
```lua
UserVaultServer.UpdateValue(player, key, function(value)
	return value + increment
end)
```

### Parameters
- `player: Player` - The player whose profile is being updated.
- `key: string` - The key to be updated within the profile.
- `increment: number` - The amount to increment the value by.

### Return Value
Returns a [`Promise`](https://eryn.io/roblox-lua-promise/api/Promise/) that:
- Resolves with the newly computed value after successfully updating it in the player's profile.
This ensures that the calling code can immediately use the updated value.
- Rejects if the increment process fails.

### Usage Examples
```lua
UserVaultServer.IncrementValue(player, "Coins", 500):andThen(function(newCoins)
	print("Successfully increased " .. player.DisplayName .. "'s coins by " .. newCoins)
end, function()
	print("Failed to increase " .. player.DisplayName .. "'s coins!")
end)
```

## GetValueChangedSignal

### Description
Creates and returns a signal that is fired when a specified key's value changes in the player's profile.
This operation is dependent on the successful loading of the player's profile.
The signal passes the new and previous values of the observed key.

### Parameters
- `player: Player` - The player whose profile changes are to be monitored.
- `key: string` - The profile key to monitor for changes.

### Return Value
Returns a [`Promise`](https://eryn.io/roblox-lua-promise/api/Promise/) that resolves with a [`Signal`](https://sleitnick.github.io/RbxUtil/api/Signal/) object.
The resolved signal can then be connected to functions that will be called with the new and previous values of the key whenever it changes.
The promise is rejected if the player's profile cannot be loaded.

### Usage Examples
```lua
UserVaultServer.GetValueChangedSignal(player, "Coins")
:andThen(function(signal)
	signal:Connect(function(newValue, oldValue)
		print("Player " .. player.DisplayName .. "'s coins changed from " .. oldValue .. " to " .. newValue)
	end)
end)
:catch(function(error)
	print("Player " .. player.DisplayName .. "'s data failed to load!")
end)
```

> [!NOTE]
> The `Signal` is only available after the player's profile has been successfully loaded.
> It does not fire for the initial load of the profile's data.
> For initial data handling, other methods like [`BindToValue()`](./DOCUMENTATION.md#bindtovalue) should be considered.

## BindToValue

### Description
Invokes a callback function with the current value of a specified key immediately upon binding, and then again each time that key's value
updates in the player's profile.

### Parameters
- `player: Player` - The player whose data is being monitored.
- `key: string` - The key within the player's profile to watch for changes.
- `callback: (newValue: any, oldValue: any?) -> ()` - A callback function that is executed with the new value of the key and,
	for updates after the initial call, the previous value. For the initial invocation, `oldValue` will not be provided.

### Return Value
Returns a [`Promise`](https://eryn.io/roblox-lua-promise/api/Promise/) that:
- Resolves once the callback has been successfully registered and invoked with the current value of the key.
- Rejects if the player's profile cannot be loaded or the key does not exist.

### Usage Examples
```lua
-- Bind to monitor and reflect changes in 'Coins' within the player's leaderstats.
UserVaultServer.BindToValue(player, "Coins", function(newValue, oldValue)
	if oldValue then
		print("Coins updated from " .. oldValue .. " to " .. newValue)
	else
		print("Initial coin value: " .. newValue)
	end
	player.leaderstats.Coins.Value = newValue
end)
```

> [!NOTE]
> The immediate invocation of the callback provides an opportunity to initialize any dependent data or UI elements with the current value of the
> specified key. Subsequent invocations facilitate real-time updates, enabling dynamic content adjustments based on the player's data changes.

## OnHopClear

### Description
Prepares a player's profile for teleportation by ensuring it is properly released and ready to be loaded in a new game instance. `OnHopClear` utilizes
[`Profile:ListenToHopReady()`](https://madstudioroblox.github.io/ProfileService/api/#profilelistentohopready)
from the ProfileService module to monitor and manage the profile's readiness for a hop. This function returns a promise that
resolves once the profile is adequately prepared, optimizing the teleportation process, especially useful when navigating noticeable delays in profile
loading after universe teleports.

### Parameters
- `player: Player` - The player whose profile is to be prepared for a hop.

### Return Value
Returns a [`Promise`](https://eryn.io/roblox-lua-promise/api/Promise/) that:
- Resolves when the player's profile has been successfully released and is ready for loading in a new game instance, facilitating seamless teleportation.
- Rejects if the player leaves the game before the promise resolves. It is recommended to account for this scenario in your implementation to handle
	potential errors gracefully.

### Usage Examples
```lua
UserVaultServer.OnHopClear(player)
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

## ReleaseProfile

### Description
Provides an option to release a player's profile with a parameter that can prevent the player from being automatically kicked from the game.
This is useful for scenarios like teleportation, where the player needs to remain in the game until the teleportation process begins.

### Parameters
- `player: Player` - The player whose profile needs to be released.
- `dontKick: boolean?` (optional) - If true, the player is not automatically kicked from the game when their profile is released.
	Useful for managing teleportation without interrupting the player's session.

### Usage Examples
#### Basic
```lua
-- Wait for the profile to be ready for a hop
UserVaultServer.OnHopClear(player)
:andThen(function()
	TeleportService:TeleportAsync(placeId, {player})
end)
:catch(function(e)
	print("Something went wrong when teleporting")
end)

-- Release the player's profile without kicking them, in anticipation of teleportation
UserVaultServer.ReleaseProfile(player, true)
```

#### Using [`Promise:timeout()`](https://eryn.io/roblox-lua-promise/api/Promise/#timeout)
```lua
-- Wait for the profile to be ready for a hop, with a timeout to handle edge cases
UserVaultServer.OnHopClear(player):timeout(5) -- Timeout after 5 seconds
:andThen(function()
	-- Proceed with teleportation upon successful readiness confirmation
	TeleportService:TeleportAsync(placeId, {player})
end)
:catch(function(e)
	-- Handle timeout or other errors
	if Promise.Error.isKind(e, Promise.Error.Kind.TimedOut) then
		print("Timeout occurred while waiting for " .. player.DisplayName .. "'s profile to be ready for hop")
	else
		print("An error occurred while preparing " .. player.DisplayName .. " for teleportation: " .. e)
	end
	-- Fallback logic for errors, such as kicking or retrying the teleportation process
	if player.Parent then
		player:Kick()
	end
end)

-- Once the teleportation is set up, release the player's profile without kicking them
UserVaultServer.ReleaseProfile(player, true)
```
> [!TIP]
> Utilizing `dontKick` with `true` is essential for teleportation scenarios, ensuring players aren't forcibly exited from the game after their profile
> release. To handle edge cases, such as players not leaving after a certain period or teleportation failing, it's advisable to use [`Promise:timeout()`](https://eryn.io/roblox-lua-promise/api/Promise/#timeout)
> with this process. This approach allows for the implementation of a fallback mechanism, ensuring that if the player does not leave the game within a
> specified timeout period, the game can take appropriate action, such as forcibly removing the player or logging an error for further investigation.

## ResetProfile

### Description
Deletes all data stored in a player's profile.

### Parameters
- `userId: number` - The user ID of the target player.
- `profileStoreIndex: string` (optional) - If provided, overrides the default profile store index.
	Only needed if using a profile store index other than the default.

### Return Value
Returns a boolean indicating if the profile was wiped successfully.

### Usage Examples
```lua
UserVaultServer.ResetProfile(123456789)
```

> [!IMPORTANT]
> ResetProfile can only be called from Roblox Studio. This is to prevent accidental data deletion.

> [!CAUTION]
> Resetting a profile is permanent and cannot be undone.

## Start

### Description
Initializes UserVaultServer with the provided configuration. This function is essential for setting up the module's behavior according to your game's
needs and should be called once before starting Knit.

### Parameters
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
	- `WarnNilUpdate: boolean` (optional) - Emits warnings when callbacks in [`UpdateValue()`](./DOCUMENTATION.md#updatevalue) return `nil` values, helping identify unintended data
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

### Usage Examples
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
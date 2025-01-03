![UserVault Logo](/logo/Small/UserVault.png)

# UserVaultClient

UserVaultClient allows the client to access their own player data and interact with it in various ways.

# Docs

## Start

### Description
Initializes UserVaultClient with the provided configuration. This function is essential for setting up the module's behavior according to your game's
needs and should be called once before starting Knit.

### Parameters
- `config: table` - Configuration options for UserVaultClient.
	- `VerboseLevel: number` (optional) - Controls the level of debug information output by the module. Useful for debugging and monitoring module
		operations.
		- `0` - No debug information. Use this level for production environments to keep the logs clean.
		- `1` - Logs updates to data, useful for tracking dynamic changes during development.
		- `2` - Logs external data access, helping identify unexpected interactions.
		- `3` - The most verbose level, logging all code paths taken within the module. Best used for troubleshooting specific issues.

### Usage Examples
```lua
UserVaultClient.Start({
	VerboseLevel = 2,
})
```

> [!WARNING]
> It's critical to invoke `Start()` before initializing other modules, such as Knit, to ensure UserVault is fully configured and operational,
> preventing dependency or initialization conflicts.
> This order is crucial for maintaining a stable and predictable initialization sequence for your game's services.

## GetState

### Description
Returns a read-only state object representing a value in the player's data profile.
The value of the state object is updated automatically.

### Parameters
- `key: string` - The key of the value to retrieve.
- `defaultValue: any` (optional) - A default value for the state object to resolve to.
	This value will be used until the player profile has been loaded and received by the client, at which time the true value will take its place.

### Return Value
Returns a `Computed` state object from the [Fusion](https://elttob.uk/Fusion) library.

### Usage Examples
```lua
	local scope = Fusion:scoped()
	local coinsValue = UserVault.GetState("Coins", 0)
	local coinsLabel = scope:New "TextLabel" {
		Text = coinsValue
	}
```

## GetValue

### Description
Retrieves specified values from the client's profile.

### Parameters
This function supports three parameter formats:

- `GetValue(keys: {string})`: Uses an array of keys to retrieve specific values.
	- `keys: {string}` - The data keys to retrieve.

- `GetValue(...: string)`: Uses a variable number of arguments to specify the data keys.
	- `...: string` - The data keys to retrieve.

- `GetValue()`: Does not retrieve any values, but can be used to check if the profile has loaded.

### Return Value
Returns a [`Promise`](https://eryn.io/roblox-lua-promise/api/Promise/) that resolves with the requested values.
When `keys` is an array, the promise resolves with a dictionary mapping each key to its value.
When using varargs, the promise resolves with the values directly.

### Usage Examples

#### Array Example
Retrieve values using an array of keys `"Coins"` and `"Level"`.
The promise resolves with a dictionary containing the values for these keys.
```lua
UserVault.GetValue({"Coins", "Level"}):andThen(function(data)
	print("Local player has " .. data.Coins .. " coins and is level " .. data.Level)
end)
```

#### Vararg Example
Retrieve values using varargs `"Coins"` and `"Level"`.
The promise resolves with the values for these keys in order.
```lua
UserVault.GetValue("Coins", "Level"):andThen(function(coins, level)
	print("Local player has " .. coins .. "coins and is level " .. level)
end)
```

> [!TIP]
> GetValues() is a valid alias for GetValue()

## GetValueChangedSignal

### Description
Creates and returns a [`Signal`](https://sleitnick.github.io/RbxUtil/api/Signal/) that is fired when a specified key's value changes in the client's profile.
The signal passes the new and previous values of the observed key.

### Parameters
- `key: string` - The profile key to monitor for changes.

### Return Value
Returns a [`Signal`](https://sleitnick.github.io/RbxUtil/api/Signal/) object that will fire with the new and previous values of the key whenever it changes.

### Usage Examples
```lua
UserVault.GetValueChangedSignal("Coins"):Connect(function(newValue, oldValue)
	print("Local player's coins changed from " .. oldValue .. " to " .. newValue)
end)
```

> [!NOTE]
> The signal is only available after the player's profile has been successfully loaded.
> It does not fire for the initial load of the profile's data.
> For initial data handling, other methods like `BindToValue()` should be considered.

## BindToValue

### Description
Invokes a callback function with the current value of a specified key immediately upon binding, and then again each time that key's value
updates in the client's profile.

### Parameters
- `key: string` - The key within the client's profile to watch for changes.
- `callback: (newValue: any, oldValue: any?) -> ()` - A callback function that is executed with the new value of the key and,
	for updates after the initial call, the previous value. For the initial invocation, `oldValue` will not be provided.

### Return Value
Returns a [`Promise`](https://eryn.io/roblox-lua-promise/api/Promise/) that resolves once the callback has been registered and invoked with the current value of the key.

### Usage Examples
```lua
-- Bind to monitor and reflect changes in 'Coins' in a `TextLabel`.
UserVault.BindToValue("Coins", function(newValue, oldValue)
	if oldValue then
		print("Coins updated from " .. oldValue .. " to " .. newValue)
	else
		print("Initial coin value" .. newValue)
	end
	textLabel.Text = newValue
end)
```

> [!NOTE]
> The immediate invocation of the callback provides an opportunity to initialize any dependent data or UI elements with the current value of the
> specified key. Subsequent invocations facilitate real-time updates, enabling dynamic content adjustments based on the player's data changes.

## DataReady

### Description
Returns a boolean flag indicating if the client's data is ready for consumption.

> [!TIP]
> Pairs well with [`GetDataReadySignal()`](./DOCUMENTATION.md#getdatareadysignal)

## GetDataReadySignal

### Description
Returns a signal which fires when the client's data becomes ready for consuption.

> [!WARNING]
> The returned signal will not fire if the function is called after the data is already ready.
> Use [`DataReady()`](./DOCUMENTATION.md#dataready) before waiting for this signal.
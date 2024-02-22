![UserVault Logo](/logo/Small/UserVault.png)

# UserVault

UserVault is a DataStore module built on ProfileService which provides safe and convenient access to player data on both the server and the client.

# Getting Started

## Install

Add UserVault to your [Wally](https://github.com/UpliftGames/wally) packages:

`rodrick160/uservault@0.2.8`

## Setup

UserVault needs to be started before it can be used.
It is important to start UserVault before any dependent modules.
If you are using [Knit](https://sleitnick.github.io/Knit/docs/intro) or an equivalent system, start UserVault before starting Knit.

### Server Example
```lua
local Knit = require(game.ReplicatedStorage.Packages.Knit)
local UserVault = require(game.ReplicatedStorage.Packages.UserVault)

UserVault.Start {
	PlayerDataTemplate = {
		Coins = 0
	}
}

-- Require modules

Knit.Start():catch(warn)
```

### Client Example
```lua
local Knit = require(game.ReplicatedStorage.Packages.Knit)
local UserVault = require(game.ReplicatedStorage.Packages.UserVault)

UserVault.Start()

-- Require modules

Knit.Start():catch(warn)
```

# Docs

Depending on whether UserVault is required from the server or client, it will return one of the following objects:
- [`UserVaultServer`](/UserVaultServer/DOCUMENTATION.md)
- [`UserVaultClient`](/UserVaultClient/DOCUMENTATION.md)

# Credit

## Authors
- Sebastian Seifert

## Third-Party Packages
- [Comm](https://sleitnick.github.io/RbxUtil/api/Comm/)
- [Fusion](https://elttob.uk/Fusion/)
- [Promise](https://eryn.io/roblox-lua-promise/)
- [Signal](https://sleitnick.github.io/RbxUtil/api/Signal)
- [TableUtil](https://sleitnick.github.io/RbxUtil/api/TableUtil)
- [Trove](https://sleitnick.github.io/RbxUtil/api/Trove)
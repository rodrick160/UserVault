-- UserVault
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
]]

local RunService = game:GetService("RunService")

if RunService:IsServer() then
	return require(script.UserVaultServer)
else
	return require(script.UserVaultClient)
end
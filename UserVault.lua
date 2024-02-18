-- UserVault
-- Quantum Maniac
-- Feb 17 2024

local RunService = game:GetService("RunService")

if RunService:IsServer() then
	return require(script.Parent.UserVaultService)
else
	return require(script.Parent.UserVaultController)
end
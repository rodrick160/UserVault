-- WaitFor
-- Quantum Maniac
-- Jul 22 2023

--\\ Dependencies //--

local Signal = require(script.Parent.Parent.Signal)

--\\ Module //--

local WaitFor = {}
WaitFor = WaitFor :: WaitFor
WaitFor.__index = WaitFor

--\\ Types //--

export type WaitFor = typeof(WaitFor)

--\\ Public //--

function WaitFor.new(disableWarning: boolean?)
	local self = {}
	setmetatable(self, WaitFor)

	self._cleared = false
	self._disableWarning = disableWarning
	self._signal = Signal.new()

	return self
end

function WaitFor:Await()
	if not self._cleared then
		if not self._disableWarning and not self._warnThread then
			local traceback = debug.traceback("", 2)
			self._warnThread = task.spawn(function()
				task.wait(5)
				warn("WaitFor has potentially infinite yield " .. traceback)
			end)
		end
		self._signal:Wait()
	end
end

function WaitFor:Clear()
	if self._warnThread then
		task.cancel(self._warnThread)
	end
	self._cleared = true
	self._signal:Fire()
end

--\\ Return //--

return WaitFor
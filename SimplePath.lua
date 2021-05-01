--[[
---------------------------------------------------------------------
Created by: V3N0M_Z
API: https://github.com/00xima/SimplePath
---------------------------------------------------------------------
]]

local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")

--Used to display waypoints
local displayPart = Instance.new("Part")
displayPart.Size = Vector3.new(1, 1, 1)
displayPart.Anchored = true
displayPart.CanCollide = false
displayPart.Color = Color3.fromRGB(255, 255, 255)
displayPart.Material = Enum.Material.Neon
displayPart.Shape = Enum.PartType.Ball

local nonHumanoidRestrictions = {
	Blocked = ":Blocked()";
	Stopped = "Stopped event";
}
local Path = {
	Status = {
		PathNotFound = "PathNotFound";
		PathCompleted = "PathCompleted";
		PathBlocked = "PathBlocked";
	};
}
Path.__index = function(tab, index)
	if not tab._humanoid then
		assert(not nonHumanoidRestrictions[index], (nonHumanoidRestrictions[index] or "").." cannot be used for a non-humanoid model")
	end
	return (tab._signals[index] and tab._signals[index].Event) or Path[index]
end

--Execute if Path.IgnoreObstacles is true
local function RetryPath(self)
	if self.IgnoreObstacles and self._goal then
		self._humanoid.Jump = true
		self._active = false
		self:Run(self._goal)
	end
end

--Move the humanoid model
local function Move(self)
	if self._active then
		if self._humanoid then
			self._humanoid:MoveTo(self._waypoints[self._waypoint].Position)
		end
	end
end

--Detect for gaps between waypoints
local function JumpDetect(self)
	if self._waypoints[self._waypoint + 1] and self._humanoid then
		local p0 = self._waypoints[self._waypoint].Position
		local p1 = self._waypoints[self._waypoint + 1].Position
		local pos = (p1 - p0).Unit * ((p1 - p0).Magnitude / 2) + p0
		local raycast = workspace:Raycast(pos + Vector3.new(0, 0.1, 0), Vector3.new(0, -1000, 0))
		if (p1.Y - p0.Y  >= self._humanoid.HipHeight) or (raycast and p1.Y - raycast.Position.Y  >= self._humanoid.HipHeight) then
			self._humanoid.Jump = true
		end
	end
end

--Check and fire the WaypointReached event
local function FireWaypointReached(self)
	local lastPos = (self._waypoint - 1 > 0 and self._waypoints[self._waypoint - 1].Position) or self._model.PrimaryPart.Position
	local nextPos = self._waypoints[self._waypoint].Position
	if lastPos == nextPos then return end
	self._signals.WaypointReached:Fire(self._model, lastPos, nextPos)
end

--Execute when humanoid reaches waypoint
local function WaypointReached(self, reached)
	FireWaypointReached(self)

	if not self._humanoid then
		if self._waypoint < #self._waypoints then
			self._waypoint += 1
		else
			self:Stop(self.Status.Reached)
			self._signals.Reached:Fire(self._model)
		end
		return
	end

	if reached and self._waypoint < #self._waypoints then	
		JumpDetect(self)
		self._waypoint += 1
		Move(self)
	elseif reached then
		self:Stop(self.Status.PathCompleted)
		self._signals.Reached:Fire(self._model)
	else
		RetryPath(self)
		self:Stop(self.Status.PathBlocked)
		self._signals.Blocked:Fire(self._model)
	end
end

--Fix the computed waypoints to make the path transition seamless
local function CleanWaypoints(self, newWaypoints, finalPosition)
	local cleanedWaypoints = {}
	for _, waypoint in ipairs(newWaypoints) do
		local angle = math.acos((finalPosition - self._model.PrimaryPart.Position).Unit:Dot((waypoint.Position - self._model.PrimaryPart.Position).Unit))
		if angle < 150 * (math.pi / 180) then
			table.insert(cleanedWaypoints, waypoint)
		end
	end
	return cleanedWaypoints
end

--Get initial waypoint for non-humanoid models
local function GetNonHumanoidWaypoint(self)
	for i, waypoint in ipairs(self._waypoints) do
		local mag = (waypoint.Position - self._model.PrimaryPart.Position).Magnitude
		if mag > 1 then
			return i
		end
	end
	return 1
end

--Destroy visual waypoints
local function DestroyWaypoints(waypoints)
	return (waypoints and (function()
		for _, waypoint in ipairs(waypoints) do
			waypoint:Destroy()
		end
	end)())
end

--Create visual waypoints
local function CreateWaypoints(waypoints)
	local displayParts = {}
	for _, waypoint in ipairs(waypoints) do
		local displayPartClone = displayPart:Clone()
		displayPartClone.Position = waypoint.Position
		displayPartClone.Parent = workspace
		table.insert(displayParts, displayPartClone)
	end
	return displayParts
end

--Execute when the humanoid doesn't reach waypoint in time
local function Timeout(self)
	RetryPath(self)
	self:Stop(self.Status.PathBlocked)
	self._signals.Blocked:Fire(self._model)
end

function Path.new(model, agentParameters)
	assert(model:IsA("Model") and model.PrimaryPart, "model must by a valid Model Instance with a set PrimaryPart")

	local self = setmetatable({
		_signals = {
			Reached = Instance.new("BindableEvent");
			Blocked = Instance.new("BindableEvent");
			WaypointReached = Instance.new("BindableEvent");
			Stopped = Instance.new("BindableEvent");
		};
		_connections = {};
		_model = model;
		_path = PathfindingService:CreatePath(agentParameters);
		_humanoid = model:FindFirstChildOfClass("Humanoid") or false;
		IgnoreObstacles = true;
	}, Path)

	if self._humanoid then
		self._connections = {self._humanoid.MoveToFinished:Connect(function(reached)
			if self._active then
				self._elapsed = tick()
				WaypointReached(self, reached)
			end
		end);
		}
	end

	pcall(function() self._model.PrimaryPart:SetNetworkOwner(nil) end)
	return self
end

function Path:Destroy()
	for _, signal in ipairs(self._signals) do
		signal:Destroy()
		self._signals[signal] = nil
	end
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	DestroyWaypoints(self._displayParts)
	self._connections = nil
	self._humanoid = nil
	self._path = nil
	self._goal = nil
end

function Path:Stop(status)
	self._signals.Stopped:Fire(self._model, status)
	self._active = false
	self._elapsed = false
	self._displayParts = (self._displayParts and DestroyWaypoints(self._displayParts))
end

function Path:Run(goal)

	if not goal and not self._humanoid and self._goal then
		WaypointReached(self, true)
		return
	end
	assert(goal and (typeof(goal) == "Vector3" or goal:IsA("BasePart")), "Goal must be a valid BasePart or a Vector3 position")

	local initialPosition = self._model.PrimaryPart.Position
	local finalPosition = (typeof(goal) == "Vector3" and goal) or goal.Position
	local success, msg = pcall(function()
		self._path:ComputeAsync(initialPosition, finalPosition)
	end)
	if not success or self._path.Status == Enum.PathStatus.NoPath or not self._path:GetWaypoints() or #self._path:GetWaypoints() == 0 or (self._humanoid and self._humanoid.FloorMaterial == Enum.Material.Air and self._model.PrimaryPart.Velocity.Magnitude >= 1) then
		self:Stop(self.Status.PathNotFound)
		return false
	end

	self._waypoints = (self._active and CleanWaypoints(self, self._path:GetWaypoints(), finalPosition)) or self._path:GetWaypoints()
	self._waypoint = 1
	self._goal = goal
	DestroyWaypoints(self._displayParts)
	self._displayParts = (self.Visualize and CreateWaypoints(self._waypoints))

	if not self._humanoid then
		self._waypoint = GetNonHumanoidWaypoint(self)
		WaypointReached(self, true)
		return
	end

	if not self._active then
		self._active = true
		Move(self)
		coroutine.wrap(function()
			while self._active do
				if self._elapsed and tick() - self._elapsed > 1 then
					Timeout(self); break
				end
				RunService.Stepped:Wait()
			end
		end)()
	end

	return true
end

return Path
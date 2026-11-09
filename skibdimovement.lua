-- Camcorder camera + VHS overlay (steady) + 4:3 bars + sprint + zoom (motor sound)
-- + barrel look + door lean + muffled audio + startup beep + battery change
-- (client-side, self-building)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local ContentProvider = game:GetService("ContentProvider")
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")
local ProximityPromptService = game:GetService("ProximityPromptService")

-- Wait for LocalPlayer + camera
local player = Players.LocalPlayer
while not player do
	Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
	player = Players.LocalPlayer
end
local camera = workspace.CurrentCamera
while not camera do
	workspace:GetPropertyChangedSignal("CurrentCamera"):Wait()
	camera = workspace.CurrentCamera
end

-- Cleanup if re-executed
pcall(function() RunService:UnbindFromRenderStep("CamcorderCam") end)
pcall(function() RunService:UnbindFromRenderStep("CamcorderUndo") end)
for _, n in ipairs({"CamcorderBlur", "CamcorderDOF"}) do
	local o = Lighting:FindFirstChild(n)
	if o then o:Destroy() end
end
for _, n in ipairs({"CamcorderEQ", "CamcorderPitch", "CamcorderDist", "CamcorderHiss",
	"CamcorderMotor", "CamcorderBeep", "CamcorderBattery", "CamcorderWind", "CamcorderComp"}) do
	local o = SoundService:FindFirstChild(n)
	if o then o:Destroy() end
end
for _, o in ipairs(SoundService:GetChildren()) do
	if string.find(o.Name, "^CamcorderStep_") then o:Destroy() end
end
if _G.CamcorderConns then
	for _, c in ipairs(_G.CamcorderConns) do pcall(function() c:Disconnect() end) end
end
_G.CamcorderConns = {}
local function keep(conn) table.insert(_G.CamcorderConns, conn) return conn end

-- Remember the ORIGINAL field of view across re-runs (zoom changes FOV)
local baseFOV = _G.CamcorderBaseFOV or camera.FieldOfView
_G.CamcorderBaseFOV = baseFOV
camera.FieldOfView = baseFOV

-- Force first person
local function forceFirstPerson()
	pcall(function()
		player.CameraMaxZoomDistance = 0.5
		player.CameraMinZoomDistance = 0.5
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	end)
end
forceFirstPerson()

---------------------------------------------------------------------
-- SPRING MODULE (embedded)
---------------------------------------------------------------------
local ITERATIONS = 8
local SPRING = {}

function SPRING.create(self, mass, force, damping, speed)
	local spring = {
		Target = Vector3.new(); Position = Vector3.new(); Velocity = Vector3.new();
		Mass = mass or 5; Force = force or 50; Damping = damping or 4; Speed = speed or 4;
	}
	function spring.shove(self, force)
		local x, y, z = force.X, force.Y, force.Z
		if x ~= x or x == math.huge or x == -math.huge then x = 0 end
		if y ~= y or y == math.huge or y == -math.huge then y = 0 end
		if z ~= z or z == math.huge or z == -math.huge then z = 0 end
		self.Velocity = self.Velocity + Vector3.new(x, y, z)
	end
	function spring.update(self, dt)
		local scaledDeltaTime = math.min(dt, 1) * self.Speed / ITERATIONS
		for i = 1, ITERATIONS do
			local iterationForce = self.Target - self.Position
			local acceleration = (iterationForce * self.Force) / self.Mass
			acceleration = acceleration - self.Velocity * self.Damping
			self.Velocity = self.Velocity + acceleration * scaledDeltaTime
			self.Position = self.Position + self.Velocity * scaledDeltaTime
		end
		return self.Position
	end
	return spring
end

---------------------------------------------------------------------
-- SETTINGS  (raise a number = stronger effect)
---------------------------------------------------------------------
local CFG = {
	Intensity   = 3.6,   -- MASTER strength: scales sway, bob, wobble, drift, landing
	SwayAmount  = 1.5,   -- lag/tilt when you turn the camera
	BobAmount   = 1.6,   -- walking bob
	DriftAmount = 1.6,   -- constant handheld wobble
	LandShake   = 1.4,   -- landing impact
	WanderDeg   = 24,    -- how far the camera slowly drifts off (degrees)
	WanderRate  = 1.2,   -- how often it drifts (lower = slower)
	BlurMax     = 14,    -- max random blur size
	BlurRate    = 1.0,   -- how often blur happens
	AspectRatio = 4 / 3, -- black bar shape
	MaxSwayDeg  = 12,    -- hard cap on turn sway tilt (degrees)
	Smoothness  = 3.5,   -- camera motion smoothing (lower = floatier/smoother, higher = snappier, 30+ = off)

	RunBoost    = 1.0,   -- how much faster/stronger the camera motion gets when running (0 = off)
	SprintMult  = 1.6,   -- walk speed multiplier while sprinting
	SprintFOV   = 10,    -- extra field of view while sprinting
	DoorDist    = 14,    -- max studs to a door for a click to count
	DoorNames   = { "door", "gate", "hatch" },

	-- Zoom
	ZoomMax     = 6,     -- maximum zoom (x)
	ZoomSpeed   = 1.4,   -- how fast holding + / - zooms
	MotorVolume = 0.7,   -- zoom motor loudness

	-- Smooth movement (lerp) -- higher = snappier, lower = floatier
	MoveAccel   = 7,     -- how fast you speed up to walking speed
	MoveDecel   = 6,     -- how fast you slow down when you let go
	AirControl  = 2.5,   -- steering strength in the air while bhopping

	-- Bhop (hold jump to auto-hop; each landing adds speed)
	BhopOn      = true,
	BhopCap     = 23,    -- top bhop speed (studs/second)
	BhopGain    = 1.5,   -- speed added per landing
	BhopGrace   = 0.25,  -- seconds after landing you can keep the chain alive
	BhopDecay   = 8,     -- speed lost per second once you stop hopping

	-- Footsteps
	StepStride  = 6,     -- studs travelled per footstep
	StepVolume  = 0.8,

	-- Mic wind pickup (speeds in studs/second)
	WindThreshold = 30,  -- air speed past the mic before wind noise starts (sprinting ~26, falling is higher)
	WindMax       = 90,  -- air speed where wind noise is at full blast
	WindVolume    = 1,   -- loudness of the wind sound at full blast
	WindFade      = 3,   -- how fast wind noise fades in/out (higher = faster)
	WindDistMin   = 0.4, -- wind sound distortion when it first starts (0..1)
	WindDistMax   = 0.9, -- wind sound distortion at full blast (0..1)

	-- Battery
	BatteryMinutes = 20,   -- minutes one battery lasts (0 = never drains); zooming drains a bit faster
	BatteryMinTime = 3,    -- shortest a battery change takes (seconds)
	BatteryMaxTime = 8,    -- longest wait for the change sound (seconds)
	BatteryKey     = Enum.KeyCode.R, -- PC key to reload the battery
	BeepOnFinish   = true, -- beep again when the new battery is in

	-- Barrel / CRT lens look
	BarrelOn    = false, -- false = plain square-cornered frame (no rounded black corners / vignette)
	CornerPct   = 0.08,  -- screen corner roundness (fraction of screen height)
	VignetteDark= 0.55,  -- how dark the edges get (0..1)

	-- Muffled recording audio (lower HighGain = more muffled, range -80..10)
	MuffleHigh  = -38,   -- treble cut (this is the main muffle)
	MuffleMid   = -8,
	MuffleLow   = 4,     -- boomy bass like a tiny mic
	TapeHissId  = nil,   -- optional looping hiss sound id
}

CFG.BatteryDrain = (CFG.BatteryMinutes > 0) and (100 / (CFG.BatteryMinutes * 60)) or 0

local IDS = {
	Motor   = 9113676092,
	Beep    = 140006631574809,
	Battery = 9113677274,
	Wind    = 107570305797094,
	Eject   = 105087507875249,
}
local function asset(id) return "rbxassetid://" .. id end

---------------------------------------------------------------------
-- SPRINGS
---------------------------------------------------------------------
local swaySpring   = SPRING:create(5, 40, 5, 4)
local bobSpring    = SPRING:create(4, 60, 6, 5)
local driftSpring  = SPRING:create(8, 20, 3, 2)
local landSpring   = SPRING:create(3, 80, 7, 6)
local wanderSpring = SPRING:create(10, 12, 3, 0.7)
local doorSpring   = SPRING:create(4, 55, 6, 5)

local lastLook = camera.CFrame.LookVector
local bobTime = 0
local nextDrift = 0
local nextWander = tick() + 1
local wasAirborne = false
local lastYVel = 0
local seed = math.random() * 1000

local function clampVec(v, m)
	return Vector3.new(
		math.clamp(v.X, -m, m),
		math.clamp(v.Y, -m, m),
		math.clamp(v.Z, -m, m))
end

---------------------------------------------------------------------
-- BLUR EFFECTS
---------------------------------------------------------------------
local blur = Instance.new("BlurEffect")
blur.Name = "CamcorderBlur"
blur.Size = 0
blur.Parent = Lighting

local dof = Instance.new("DepthOfFieldEffect")
dof.Name = "CamcorderDOF"
dof.FarIntensity = 0
dof.NearIntensity = 0
dof.FocusDistance = 30
dof.InFocusRadius = 40
dof.Parent = Lighting

local blurTarget, blurNow = 0, 0
local nextBlur = tick() + 2
local blurHold = 0
local dofTargetFar, dofFar = 0, 0
local dofTargetNear, dofNear = 0, 0

---------------------------------------------------------------------
-- MUFFLED RECORDING AUDIO
---------------------------------------------------------------------
local eq, pitch, dist, hiss, comp
pcall(function()
	eq = Instance.new("EqualizerSoundEffect")
	eq.Name = "CamcorderEQ"
	eq.HighGain = CFG.MuffleHigh
	eq.MidGain = CFG.MuffleMid
	eq.LowGain = CFG.MuffleLow
	eq.Parent = SoundService

	pitch = Instance.new("PitchShiftSoundEffect")
	pitch.Name = "CamcorderPitch"
	pitch.Octave = 1
	pitch.Parent = SoundService

	dist = Instance.new("DistortionSoundEffect")
	dist.Name = "CamcorderDist"
	dist.Level = 0.06
	dist.Parent = SoundService

	-- squashed, boxy mic dynamics
	comp = Instance.new("CompressorSoundEffect")
	comp.Name = "CamcorderComp"
	comp.Threshold = -28
	comp.Ratio = 8
	comp.Attack = 0.02
	comp.Release = 0.2
	comp.GainMakeup = 4
	comp.Parent = SoundService
end)
if CFG.TapeHissId then
	pcall(function()
		hiss = Instance.new("Sound")
		hiss.Name = "CamcorderHiss"
		hiss.SoundId = asset(CFG.TapeHissId)
		hiss.Looped = true
		hiss.Volume = 0.25
		hiss.Parent = SoundService
		hiss:Play()
	end)
end

---------------------------------------------------------------------
-- CAMERA SOUNDS (zoom motor, beep, battery change)
---------------------------------------------------------------------
local function makeSound(name, id, volume, looped)
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = asset(id)
	s.Volume = volume
	s.Looped = looped or false
	s.Parent = SoundService
	return s
end

local motorSnd   = makeSound("CamcorderMotor", IDS.Motor, 0, true)
local beepSnd    = makeSound("CamcorderBeep", IDS.Beep, 1, false)
local batterySnd = makeSound("CamcorderBattery", IDS.Battery, 1, false)
local windSnd    = makeSound("CamcorderWind", IDS.Wind, 0, true)
local windDist = nil
pcall(function()
	windDist = Instance.new("DistortionSoundEffect")
	windDist.Name = "CamcorderWindDist"
	windDist.Level = CFG.WindDistMin
	windDist.Parent = windSnd -- distorts only the wind sound
end)
pcall(function() motorSnd:Play() end) -- runs silent (volume 0) until zooming
pcall(function() windSnd:Play() end)  -- runs silent until the mic picks up wind

local function playOnce(s)
	pcall(function()
		s.TimePosition = 0
		s:Play()
	end)
end

---------------------------------------------------------------------
-- SPRINT + ZOOM + BATTERY STATE
---------------------------------------------------------------------
local sprintHeld = false
local sprintApplied = false
local baseSpeed = 16
local currentHum = nil
local sprintAmount = 0

local zoomTarget, zoomNow = 1, 1
local zoomInHeld, zoomOutHeld = false, false
local motorLevel = 0
local windNow = 0 -- 0..1 how much wind the mic is picking up

local battery = 100
local changingBattery = false
local lowWarned = false
local changeBattery -- defined after the GUI exists

local function getHumanoid()
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid"),
	       char and char:FindFirstChild("HumanoidRootPart")
end

keep(UserInputService.InputBegan:Connect(function(input, gp)
	if input.KeyCode == Enum.KeyCode.LeftShift then sprintHeld = true end
	if input.KeyCode == Enum.KeyCode.Equals then zoomInHeld = true end
	if input.KeyCode == Enum.KeyCode.Minus then zoomOutHeld = true end
	if input.KeyCode == CFG.BatteryKey and not gp and changeBattery then changeBattery() end
end))
keep(UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftShift then sprintHeld = false end
	if input.KeyCode == Enum.KeyCode.Equals then zoomInHeld = false end
	if input.KeyCode == Enum.KeyCode.Minus then zoomOutHeld = false end
end))
-- Mouse wheel zoom (PC)
keep(UserInputService.InputChanged:Connect(function(input, gp)
	if input.UserInputType == Enum.UserInputType.MouseWheel and not changingBattery then
		zoomTarget = math.clamp(zoomTarget * (1 + input.Position.Z * 0.2), 1, CFG.ZoomMax)
	end
end))

---------------------------------------------------------------------
-- DOOR LEAN (camera dips like switching to one hand)
---------------------------------------------------------------------
local doorReleaseAt = 0
local doorCooldown = 0

local function doorLean()
	local now = tick()
	if now < doorCooldown then return end
	doorCooldown = now + 1.6
	doorReleaseAt = now + 0.9
	doorSpring.Target = Vector3.new(-13, -5, 9)
end

local function nameIsDoor(name)
	name = name:lower()
	for _, n in ipairs(CFG.DoorNames) do
		if name:find(n, 1, true) then return true end
	end
	return false
end

local function looksLikeDoor(inst)
	local cur = inst
	for _ = 1, 4 do
		if not cur or cur == workspace then break end
		if nameIsDoor(cur.Name) then return true end
		cur = cur.Parent
	end
	return false
end

keep(ProximityPromptService.PromptTriggered:Connect(function(prompt, plr)
	if plr ~= player then return end
	local text = (prompt.ActionText .. " " .. prompt.ObjectText):lower()
	if text:find("door") or text:find("open") or looksLikeDoor(prompt.Parent) then
		doorLean()
	end
end))

keep(UserInputService.InputBegan:Connect(function(input, gp)
	if gp then return end
	local t = input.UserInputType
	if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then return end

	local cam = workspace.CurrentCamera
	local ray = cam:ScreenPointToRay(input.Position.X, input.Position.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	if player.Character then params.FilterDescendantsInstances = { player.Character } end
	local result = workspace:Raycast(ray.Origin, ray.Direction * 60, params)
	if not result or not result.Instance then return end
	if not looksLikeDoor(result.Instance) then return end

	local _, root = getHumanoid()
	if root and (root.Position - result.Position).Magnitude > CFG.DoorDist then return end
	doorLean()
end))

---------------------------------------------------------------------
-- SMOOTH MOVEMENT + BHOP + FOOTSTEPS
---------------------------------------------------------------------
local STEP_IDS = {
	Tile     = 9065069004,
	Gravel   = 9064853890,
	Wood     = 9064822808,
	Metal    = 9064974448,
	Grass    = 9064714296,
	Concrete = 103640256464902,
}
local MATERIAL_GROUPS = {
	Tile   = { "Tile", "Marble", "Granite", "Glass", "Ice", "Glacier" },
	Gravel = { "Pebble", "Ground", "Sand", "Mud", "Cobblestone", "Salt", "Rock", "Basalt" },
	Wood   = { "Wood", "WoodPlanks" },
	Metal  = { "Metal", "CorrodedMetal", "DiamondPlate", "Foil" },
	Grass  = { "Grass", "LeafyGrass", "Snow", "Fabric" },
	-- everything else (Concrete, Brick, Asphalt, Plastic...) falls back to Concrete
}
local matToKind = {}
for kind, names in pairs(MATERIAL_GROUPS) do
	for _, n in ipairs(names) do
		pcall(function() matToKind[Enum.Material[n]] = kind end)
	end
end

local stepSounds = {}
local stepList = {}
for kind, id in pairs(STEP_IDS) do
	local snd = makeSound("CamcorderStep_" .. kind, id, 0.6, false)
	stepSounds[kind] = snd
	table.insert(stepList, snd)
end
task.spawn(function()
	pcall(function() ContentProvider:PreloadAsync(stepList) end)
end)

local function stopSteps()
	for _, snd in ipairs(stepList) do
		if snd.IsPlaying then snd:Stop() end
	end
end

local function playStep(material, vol)
	local kind = matToKind[material] or "Concrete"
	local snd = stepSounds[kind]
	if not snd then return end
	snd.Volume = vol * CFG.StepVolume
	snd.PlaybackSpeed = 0.92 + math.random() * 0.16
	playOnce(snd)
end

-- Mobile jump button hold detection (so bhop works on touch too)
local touchJumpHeld = false
local boundJump = nil
local function bindTouchJump()
	local pg = player:FindFirstChildOfClass("PlayerGui")
	local tg = pg and pg:FindFirstChild("TouchGui")
	local frame = tg and tg:FindFirstChild("TouchControlFrame")
	local btn = frame and frame:FindFirstChild("JumpButton")
	if btn and btn ~= boundJump then
		boundJump = btn
		keep(btn.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then touchJumpHeld = true end
		end))
		keep(btn.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then touchJumpHeld = false end
		end))
	end
end
bindTouchJump()

local smoothVel = Vector3.new()
local bhopSpeed = 0
local bhopIdleT = 99
local moveWasAir = false
local stepDist = CFG.StepStride * 0.7
local nextBindCheck = 0
local lastLandT = 0

keep(RunService.Heartbeat:Connect(function(dt)
	dt = math.min(dt, 1 / 20)
	local now = tick()
	if now >= nextBindCheck then
		nextBindCheck = now + 1
		pcall(bindTouchJump)
	end

	local hum, root = getHumanoid()
	if not hum or not root or hum.Health <= 0 then
		smoothVel = Vector3.new()
		return
	end
	-- Remove Roblox's original walking sound (it gets re-created on respawn)
	local origRun = root:FindFirstChild("Running")
	if origRun and origRun:IsA("Sound") then
		origRun.Volume = 0
		pcall(function() origRun:Destroy() end)
	end

	local vel = root.AssemblyLinearVelocity
	local horiz = Vector3.new(vel.X, 0, vel.Z)

	-- Seated / ragdolled: hands off
	if hum.Sit or hum.SeatPart or hum.PlatformStand then
		smoothVel = horiz
		bhopSpeed = 0
		moveWasAir = false
		return
	end

	local grounded = hum.FloorMaterial ~= Enum.Material.Air
	local landed = grounded and moveWasAir
	local move = hum.MoveDirection
	local hasInput = move.Magnitude > 0.05

	local jumpHeld = false
	if CFG.BhopOn then
		jumpHeld = UserInputService:IsKeyDown(Enum.KeyCode.Space) or touchJumpHeld
		if not jumpHeld then
			pcall(function()
				jumpHeld = UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonA)
			end)
		end
	end

	-- BHOP: hold jump = auto-hop, every landing adds a bit of speed up to the cap
	local normalSpeed = hum.WalkSpeed
	if grounded then
		if jumpHeld then
			if landed then
				local base = math.max(bhopSpeed, math.min(normalSpeed, CFG.BhopCap))
				bhopSpeed = math.min(CFG.BhopCap, base + CFG.BhopGain)
			end
			bhopIdleT = 0
			hum.Jump = true
		else
			bhopIdleT += dt
			if bhopIdleT > CFG.BhopGrace then
				bhopSpeed = math.max(0, bhopSpeed - CFG.BhopDecay * dt)
			end
		end
	elseif jumpHeld then
		bhopIdleT = 0
	end

	local chain = jumpHeld or bhopIdleT < CFG.BhopGrace
	local targetSpeed = normalSpeed
	if chain and bhopSpeed > normalSpeed then
		targetSpeed = math.min(bhopSpeed, CFG.BhopCap)
	end
	local desired = move * targetSpeed

	-- SMOOTH MOVEMENT: lerp the horizontal velocity instead of snapping
	if (horiz - smoothVel).Magnitude > 40 then
		smoothVel = horiz -- something external (fling, explosion) moved us, don't fight it
	end
	if grounded then
		local rate = hasInput and CFG.MoveAccel or CFG.MoveDecel
		smoothVel = smoothVel:Lerp(desired, 1 - math.exp(-dt * rate))
		root.AssemblyLinearVelocity = Vector3.new(smoothVel.X, vel.Y, smoothVel.Z)
	else
		if chain and hasInput then
			-- in the air while hopping: keep momentum, steer a little, build toward bhop speed
			smoothVel = horiz:Lerp(desired, 1 - math.exp(-dt * CFG.AirControl))
			root.AssemblyLinearVelocity = Vector3.new(smoothVel.X, vel.Y, smoothVel.Z)
		else
			smoothVel = horiz
		end
	end

	-- FOOTSTEPS (by the material under you)
	if grounded then
		if landed then
			playStep(hum.FloorMaterial, 1)
			stepDist = 0
			lastLandT = now
		end
		if hasInput and not jumpHeld and smoothVel.Magnitude > 2 then
			stepDist += smoothVel.Magnitude * dt
			if stepDist >= CFG.StepStride then
				stepDist = 0
				playStep(hum.FloorMaterial, 0.6 + sprintAmount * 0.3)
			end
		elseif not hasInput then
			stepDist = CFG.StepStride * 0.7
		end
	end

	-- Stop the footstep sound the moment you stop walking (landing thuds finish playing)
	local walking = grounded and hasInput and not jumpHeld and smoothVel.Magnitude > 2
	if not walking and (now - lastLandT) > 0.35 then
		stopSteps()
	end

	moveWasAir = not grounded
end))

---------------------------------------------------------------------
-- STEP 1: remove last frame's offset BEFORE the default camera runs
---------------------------------------------------------------------
local lastOffset = CFrame.new()
local smoothPos = Vector3.new()
local smoothRot = Vector3.new()
local smoothPos2 = Vector3.new()
local smoothRot2 = Vector3.new()

RunService:BindToRenderStep("CamcorderUndo", Enum.RenderPriority.Camera.Value - 1, function()
	camera = workspace.CurrentCamera
	camera.CFrame = camera.CFrame * lastOffset:Inverse()
	lastOffset = CFrame.new()
end)

---------------------------------------------------------------------
-- STEP 2: apply fresh offset AFTER the default camera runs
---------------------------------------------------------------------
RunService:BindToRenderStep("CamcorderCam", Enum.RenderPriority.Camera.Value + 1, function(dt)
	camera = workspace.CurrentCamera
	local hum, root = getHumanoid()
	local t = tick()
	dt = math.min(dt, 1 / 20)

	-- Keep first person locked (games can try to switch it back)
	if player.CameraMode ~= Enum.CameraMode.LockFirstPerson then forceFirstPerson() end

	-- Battery drain (auto change when empty)
	if not changingBattery and CFG.BatteryDrain > 0 then
		battery = math.max(0, battery - CFG.BatteryDrain * (1 + motorLevel * 0.6 + sprintAmount * 0.2) * dt)
		if battery <= 10 and not lowWarned then
			lowWarned = true
			playOnce(beepSnd) -- low battery warning
		end
		if battery <= 0 and changeBattery then changeBattery() end
	end

	-- Sprint: speed + smoothing
	if hum ~= currentHum then
		currentHum = hum
		sprintApplied = false
	end
	local wantSprint = sprintHeld and hum ~= nil
	if wantSprint then
		if not sprintApplied then
			baseSpeed = hum.WalkSpeed
			sprintApplied = true
		end
		hum.WalkSpeed = baseSpeed * CFG.SprintMult
	elseif sprintApplied then
		if hum then hum.WalkSpeed = baseSpeed end
		sprintApplied = false
	end
	local moving0 = root and Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude > 2
	local sprintTarget = (wantSprint and moving0) and 1 or 0
	sprintAmount += (sprintTarget - sprintAmount) * math.min(dt * 5, 1)

	-- Running makes the camera motion faster and more energetic
	local runSpeed = root and Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude or 0
	local runFactor = math.clamp((runSpeed - 12) / 12, 0, 1) * CFG.RunBoost

	-- Zoom (hold + / -), smoothed like a motorized lens
	if zoomInHeld then zoomTarget = zoomTarget * (1 + dt * CFG.ZoomSpeed) end
	if zoomOutHeld then zoomTarget = zoomTarget / (1 + dt * CFG.ZoomSpeed) end
	zoomTarget = math.clamp(zoomTarget, 1, CFG.ZoomMax)
	local prevZoom = zoomNow
	zoomNow += (zoomTarget - zoomNow) * math.min(dt * 6, 1)
	local zoomSpeedNow = math.abs(zoomNow - prevZoom) / math.max(dt, 1e-3)

	-- Zoom motor sound: fades in while the lens moves, out when it stops
	local motorTarget = (zoomSpeedNow > 0.05 and not changingBattery) and CFG.MotorVolume or 0
	motorLevel += (motorTarget - motorLevel) * math.min(dt * (motorTarget > motorLevel and 14 or 8), 1)
	motorSnd.Volume = motorLevel
	motorSnd.PlaybackSpeed = 0.9 + math.clamp(zoomSpeedNow / 4, 0, 0.3)
	if not motorSnd.IsPlaying then pcall(function() motorSnd:Play() end) end

	-- Mic wind pickup: world wind + your own movement through the air
	local windSpeed = workspace.GlobalWind.Magnitude
	if root then
		local rel = root.AssemblyLinearVelocity - workspace.GlobalWind
		windSpeed = math.max(windSpeed, rel.Magnitude)
	end
	local windTarget = 0
	if not changingBattery then
		windTarget = math.clamp((windSpeed - CFG.WindThreshold) / math.max(CFG.WindMax - CFG.WindThreshold, 1), 0, 1)
	end
	windNow += (windTarget - windNow) * math.min(dt * CFG.WindFade, 1)
	windSnd.Volume = windNow * CFG.WindVolume
	windSnd.PlaybackSpeed = 0.9 + windNow * 0.25
	if windDist then
		windDist.Level = CFG.WindDistMin + (CFG.WindDistMax - CFG.WindDistMin) * windNow
	end
	if not windSnd.IsPlaying then pcall(function() windSnd:Play() end) end

	-- Focus hunts a little while the lens is moving
	if zoomSpeedNow > 0.3 then
		blurTarget = math.max(blurTarget, CFG.BlurMax * 0.4)
		blurHold = t + 0.12
	end

	-- Field of view = base + sprint, then divided by zoom (true zoom maths)
	local fovRad = math.rad(baseFOV + CFG.SprintFOV * sprintAmount)
	camera.FieldOfView = math.clamp(math.deg(2 * math.atan(math.tan(fovRad / 2) / zoomNow)), 5, 120)

	-- Turn sway
	local look = camera.CFrame.LookVector
	local rel = camera.CFrame:VectorToObjectSpace(look - lastLook)
	lastLook = look
	local rx = math.clamp(rel.X, -0.05, 0.05)
	local ry = math.clamp(rel.Y, -0.05, 0.05)
	swaySpring:shove(Vector3.new(-ry * 12, rx * 15, rx * 10) * CFG.SwayAmount)

	-- Walk bob + landing
	if hum and root then
		local speed = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
		local moving = speed > 1 and hum.FloorMaterial ~= Enum.Material.Air
		if moving then
			local prev = bobTime
			bobTime += dt * speed * 0.55 * (1 + runFactor * 0.9)
			if math.floor(prev / math.pi) ~= math.floor(bobTime / math.pi) then
				local side = (math.floor(bobTime / math.pi) % 2 == 0) and 1 or -1
				local s = math.clamp(speed / 16, 0.3, 1.6) * CFG.BobAmount * (1 + sprintAmount * 0.5) * (1 + runFactor * 0.6)
				bobSpring:shove(Vector3.new(side * 1.5 * s, -4.5 * s, side * 2.5 * s))
			end
		end
		local airborne = hum.FloorMaterial == Enum.Material.Air
		if wasAirborne and not airborne then
			local impact = math.clamp(-lastYVel / 30, 0, 2)
			landSpring:shove(Vector3.new(0, -14 * impact, 5 * impact) * CFG.LandShake)
			blurTarget = math.max(blurTarget, impact * CFG.BlurMax * 0.5)
			blurHold = t + 0.2
		end
		wasAirborne = airborne
		lastYVel = root.AssemblyLinearVelocity.Y
	end

	-- Door lean release
	if doorReleaseAt > 0 and t >= doorReleaseAt then
		doorReleaseAt = 0
		doorSpring.Target = Vector3.new()
		doorSpring:shove(Vector3.new(7, 4, -6))
	end

	-- Constant handheld wobble
	if t >= nextDrift then
		nextDrift = t + (0.2 + math.random() * 0.4) / (1 + runFactor * 1.2)
		driftSpring:shove(Vector3.new(
			(math.random() - 0.5) * 2.6,
			(math.random() - 0.5) * 2.6,
			(math.random() - 0.5) * 1.5) * CFG.DriftAmount)
	end

	-- SLOW drift off
	if t >= nextWander then
		nextWander = t + (5 + math.random() * 6) / CFG.WanderRate
		local d = CFG.WanderDeg
		if math.random() < 0.2 then
			wanderSpring.Target = Vector3.new()
		else
			wanderSpring.Target = Vector3.new(
				(math.random() - 0.5) * d * 0.5,
				(math.random() - 0.5) * d,
				(math.random() - 0.5) * d * 0.3)
		end
	end
	local nx = math.noise(t * 0.1, seed, 0) * 4
	local ny = math.noise(seed, t * 0.09, 0) * 5.5
	local nz = math.noise(0, seed, t * 0.07) * 2.2

	local sway   = clampVec(swaySpring:update(dt), CFG.MaxSwayDeg)
	local bob    = clampVec(bobSpring:update(dt), 6)
	local drift  = clampVec(driftSpring:update(dt), 5)
	local land   = clampVec(landSpring:update(dt), 6)
	local wander = wanderSpring:update(dt)
	local door   = clampVec(doorSpring:update(dt), 22)

	-- Shake is a bit calmer when zoomed in (it's magnified by the lens already)
	local I = CFG.Intensity / (zoomNow ^ 0.35) * (1 + runFactor * 0.3)

	local pos = Vector3.new(
		(bob.X * 0.15) * I + door.Z * 0.03,
		(bob.Y * 0.2 + land.Y * 0.2) * I + door.X * 0.035,
		0)
	local rotX = math.rad((sway.X + bob.Y * 1.2 + drift.Y * 2 + land.Y * 1.5 + wander.X + nx) * I + door.X)
	local rotY = math.rad((sway.Y + drift.X * 2 + wander.Y + ny) * I + door.Y)
	local rotZ = math.rad((sway.Z * 0.6 + bob.Z * 1.2 + drift.Z * 2 + wander.Z + nz) * I + door.Z)

	-- Smooth the final motion (low-pass filter) so everything glides
	local sm = CFG.Smoothness * (1 + runFactor) -- snappier when running
	local alpha = 1 - math.exp(-dt * sm)
	smoothPos = smoothPos:Lerp(pos, alpha)
	smoothRot = smoothRot:Lerp(Vector3.new(rotX, rotY, rotZ), alpha)
	-- second stage removes sharp corners for a silky glide
	local alpha2 = 1 - math.exp(-dt * sm * 1.5)
	smoothPos2 = smoothPos2:Lerp(smoothPos, alpha2)
	smoothRot2 = smoothRot2:Lerp(smoothRot, alpha2)

	lastOffset = CFrame.new(smoothPos2) * CFrame.Angles(smoothRot2.X, smoothRot2.Y, smoothRot2.Z)
	camera.CFrame = camera.CFrame * lastOffset

	-- Random blur
	if t >= nextBlur then
		nextBlur = t + (1.5 + math.random() * 5) / CFG.BlurRate
		local kind = math.random()
		if kind < 0.5 then
			blurTarget = CFG.BlurMax * (0.3 + math.random() * 0.7)
			blurHold = t + 0.15 + math.random() * 0.35
			dofTargetFar = 0.6 + math.random() * 0.4
			dofTargetNear = 0
		elseif kind < 0.8 then
			blurTarget = CFG.BlurMax * 0.25
			blurHold = t + 0.6 + math.random()
			dofTargetFar = 0.9
			dofTargetNear = 0.5
			dof.FocusDistance = 5 + math.random() * 60
			dof.InFocusRadius = 5 + math.random() * 25
		else
			blurTarget = CFG.BlurMax * 0.15
			blurHold = t + 0.08
		end
	end
	if t > blurHold then
		blurTarget = 0
		dofTargetFar, dofTargetNear = 0, 0
	end
	local k = (blurTarget > blurNow) and 14 or 5
	blurNow += (blurTarget - blurNow) * math.min(dt * k, 1)
	dofFar += (dofTargetFar - dofFar) * math.min(dt * 6, 1)
	dofNear += (dofTargetNear - dofNear) * math.min(dt * 6, 1)
	blur.Size = blurNow
	dof.FarIntensity = dofFar
	dof.NearIntensity = dofNear
end)

---------------------------------------------------------------------
-- VHS OVERLAY + BLACK BARS + BARREL LOOK + BUTTONS
---------------------------------------------------------------------
local DATE_TEXTURE = 10802404358
local VHS_IDS = {
	134269908677501, 111124494349559, 136551230135269, 139069729953442,
	73088870867534,  112220143820362, 71391698410192,  79676063868730,
	114303475309679, 85003079763052,
}

local function removeOld(parent)
	local g = parent and parent:FindFirstChild("CamcorderGui")
	if g then g:Destroy() end
end

local gui = Instance.new("ScreenGui")
gui.Name = "CamcorderGui"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 50
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function() gui.ScreenInsets = Enum.ScreenInsets.None end)

local parented = false
pcall(function()
	if gethui then
		removeOld(gethui())
		gui.Parent = gethui()
		parented = gui.Parent ~= nil
	end
end)
if not parented then
	pcall(function()
		local cg = game:GetService("CoreGui")
		removeOld(cg)
		gui.Parent = cg
		parented = gui.Parent ~= nil
	end)
end
if not parented then
	local pg = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	if pg then
		removeOld(pg)
		gui.Parent = pg
	end
end

local holder = Instance.new("Frame")
holder.AnchorPoint = Vector2.new(0.5, 0.5)
holder.Position = UDim2.fromScale(0.5, 0.5) -- stays put: VHS overlay does not shake
holder.Size = UDim2.fromScale(1, 1)
holder.BackgroundTransparency = 1
holder.ZIndex = 1
holder.Parent = gui

local function makeLayer(id, z)
	local img = Instance.new("ImageLabel")
	img.Size = UDim2.fromScale(1, 1)
	img.BackgroundTransparency = 1
	img.Image = asset(id)
	img.ScaleType = Enum.ScaleType.Stretch
	img.ImageTransparency = 1
	img.ZIndex = z
	img.Parent = holder
	return img
end

local layers = {}
for i, id in ipairs(VHS_IDS) do layers[i] = makeLayer(id, i) end

local dateLayer = makeLayer(DATE_TEXTURE, 20)
dateLayer.ImageTransparency = 0.05

local tint = Instance.new("Frame")
tint.Size = UDim2.fromScale(1, 1)
tint.BackgroundColor3 = Color3.fromRGB(20, 25, 20)
tint.BackgroundTransparency = 0.88
tint.BorderSizePixel = 0
tint.ZIndex = 0
tint.Parent = holder

-- BARREL / CRT LOOK -------------------------------------------------
local function makeStrip(rotation)
	local f = Instance.new("Frame")
	f.BackgroundColor3 = Color3.new(0, 0, 0)
	f.BorderSizePixel = 0
	f.ZIndex = 80
	f.Visible = CFG.BarrelOn
	f.Parent = gui
	local g = Instance.new("UIGradient")
	g.Rotation = rotation
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1 - CFG.VignetteDark),
		NumberSequenceKeypoint.new(1, 1),
	})
	g.Parent = f
	return f
end
local stripLeft   = makeStrip(0)
local stripRight  = makeStrip(180)
local stripTop    = makeStrip(90)
local stripBottom = makeStrip(270)
stripLeft.AnchorPoint   = Vector2.new(0, 0.5)
stripRight.AnchorPoint  = Vector2.new(1, 0.5)
stripTop.AnchorPoint    = Vector2.new(0.5, 0)
stripBottom.AnchorPoint = Vector2.new(0.5, 1)

local mask = Instance.new("Frame")
mask.AnchorPoint = Vector2.new(0.5, 0.5)
mask.Position = UDim2.fromScale(0.5, 0.5)
mask.BackgroundTransparency = 1
mask.ZIndex = 90
mask.Visible = CFG.BarrelOn
mask.Parent = gui
local maskCorner = Instance.new("UICorner")
maskCorner.Parent = mask
local maskStroke = Instance.new("UIStroke")
maskStroke.Color = Color3.new(0, 0, 0)
maskStroke.LineJoinMode = Enum.LineJoinMode.Round
maskStroke.Parent = mask

-- BLACK BARS (screen-centre anchored, huge)
local function makeBar()
	local bar = Instance.new("Frame")
	bar.BackgroundColor3 = Color3.new(0, 0, 0)
	bar.BorderSizePixel = 0
	bar.ZIndex = 100
	bar.Size = UDim2.fromOffset(4000, 8000)
	bar.Parent = gui
	return bar
end
local leftBar = makeBar()
leftBar.AnchorPoint = Vector2.new(1, 0.5)
local rightBar = makeBar()
rightBar.AnchorPoint = Vector2.new(0, 0.5)

-- BATTERY CHANGE SCREEN (black + eject icon, sits inside the 4:3 frame)
local cover = Instance.new("Frame")
cover.AnchorPoint = Vector2.new(0.5, 0.5)
cover.Position = UDim2.fromScale(0.5, 0.5)
cover.BackgroundColor3 = Color3.new(0, 0, 0)
cover.BorderSizePixel = 0
cover.ZIndex = 150
cover.Visible = false
cover.Parent = gui

local ejectIcon = Instance.new("ImageLabel")
ejectIcon.AnchorPoint = Vector2.new(0.5, 0.5)
ejectIcon.Position = UDim2.fromScale(0.5, 0.5)
ejectIcon.Size = UDim2.fromOffset(160, 160)
ejectIcon.BackgroundTransparency = 1
ejectIcon.Image = asset(IDS.Eject)
ejectIcon.ScaleType = Enum.ScaleType.Fit
ejectIcon.ZIndex = 151
ejectIcon.Parent = cover

-- BUTTONS
local function makeButton(text, w, h, textSize)
	local b = Instance.new("TextButton")
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.Size = UDim2.fromOffset(w, h)
	b.BackgroundColor3 = Color3.new(0, 0, 0)
	b.BackgroundTransparency = 0.45
	b.Font = Enum.Font.Code
	b.Text = text
	b.TextSize = textSize or 22
	b.TextColor3 = Color3.new(1, 1, 1)
	b.AutoButtonColor = false
	b.ZIndex = 200
	b.Parent = gui
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 10)
	c.Parent = b
	local s = Instance.new("UIStroke")
	s.Color = Color3.new(1, 1, 1)
	s.Thickness = 2
	s.Transparency = 0.3
	s.Parent = b
	return b
end

local function bindHold(btn, setter)
	keep(btn.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
			setter(true)
		end
	end))
	keep(btn.InputEnded:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
			setter(false)
		end
	end))
end

local sprintBtn = makeButton("SPRINT", 120, 54, 22)
local zoomInBtn = makeButton("+", 120, 54, 34)
local zoomOutBtn = makeButton("-", 120, 54, 34)
local batteryBtn = makeButton("RELOAD", 120, 44, 20)
bindHold(sprintBtn, function(v) sprintHeld = v end)
bindHold(zoomInBtn, function(v) zoomInHeld = v end)
bindHold(zoomOutBtn, function(v) zoomOutHeld = v end)
keep(batteryBtn.InputBegan:Connect(function(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
		if changeBattery then changeBattery() end
	end
end))

local zoomLabel = Instance.new("TextLabel")
zoomLabel.AnchorPoint = Vector2.new(0.5, 0.5)
zoomLabel.Size = UDim2.fromOffset(120, 30)
zoomLabel.BackgroundTransparency = 1
zoomLabel.Font = Enum.Font.Code
zoomLabel.TextSize = 20
zoomLabel.TextColor3 = Color3.new(1, 1, 1)
zoomLabel.Text = "ZOOM x1.0"
zoomLabel.ZIndex = 200
zoomLabel.Parent = gui

-- BATTERY ICON (top right of the frame)
local batteryIcon = Instance.new("Frame")
batteryIcon.AnchorPoint = Vector2.new(0.5, 0.5)
batteryIcon.Size = UDim2.fromOffset(140, 30)
batteryIcon.BackgroundTransparency = 1
batteryIcon.ZIndex = 200
batteryIcon.Parent = gui

local batteryPct = Instance.new("TextLabel")
batteryPct.Size = UDim2.fromOffset(64, 30)
batteryPct.BackgroundTransparency = 1
batteryPct.Font = Enum.Font.Code
batteryPct.TextSize = 20
batteryPct.TextXAlignment = Enum.TextXAlignment.Right
batteryPct.TextColor3 = Color3.new(1, 1, 1)
batteryPct.Text = "100%"
batteryPct.ZIndex = 200
batteryPct.Parent = batteryIcon

local batteryBody = Instance.new("Frame")
batteryBody.Position = UDim2.fromOffset(72, 2)
batteryBody.Size = UDim2.fromOffset(58, 26)
batteryBody.BackgroundTransparency = 1
batteryBody.ZIndex = 200
batteryBody.Parent = batteryIcon
local bodyCorner = Instance.new("UICorner")
bodyCorner.CornerRadius = UDim.new(0, 4)
bodyCorner.Parent = batteryBody
local bodyStroke = Instance.new("UIStroke")
bodyStroke.Color = Color3.new(1, 1, 1)
bodyStroke.Thickness = 2
bodyStroke.Parent = batteryBody

local batteryNub = Instance.new("Frame")
batteryNub.Position = UDim2.fromOffset(131, 9)
batteryNub.Size = UDim2.fromOffset(5, 12)
batteryNub.BackgroundColor3 = Color3.new(1, 1, 1)
batteryNub.BorderSizePixel = 0
batteryNub.ZIndex = 200
batteryNub.Parent = batteryIcon

local batteryInner = Instance.new("Frame")
batteryInner.Position = UDim2.fromOffset(3, 3)
batteryInner.Size = UDim2.new(1, -6, 1, -6)
batteryInner.BackgroundTransparency = 1
batteryInner.ZIndex = 200
batteryInner.Parent = batteryBody

local batteryFill = Instance.new("Frame")
batteryFill.Size = UDim2.fromScale(1, 1)
batteryFill.BackgroundColor3 = Color3.fromRGB(90, 255, 90)
batteryFill.BorderSizePixel = 0
batteryFill.ZIndex = 200
batteryFill.Parent = batteryInner

-- MIC INDICATOR (top left of the frame): bar fills and turns red when wind is picked up
local micGui = Instance.new("Frame")
micGui.AnchorPoint = Vector2.new(0.5, 0.5)
micGui.Size = UDim2.fromOffset(150, 30)
micGui.BackgroundTransparency = 1
micGui.ZIndex = 200
micGui.Parent = gui

local micLabel = Instance.new("TextLabel")
micLabel.Size = UDim2.fromOffset(52, 30)
micLabel.BackgroundTransparency = 1
micLabel.Font = Enum.Font.Code
micLabel.TextSize = 20
micLabel.TextXAlignment = Enum.TextXAlignment.Left
micLabel.TextColor3 = Color3.new(1, 1, 1)
micLabel.Text = "MIC"
micLabel.ZIndex = 200
micLabel.Parent = micGui

local micBar = Instance.new("Frame")
micBar.Position = UDim2.fromOffset(54, 8)
micBar.Size = UDim2.fromOffset(92, 14)
micBar.BackgroundTransparency = 1
micBar.ZIndex = 200
micBar.Parent = micGui
local micStroke = Instance.new("UIStroke")
micStroke.Color = Color3.new(1, 1, 1)
micStroke.Thickness = 2
micStroke.Parent = micBar

local micFill = Instance.new("Frame")
micFill.Position = UDim2.fromOffset(2, 2)
micFill.Size = UDim2.new(0, 0, 1, -4)
micFill.BackgroundColor3 = Color3.fromRGB(90, 255, 90)
micFill.BorderSizePixel = 0
micFill.ZIndex = 200
micFill.Parent = micBar

-- Preload everything (images + sounds)
task.spawn(function()
	local list = { dateLayer, ejectIcon, motorSnd, beepSnd, batterySnd, windSnd }
	for _, l in ipairs(layers) do table.insert(list, l) end
	pcall(function() ContentProvider:PreloadAsync(list) end)
end)

---------------------------------------------------------------------
-- BATTERY CHANGE SEQUENCE
---------------------------------------------------------------------
changeBattery = function()
	if changingBattery then return end
	changingBattery = true

	-- release held controls and reset lens
	sprintHeld, zoomInHeld, zoomOutHeld = false, false, false
	zoomTarget = 1

	cover.Visible = true
	for _, b in ipairs({ sprintBtn, zoomInBtn, zoomOutBtn, batteryBtn, zoomLabel, batteryIcon, micGui }) do
		b.Visible = false
	end

	playOnce(beepSnd)

	task.spawn(function()
		task.wait(0.5)
		local t0 = tick()
		local done = false
		local conn = batterySnd.Ended:Connect(function() done = true end)
		playOnce(batterySnd)

		while not done and (tick() - t0) < CFG.BatteryMaxTime do
			task.wait(0.1)
		end
		conn:Disconnect()

		local remaining = CFG.BatteryMinTime - (tick() - t0)
		if remaining > 0 then task.wait(remaining) end

		-- new battery is in: back to normal
		battery = 100
		lowWarned = false
		cover.Visible = false
		for _, b in ipairs({ sprintBtn, zoomInBtn, zoomOutBtn, batteryBtn, zoomLabel, batteryIcon, micGui }) do
			b.Visible = true
		end
		if CFG.BeepOnFinish then playOnce(beepSnd) end
		changingBattery = false
	end)
end

-- Startup beep
playOnce(beepSnd)

---------------------------------------------------------------------
-- MAIN GUI LOOP
---------------------------------------------------------------------
local active = {}
local nextSwap, nextGlitch, glitchEnd = 0, 0, 0
local audioSeed = math.random() * 100

keep(RunService.RenderStepped:Connect(function()
	local now = tick()

	local vp = workspace.CurrentCamera.ViewportSize
	if vp.X > 0 and vp.Y > 0 then
		local frameW = math.min(vp.Y * CFG.AspectRatio, vp.X)
		local H = vp.Y

		leftBar.Position = UDim2.new(0.5, -frameW / 2, 0.5, 0)
		rightBar.Position = UDim2.new(0.5, frameW / 2, 0.5, 0)
		holder.Size = UDim2.fromOffset(frameW * 1.04, H * 1.04)
		cover.Size = UDim2.fromOffset(frameW, H)

		-- Barrel look sizing
		local r = H * CFG.CornerPct
		mask.Size = UDim2.fromOffset(frameW, H)
		maskCorner.CornerRadius = UDim.new(0, r)
		maskStroke.Thickness = r * 1.6 + 40

		local sw, sh = frameW * 0.14, H * 0.14
		stripLeft.Position = UDim2.new(0.5, -frameW / 2, 0.5, 0)
		stripLeft.Size = UDim2.new(0, sw, 1, 0)
		stripRight.Position = UDim2.new(0.5, frameW / 2, 0.5, 0)
		stripRight.Size = UDim2.new(0, sw, 1, 0)
		stripTop.Position = UDim2.new(0.5, 0, 0, 0)
		stripTop.Size = UDim2.new(0, frameW, 0, sh)
		stripBottom.Position = UDim2.new(0.5, 0, 1, 0)
		stripBottom.Size = UDim2.new(0, frameW, 0, sh)

		-- Buttons: right side inside the frame
		local bx = frameW / 2 - 90
		sprintBtn.Position = UDim2.new(0.5, bx, 1, -150)
		zoomOutBtn.Position = UDim2.new(0.5, bx, 1, -250)
		zoomInBtn.Position = UDim2.new(0.5, bx, 1, -330)
		zoomLabel.Position = UDim2.new(0.5, bx, 1, -385)
		batteryBtn.Position = UDim2.new(0.5, bx, 1, -435)
		batteryIcon.Position = UDim2.new(0.5, frameW / 2 - 100, 0, 45)
		micGui.Position = UDim2.new(0.5, -frameW / 2 + 100, 0, 45)
	end

	-- Button feedback
	sprintBtn.BackgroundTransparency = sprintHeld and 0.15 or 0.45
	sprintBtn.TextColor3 = sprintHeld and Color3.fromRGB(255, 90, 90) or Color3.new(1, 1, 1)
	zoomInBtn.BackgroundTransparency = zoomInHeld and 0.15 or 0.45
	zoomOutBtn.BackgroundTransparency = zoomOutHeld and 0.15 or 0.45
	zoomLabel.Text = string.format("ZOOM x%.1f", zoomNow)
	-- Battery icon: fill level, colour, blink when low
	local pct = math.clamp(battery, 0, 100)
	local lowBlink = pct < 15 and (math.floor(now * 2) % 2 == 0)
	batteryFill.Size = UDim2.fromScale(pct / 100, 1)
	local bcol = (pct > 50) and Color3.fromRGB(90, 255, 90)
		or (pct > 20) and Color3.fromRGB(255, 210, 60)
		or Color3.fromRGB(255, 70, 70)
	batteryFill.BackgroundColor3 = bcol
	batteryFill.Visible = not lowBlink
	bodyStroke.Color = (pct < 15) and bcol or Color3.new(1, 1, 1)
	batteryNub.BackgroundColor3 = bodyStroke.Color
	batteryPct.TextColor3 = (pct < 15) and bcol or Color3.new(1, 1, 1)
	batteryPct.Text = string.format("%d%%", math.floor(pct + 0.5))

	-- Mic indicator + wind distortion
	micFill.Size = UDim2.new(windNow, -4 * windNow, 1, -4)
	local micCol = (windNow > 0.6) and Color3.fromRGB(255, 70, 70)
		or (windNow > 0.25) and Color3.fromRGB(255, 210, 60)
		or Color3.fromRGB(90, 255, 90)
	micFill.BackgroundColor3 = micCol
	micLabel.Text = (windNow > 0.25) and "WIND" or "MIC"
	micLabel.TextColor3 = (windNow > 0.6) and micCol or Color3.new(1, 1, 1)
	if dist then dist.Level = 0.06 + windNow * 0.25 end

	-- Shuffle VHS overlays (flicker only, the overlay itself never moves)
	if now >= nextSwap then
		nextSwap = now + 0.06 + math.random() * 0.08
		for _, l in ipairs(layers) do l.ImageTransparency = 1 end
		active = {}
		for _ = 1, math.random(2, 3) do
			local l = layers[math.random(1, #layers)]
			l.ImageTransparency = 0.55 + math.random() * 0.3
			table.insert(active, l)
		end
	end

	-- Glitch burst (brightness flicker only, no position shake)
	if now >= nextGlitch then
		nextGlitch = now + 2 + math.random() * 5
		glitchEnd = now + 0.1 + math.random() * 0.2
	end
	local glitching = now < glitchEnd

	if glitching then
		for _, l in ipairs(active) do l.ImageTransparency = 0.3 end
		dateLayer.ImageTransparency = 0.25 + math.random() * 0.3
	else
		dateLayer.ImageTransparency = (math.random() < 0.03) and 0.4 or 0.05
	end

	-- Muffled tape audio
	if pitch then
		local wow = math.noise(now * 0.6, audioSeed, 0) * 0.02
		pitch.Octave = glitching and (0.95 + math.random() * 0.02) or (1 + wow)
	end
	if eq then
		eq.HighGain = glitching and (CFG.MuffleHigh - 12) or CFG.MuffleHigh
	end
end))

print("[Camcorder] running")

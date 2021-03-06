-- Automatic mining program by valvate.
-- Put everything in a function because i can
-- TODO:
-- Make it dig mines in a circle
-- Make it check fuel (add fuel calculation for going to a position in val_lib)
-- Make it remotely controlable through websockets
-- Create a startup file to contiune when the server restarts.

local t = require("val_lib")
local inventory
local debug_level = 3
local logfile			= "minerJesus.log"
local doLogging		= true
local debugging   = false

local websocket_host = "ws://nh.zapto.org:8423"
local use_websockets = false
local c
local err

local safetyBuffer = 300 -- Fuel safety buffer
local startFuel
local space = 1 -- How much to move forward before quarrying

-- Manage args
local args = { ... }

if #args ~= 1 then
	print("Usage: minerJesus <quarrySize>")
	return
end

local quarrySize = tonumber(args[1])
if type(quarrySize) ~= "number" then
	print("quarrySize must be a number.")
end

-- Logger function
local function log(msg, msg_level)
	if not msg_level then
		log("[ERROR] msg_level is nil", 1)
		msg_level = 4
	end

	if msg_level <= debug_level then
		print(msg)
		t.writeToFile(msg, logfile, "a")
	end
	if msg_level == 0 then
		error()
	end
end

-- Return a map of your inventory
local function getInvMap()
	local inv = {}
	local item

	for i=1,16 do
		item = turtle.getItemDetail(i)
		if item then
			inv[i] = item
		else
			inv[i] = "empty"
		end
	end

	return inv
end

local function forward()
	while not t.forward() do
		turtle.attack()
		t.dig()
	end
end

local function down()
	while not t.down() do
		turtle.attackDown()
		t.digDown()
	end
end

local function up()
	while not t.up() do
		turtle.attackUp()
		t.digUp()
	end
end

local function say(msg)
	if use_websockets then
		-- Says stuff over websocket
		log("[DEBUG] Saying "..msg.." Over websocket", 4)
		local status = pcall(c.send, msg)
		if not status then
			log("[INFO] Failed to send to server, closing connection...", 3)
			pcall(c.close)
			use_websockets = false
		end
	end
end

-- Talk about the stuff in your inventory
local function sayInv()
	inventory = getInv()
	local text = ""

	for i=1,16 do
		if inventory[i] ~= "empty" then

			text = text:sub(":(.+)")..inventory[i]
		end
	end
	return text
end

-- Refuel if you need to
local function refuel()
	if turtle.getFuelLevel() < (t.calcFuelForPos("home") + safetyBuffer) then
		local slot = 0
		local item
		local prevSlot = turtle.getSelectedSlot()

		-- While its in your inventory
		while slot do
			slot, item = inInv()
			if slot ~= 0 then
				turtle.select(slot)
				turtle.refuel(item.count)
			end
		end
		turtle.select(prevSlot)
	end

	if turtle.getFuelLevel() < 1000 then
		gotoPos("home")
		log("[FATAL] Out of fuel ):", 0)
	end
end

local function inInvList(list, itemName)
	local slot, item
	for index, value in pairs(list) do
		slot, item = inInv(itemName)
		if slot and item then
			return slot, item
		end
	end
	return nil, nil
end

local function inInv(itemName)
	inventory = getInvMap()
	for slot,item in pairs(inventory) do
		if item ~= "empty" and item.name == itemName then
			return slot, item
		end
	end
	return nil, nil
end


-- Drops all items into chest
local function dropOff()
	inventory = getInvMap()
	t.saveCurrentPos("pre dropoff spot")
	t.gotoPos("home")
	local prevSlot = turtle.getSelectedSlot()
	for i=1,16 do
		-- Strange glitch where it says depositing bucket, even through bucket is in slot 16.
		if inventory and inventory[i] ~= "empty" then
			if inventory[i].name ~= "minecraft:bucket" then
				turtle.select(i)
				log("[INFO] Depositing "..tostring(inventory[i].count).." "..inventory[i].name:match(":(.+)"), 3)
				say("Depositing "..tostring(inventory[i].count).." "..inventory[i].name:match(":(.+)"))
				turtle.dropDown(inventory[i].count)
			end
		end
	end
	turtle.select(prevSlot)
	t.gotoPos("pre dropoff spot")
end

local function refuelAll()
	local prevSlot = turtle.getSelectedSlot()
	for i=1,15 do
		turtle.select(i)
		turtle.refuel(64)
	end
	turtle.select(prevSlot)
end

-- I bet i could do the faster, but copy and paste is faster :^)
local function checkForLava()
		-- If you found the lava juice, slurp it up and refuel
		local _, item1   = turtle.inspect()
		local _, item2 = turtle.inspectDown()

		if item1.name and item1.name == "minecraft:lava" or "minecraft:flowing_lava" then
			local prevSlot = turtle.getSelectedSlot()

			turtle.select(16)
			if turtle.place() and turtle.refuel(1) then
				log("[INFO] Found lava refueling...", 3)
				say("slurp slurp gotta slurp that lava")
				say("My fuel level is now "..tostring(turtle.getFuelLevel()))
				log("[INFO] My fuel level is now "..tostring(turtle.getFuelLevel(), 3))
			end

			turtle.select(prevSlot)
		end
		if item1.name and item1.name == "minecraft:lava" or "minecraft:flowing_lava" then
			local prevSlot = turtle.getSelectedSlot()

			turtle.select(16)
			if turtle.placeDown() and turtle.refuel(1) then
				log("[INFO] Found lava refueling...", 3)
				say("shopromsdhdhfshorhslrp gotta slurp that lava shropglonpshrulp")
				log("[INFO] My fuel level is now "..turtle.getFuelLevel(), 3)
			end

			turtle.select(prevSlot)
		end
end

local function mine()
	t.saveCurrentPos("mine top")
	while true do
		while turtle.attack() do end
		t.dig()
		-- Break from the loop at bedrock
		if not t.digDown() and not turtle.attackDown() and not t.down() then
			break
		end

		checkForLava()
	end
	refuelAll()
	t.gotoPos("mine top")
end

-- Return true if you have space in your inventory, false if not
local function haveSpace()
	for i=1,15 do
		if turtle.getItemCount(i) == 0 then
			return true
		end
	end
	return false
end

local function iShouldReturnHome()
	-- If you don't have space return home
	if haveSpace() == false then
		return true
	end

	-- Check that you have enough fuel
	local fuelNeeded = t.calcFuelForPos("home")
	if fuelNeeded > turtle.getFuelLevel() then
		log("[WARNING] We don't have enough fuel to return home, trying to get there anyways", 2)
		say("no fuel juice i do try get home")
		return true
	elseif fuelNeeded > (turtle.getFuelLevel() * 2) then
		log("[INFO] Can't contiune, out of fuel. returning home...", 3)
		return true
	end
	return false
end

local function createStartup()
	-- Create startup file for safety
	if fs.exists("startup") then
		if fs.exists("oldstartup") then
			log("[FATAL] oldstartup exists, please delete or rename it", 0)
		end
		fs.move("startup", "oldstartup")
	end

	local safety = [[
local t = require("val_lib")
t.gotoPos("home")
print("[FATAL] Server restarted or my chunk got unloaded.")
fs.delete("safety")
	]]

	local f = fs.open("startup", "w")
	f.write("\nshell.run(\"safety\")")
	f.close()

	local f = fs.open("safety", "w")
	f.write(safety)
	f.close()
end

-- Ran on start
local function init()
	-- Clear the logfile at the start
	fs.delete(logfile)

	t.saveCurrentPos("home")
	-- Required for dropOff()
	inventory = getInvMap()

	-- Check if have a bucket
	local bSlot
	local slot, item = inInv("minecraft:bucket")
	if slot then
		if item.count > 1 then
			log("[FATAL] Only one bucket please!", 0)
		end
	else
		log("[FATAL] Please insert one bucket into my inventory!", 0)
	end

	if turtle.getFuelLevel() < 1000 then
		log("[FATAL] I need at least 1000 fuel to start off", 0)
	end

	turtle.select(1)
	if use_websockets then
		log("[INFO] Trying to connect via websockets", 3)
		c, err = http.websocket(websocket_host)
		if err ~= nil then
			log("[FATAL] "..err, 0)
			-- In case it was true and since we failed it should be false
			use_websockets = false
		end
	end

	-- Deal with quarrySize
	quarrySize = math.ceil(quarrySize / 2)
	-- Make sure its even
	if quarrySize % 2 ~= 0 then quarrySize = quarrySize + 1 end
	-- Drop your items into the chest
	dropOff()

	-- Put the bucket in the right slot
	turtle.select(slot)
	turtle.transferTo(16)

	startFuel = turtle.getFuelLevel()
	createStartup()
end

local function main()
	-- Go to the first mining position.
	for i=1,space do
		t.dig()
		t.forward()
	end

	t.saveCurrentPos("quarry")
	for main=1,quarrySize do
		for line=1,quarrySize do
			mine()
			t.cleanInventory()
			for i=1,2 do
				forward()
			end
		end

		if iShouldReturnHome() then
			inventory = getInvMap()
			dropOff()
		end

		-- Goes to the next line for digging.
		if main < quarrySize then
			t.gotoPos("quarry")
			t.goto(t.x + 1, t.y, t.z, t.orientation)
		else
			t.gotoPos("home")
		end
	end
	t.gotoPos("home")
end

-- Run the shiet
init()
-- If we're debugging don't pcall main
if debugging == true then
	main()
else
	local status = pcall(main)
	if not status then
		print("Miner jesus crashed, or you terminated him")
		say("oh god why why did you kill me, i thought we were buddies... did i do something wrong?")
		print("Going home...")
		t.gotoPos("home")
	end
	print("I started with "..tostring(startFuel).." fuel")
	print("I ended with "..tostring(turtle.getFuelLevel()).." fuel")

	-- Cleanup
	fs.delete("safety")
	fs.delete("startup")
	fs.move("oldstartup", "startup")
	fs.delete("coords")
	fs.delete("savedPositions")
end

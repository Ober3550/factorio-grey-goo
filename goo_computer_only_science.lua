-- Input Signal Key:
-- - red[some-item] - The number of that item in the logistic network, negative if there is unsatisfied demand
-- - green[ore-type] - The amount of ore appearing on the resource scanner
-- Output Signal Key:
-- - out['red/signal-X'] - The X coordinate to survey
-- - out['red/signal-Y'] - The Y coordinate to survey
-- - out['red/signal-W'] - The width of the survey
-- - out['red/signal-H'] - The height of the survey
-- - out['construction-robot'] - The index of the blueprint to deploy
-- - out['signal-X'] - The X coordinate to deploy the next blueprint
-- - out['signal-Y'] - The Y coordinate to deploy the next blueprint
-- - out['signal-check'] - 1 if now is a good time for construction and research,
--                         0 otherwise
-- (Note: The red wire goes to the resource scanner, the green wire goes to the
-- blueprint deployer and also feeds back to the input)
local DEBUG = false
local PAUSE = false

local MAX_MEGATILES = 484
local MAX_RESEARCH_TILES = 25

local PIN_OFFSET_X = -47
local PIN_OFFSET_Y = 10

local DEPLOYER_OFFSET_X = 6
local DEPLOYER_OFFSET_Y = 1

local newSignal = 0
local tagSignal = nil

if not var.tilesBuilt then
    var.tilesBuilt = 0
end

-- Convert the input signals to local variables for readability
local currently_constructed_megatiles = math.floor(var.tilesBuilt / 8) + 1
local currently_constructed_research_tiles = red['signal-dot']
local available_logistic_bots = red['logistic-robot']
local total_logistic_bots = red['signal-B']
local available_construction_bots = red['signal-C']
local total_construction_bots = red['construction-robot']
local accumulator_charge = red['signal-E']
local lastSignal = green['signal-P']

local busy_construction_bots = total_construction_bots - available_construction_bots
-- We wait less the larger the factory is,
-- since overproduction in the late game is less catastrophic.
local waiting_on_construction_bots = busy_construction_bots > (currently_constructed_megatiles / 25) + 1
local currently_in_logistic_shock = available_logistic_bots < (total_logistic_bots / 10)
-- This will only happen in biter runs
local currently_in_construction_shock = total_construction_bots < 150

-- This combined logic ensures that we keep building power megatiles even if
-- the power situation has temporarily recovered
var.currently_in_power_shock = accumulator_charge < 40 or (var.currently_in_power_shock and accumulator_charge < 50)
var.need_power = var.currently_in_power_shock

local can_build_tile = not waiting_on_construction_bots and not currently_in_logistic_shock and
                           not currently_in_construction_shock

out = {}

local MEGA_BRAIN = 115
local MEGA_BASE = 1
local MEGA_SOLAR = 2
local SMALL_SOLAR = 108
local SMALL_MINING = 53
local SMALL_MINING_URANIUM = 54
local MEGA_NUCLEAR = 106
local DECON_TREES = 109
local MEGA_COAL_LIQUEFACTION = 110
local SMALL_ARTILLERY = 114
local SMALL_LABS = 9

-- Each of these modules is a hardcoded sequence to start the whole process
local mall_sequence = {{
    name = 'smart-smelter',
    outSignal = 116
}, {
    name = 'intermediates',
    outSignal = 117
}, {
    name = 'mall-1',
    outSignal = 118
}, {
    name = 'smart-smelter',
    outSignal = 116
}, {
    name = 'mall-2',
    outSignal = 119
}, {
    name = 'concrete',
    outSignal = 79
}, {
    name = 'uranium',
    outSignal = 104
}, {
    name = 'mall-3',
    outSignal = 120
}}

-- Each item is in the first tier that does not contain any of its ingredients
local ITEM_TIERS = {{{
    name = 'water-barrel',
    outSignal = 86
}, {
    name = 'iron-plate',
    outSignal = 3
}, {
    name = 'copper-plate',
    outSignal = 4
}, {
    name = 'stone-brick',
    outSignal = 5
}}, {{
    name = 'iron-gear-wheel',
    outSignal = 7
}, {
    name = 'steel-plate',
    outSignal = 6
}}, {{
    name = 'electronic-circuit',
    outSignal = 12
}, {
    name = 'plastic-bar',
    outSignal = 21
}, {
    name = 'sulfur',
    outSignal = 25
}}, {{
    name = 'advanced-circuit',
    outSignal = 23
}, {
    name = 'sulfuric-acid-barrel',
    outSignal = 32
}}, {{
    name = 'processing-unit',
    outSignal = 36
}, {
    name = 'battery',
    outSignal = 33
}}, {{
    name = 'engine-unit',
    outSignal = 24
}}, {{
    name = 'electric-engine-unit',
    outSignal = 35
}}, {{
    name = 'flying-robot-frame',
    outSignal = 37
}}, {{
    name = 'speed-module-3',
    outSignal = 63
}, {
    name = 'productivity-module-3',
    outSignal = 65
}}, {{
    name = 'low-density-structure',
    outSignal = 31
}, {
    name = 'rocket-fuel',
    outSignal = 43
}}, {{
    name = 'piercing-rounds-magazine',
    outSignal = 18
}, {
    name = 'productivity-module',
    outSignal = 28
}, {
    name = 'electric-furnace',
    outSignal = 29
}, {
    name = 'satellite',
    outSignal = 44
}}, {{
    name = 'automation-science-pack',
    outSignal = 8
}, {
    name = 'logistic-science-pack',
    outSignal = 15
}, {
    name = 'military-science-pack',
    outSignal = 20
}, {
    name = 'chemical-science-pack',
    outSignal = 26
}, {
    name = 'production-science-pack',
    outSignal = 30
}, {
    name = 'utility-science-pack',
    outSignal = 38
}, {
    name = 'space-science-pack',
    outSignal = 47
}}}

delay = 30 * 60

local MEGA_SURVEY = 1
local MEGA_CHECK = 2
local MEGA_BUILD = 3
local MEGA_WAIT_SURVEY = 4
local MEGA_WAIT = 5
local MINI_SURVEY = 6
local MINI_CHECK = 7
local MINI_BUILD = 8
local MINI_WAIT_SURVEY = 9
local MINI_WAIT = 10
local STATE_NAMES = {"MEGA_SURVEY", "MEGA_CHECK", "MEGA_BUILD", "MEGA_WAIT_SURVEY", "MEGA_WAIT", "MINI_SURVEY",
                     "MINI_CHECK", "MINI_BUILD", "MINI_WAIT_SURVEY", "MINI_WAIT"}

local blueprint_book = green['blueprint-book'] == 1
if blueprint_book and not PAUSE then
    if not var.doneInit then
        if red['signal-info'] == 1 then
            var.doneInit = true
            var.last_nuclear_megatile = 0
            var.researchDeadline = math.huge
            var.need_artillery = false
            var.CURRENT_STATE = MEGA_SURVEY

            -- We have to track tilesBuilt as a variable because we can't trust the 
            -- input from the outside world. If part of a tile has been placed down,
            -- but not the combinator that reports its existence, we could end up
            -- deploying two different blueprints on the same tile space.
            -- Instead we wait for the numbers from the circuit network to match 
            -- the expected number from the variable before proceeeding.
            game.print('Initialized with ' .. var.tilesBuilt .. ' tiles built')

            -- var.megablock_x = DEPLOYER_OFFSET_X
            -- var.megablock_y = DEPLOYER_OFFSET_Y
            -- out['green/signal-X'] = var.megablock_x
            -- out['green/signal-Y'] = var.megablock_y
            -- out['green/construction-robot'] = BRAIN_TILE
            out['red/deconstruction-planner'] = -2

            for i = 1, #ITEM_TIERS do
                local current_tier = ITEM_TIERS[i]
                local tier_text = 'Tier ' .. i .. ': '
                for j = 1, #current_tier do
                    local currrent_item = current_tier[j]
                    tier_text = tier_text .. ' [img=item.' .. currrent_item.name .. ']'
                end
                game.print(tier_text)
            end
        end
    else
        if DEBUG then
            game.print("Current state: " .. STATE_NAMES[var.CURRENT_STATE])
        end
        local ghosts = {}
        local ignore_signals = {
            ["signal-X"] = true,
            ["signal-Y"] = true,
            ["signal-W"] = true,
            ["signal-H"] = true,
            ["signal-P"] = true,
            ["construction-robot"] = true,
            ["blueprint-book"] = true,
            ["coal"] = true,
            ["stone"] = true,
            ["uranium-ore"] = true,
            ["copper-ore"] = true,
            ["iron-ore"] = true,
            ["laser-turret"] = true
        }
        for k, v in pairs(green) do
            if ignore_signals[k] == nil then
                ghosts[#ghosts + 1] = k
            end
        end
        -- Module ghosts don't show up on the radar but we should still wait for them aslong as the modules are built
        if currently_constructed_megatiles > 3 then
            if red["productivity-module-3"] > 0 and red["productivity-module-3"] < 100 then
                ghosts[#ghosts + 1] = "productivity-module-3"
            end
            if red["productivity-module-3"] > 0 and red["speed-module-3"] < 100 then
                ghosts[#ghosts + 1] = "speed-module-3"
            end
        end
        if var.CURRENT_STATE == MEGA_SURVEY or var.CURRENT_STATE == MEGA_WAIT_SURVEY then
            local n = (var.tilesBuilt / 8) + 1
            local x = 0
            local y = 0
            local steps = 0
            local max_steps = 1
            local turns_taken = 0
            for i = 2, n, 1 do
                if turns_taken % 4 == 0 then
                    x = x - 1
                elseif turns_taken % 4 == 1 then
                    y = y - 1
                elseif turns_taken % 4 == 2 then
                    x = x + 1
                elseif turns_taken % 4 == 3 then
                    y = y + 1
                end
                steps = steps + 1
                if steps == max_steps then
                    steps = 0
                    turns_taken = turns_taken + 1
                end
                if steps == 0 and turns_taken % 2 == 0 then
                    max_steps = max_steps + 1
                end
            end

            var.megablock_x = x * 48 + DEPLOYER_OFFSET_X
            var.megablock_y = y * 48 + DEPLOYER_OFFSET_Y

            -- Area scanner
            out['red/signal-X'] = var.megablock_x - 25
            out['red/signal-Y'] = var.megablock_y - 25
            out['red/signal-W'] = 52
            out['red/signal-H'] = 52
            -- Deconstruct trees and rocks
            out['green/construction-robot'] = 109
            out['green/signal-X'] = var.megablock_x - 24
            out['green/signal-Y'] = var.megablock_y - 24
            out['green/signal-W'] = 50
            out['green/signal-H'] = 50

            if DEBUG then
                game.print('Surveying megatile ' .. n)
                game.print("Spiral x  : " .. x)
                game.print("Spiral y  : " .. y)
                game.print("Megatile x: " .. var.megablock_x)
                game.print("Megatile y: " .. var.megablock_y)
            end
            if var.CURRENT_STATE == MEGA_WAIT_SURVEY then
                var.CURRENT_STATE = MEGA_WAIT
            else
                var.CURRENT_STATE = MEGA_CHECK
            end

        elseif var.CURRENT_STATE == MEGA_CHECK then
            if currently_constructed_megatiles == 1 then
                if DEBUG then
                    game.print("Building brain megatile")
                end
                var.BUILD_MEGA = MEGA_BRAIN
                var.CURRENT_STATE = MEGA_BUILD
                var.FILLABLE_MEGA = true
            elseif currently_constructed_megatiles > 3 and
                (green['uranium-ore'] > 100000 or green['uranium-ore'] + green['iron-ore'] + green['copper-ore'] +
                    green['stone'] + green['coal'] > 1000000) then
                -- If the megatile has uranium, or has abundant resources,
                -- it must be mined (we'll use a blank patch and let the
                -- smaller surveys divy it up)
                game.print("Building mining megatile")
                var.BUILD_MEGA = MEGA_BASE
                var.CURRENT_STATE = MEGA_BUILD
                var.FILLABLE_MEGA = true
            elseif currently_constructed_megatiles == 2 or var.need_power then
                if red['nuclear-reactor'] >= 4 and red['heat-exchanger'] >= 48 and red['steam-turbine'] >= 52 and
                    red['heat-pipe'] >= 160 then
                    game.print("Building nuclear megatile")
                    var.BUILD_MEGA = MEGA_NUCLEAR
                    var.CURRENT_STATE = MEGA_BUILD
                    var.FILLABLE_MEGA = false
                elseif DEBUG then
                    game.print("Waiting for nuclear components")
                end
            elseif currently_constructed_megatiles == 3 or
                (red['petroleum-gas-barrel'] < 50 or red['light-oil-barrel'] < 50 or red['heavy-oil-barrel'] < 50) then
                game.print("Building coal liquefaction megatile")
                var.BUILD_MEGA = MEGA_COAL_LIQUEFACTION
                var.CURRENT_STATE = MEGA_BUILD
                var.FILLABLE_MEGA = false
            else
                -- If we're good on power and oil, build a blank megatile
                game.print("Building blank megatile")
                var.BUILD_MEGA = MEGA_BASE
                var.CURRENT_STATE = MEGA_BUILD
                var.FILLABLE_MEGA = true
            end
        elseif var.CURRENT_STATE == MEGA_BUILD then
            out['construction-robot'] = var.BUILD_MEGA
            out['green/signal-X'] = var.megablock_x
            out['green/signal-Y'] = var.megablock_y
            delay = 1
            var.CURRENT_STATE = MEGA_WAIT_SURVEY
            var.WAIT_COUNT = 0
        elseif var.CURRENT_STATE == MEGA_WAIT then
            if #ghosts > 0 then
                if var.WAIT_COUNT > 0 then
                    game.print("Waiting for ghosts:")
                    for _, v in pairs(ghosts) do
                        game.print(v)
                    end
                end
                var.CURRENT_STATE = MEGA_WAIT_SURVEY
                var.WAIT_COUNT = var.WAIT_COUNT + 1
            else
                game.print("Completed megatile " .. currently_constructed_megatiles)
                var.WAIT_COUNT = 0
                if var.FILLABLE_MEGA then
                    var.CURRENT_STATE = MINI_SURVEY
                else
                    var.CURRENT_STATE = MEGA_SURVEY
                    var.tilesBuilt = var.tilesBuilt + 8
                end
            end
        elseif var.CURRENT_STATE == MINI_SURVEY or var.CURRENT_STATE == MINI_WAIT_SURVEY then
            local n = (var.tilesBuilt % 8) + 1
            local x = -1
            local y = 0
            local steps = 0
            local max_steps = 1
            local turns_taken = 0
            for i = 2, n, 1 do
                steps = steps + 1
                if steps == max_steps then
                    steps = 0
                    turns_taken = turns_taken + 1
                end
                if steps == 0 and turns_taken % 2 == 0 then
                    max_steps = max_steps + 1
                end
                if turns_taken % 4 == 0 then
                    x = x - 1
                elseif turns_taken % 4 == 1 then
                    y = y - 1
                elseif turns_taken % 4 == 2 then
                    x = x + 1
                elseif turns_taken % 4 == 3 then
                    y = y + 1
                end
            end

            var.miniblock_x = var.megablock_x + x * 16
            var.miniblock_y = var.megablock_y + y * 16
            out['red/signal-X'] = var.miniblock_x - 5
            out['red/signal-Y'] = var.miniblock_y - 6
            out['red/signal-W'] = 14
            out['red/signal-H'] = 14

            if DEBUG then
                game.print('Surveying minitile ' .. var.tilesBuilt + 1)
                game.print("Spiral x  : " .. x)
                game.print("Spiral y  : " .. y)
                game.print("Minitile x: " .. var.megablock_x)
                game.print("Minitile y: " .. var.megablock_y)
            end

            if var.CURRENT_STATE == MINI_WAIT_SURVEY then
                var.CURRENT_STATE = MINI_WAIT
            else
                var.CURRENT_STATE = MINI_CHECK
            end
        elseif var.CURRENT_STATE == MINI_CHECK then
            if currently_constructed_megatiles == 1 then
                -- Create the mall modules in sequence
                local small_modules_ready = red['signal-green']
                if small_modules_ready >= var.tilesBuilt then
                    game.print("Building " .. mall_sequence[var.tilesBuilt + 1]["name"])
                    var.BUILD_MINI = mall_sequence[var.tilesBuilt + 1]['outSignal']
                    var.CURRENT_STATE = MINI_BUILD
                elseif DEBUG then
                    game.print("Waiting for module ready")
                end
            elseif (green['uranium-ore'] > 100000 and red['uranium-ore'] < 100000) then
                tagSignal = {
                    type = "item",
                    name = "uranium-ore"
                }
                game.print("Building uranium tile " .. '[img=item.uranium-ore]')
                var.BUILD_MINI = SMALL_MINING_URANIUM
                var.CURRENT_STATE = MINI_BUILD
            elseif (green['iron-ore'] > 100000 and red['iron-ore'] < 250000) or
                (green['copper-ore'] > 100000 and red['copper-ore'] < 250000) or
                (green['stone'] > 100000 and red['stone'] < 200000) or (green['coal'] > 100000 and red['coal'] < 250000) then
                local oreType = nil
                local maxAvailable = math.max(green['iron-ore'], green['copper-ore'], green['stone'], green['coal'])
                if green['iron-ore'] == maxAvailable then
                    oreType = 'iron-ore'
                elseif green['copper-ore'] == maxAvailable then
                    oreType = 'copper-ore'
                elseif green['stone'] == maxAvailable then
                    oreType = 'stone'
                elseif green['coal'] == maxAvailable then
                    oreType = 'coal'
                end
                tagSignal = {
                    type = "item",
                    name = oreType
                }
                game.print("Building mining tile " .. '[img=item.' .. oreType .. ']')
                var.BUILD_MINI = SMALL_MINING
                var.CURRENT_STATE = MINI_BUILD

            elseif var.need_artillery then
                var.need_artillery = false
                tagSignal = {
                    type = "item",
                    name = 'artillery-targeting-remote'
                }
                game.print("Building artillery tile" .. '[img=item.artillery-targeting-remote]')
                var.BUILD_MINI = SMALL_ARTILLERY
                var.CURRENT_STATE = MINI_BUILD
            elseif red['iron-ore'] < 1000 or red['copper-ore'] < 1000 or red['coal'] < 1000 or red['stone'] < 1000 then
                -- If we have no ores skip building more production
                game.print("Skipping tile to search for more ores")
                var.BUILD_MINI = 109
                var.CURRENT_STATE = MINI_BUILD
            else
                local most_needed_item = nil
                for i = 1, #ITEM_TIERS do
                    local current_tier = ITEM_TIERS[i]
                    local check_again = false
                    for j = 1, #current_tier do
                        local currrent_item = current_tier[j]
                        -- Check if this items demand is higher than the other ones
                        -- in the tier that we've seen
                        if red[currrent_item.name] < 0 and
                            (most_needed_item == nil or red[currrent_item.name] < red[most_needed_item.name]) then
                            -- If we just built this tile, don't choose it, but set
                            -- check_again to true in case nothing else in the tier
                            -- is in demand
                            if currrent_item.outSignal == lastSignal then
                                check_again = true
                            else
                                most_needed_item = currrent_item
                            end
                        end
                    end
                    -- If the only item in this tier that is in demand is the thing we
                    -- built last tile, then fine, we'll build another.
                    -- We do not want to start checking higher tiers, since they might
                    -- depend on this item.
                    if most_needed_item == nil and check_again then
                        for j = 1, #current_tier do
                            local currrent_item = current_tier[j]
                            if red[currrent_item.name] < 0 and
                                (most_needed_item == nil or red[currrent_item.name] < red[most_needed_item.name]) then
                                most_needed_item = currrent_item
                            end
                        end
                    end
                    if most_needed_item ~= nil then
                        out['signal-L'] = i
                        break
                    end
                end
                if most_needed_item ~= nil then
                    tagSignal = {
                        type = "item",
                        name = most_needed_item.name
                    }
                    game.print("Building prioritised item " .. '[img=item.' .. most_needed_item.name .. ']')
                    var.BUILD_MINI = most_needed_item.outSignal
                    var.CURRENT_STATE = MINI_BUILD
                elseif currently_constructed_research_tiles < MAX_RESEARCH_TILES and game.tick > var.researchDeadline then
                    tagSignal = {
                        type = "item",
                        name = "lab"
                    }
                    game.print("Building research tile")
                    var.BUILD_MINI = SMALL_LABS
                    var.CURRENT_STATE = MINI_BUILD
                    var.researchDeadline = math.huge
                elseif currently_constructed_research_tiles < MAX_RESEARCH_TILES and var.researchDeadline == math.huge then
                    -- If there's truly nothing we can build, start a timer and
                    -- if that's still the case when it's done, we'll build research.
                    -- This is to prevent new research tiles from sneaking in
                    -- during a really short pre-demand-shock period.
                    game.print('Setting a research deadline for ' .. (5 * 60) .. ' seconds')
                    var.researchDeadline = game.tick + (5 * 60 * 60)
                end
            end
        elseif var.CURRENT_STATE == MINI_BUILD then
            out['construction-robot'] = var.BUILD_MINI
            out['signal-X'] = var.miniblock_x
            out['signal-Y'] = var.miniblock_y
            delay = 1
            var.CURRENT_STATE = MINI_WAIT_SURVEY
            var.WAIT_COUNT = 0
        elseif var.CURRENT_STATE == MINI_WAIT then
            if #ghosts > 0 then
                if var.WAIT_COUNT > 0 then
                    game.print("Waiting for ghosts:")
                    for _, v in pairs(ghosts) do
                        game.print(v)
                    end
                end
                var.CURRENT_STATE = MINI_WAIT_SURVEY
                var.WAIT_COUNT = var.WAIT_COUNT + 1
            else
                game.print("Completed minitile " .. var.tilesBuilt)
                var.tilesBuilt = var.tilesBuilt + 1
                var.WAIT_COUNT = 0
                if var.tilesBuilt % 8 == 0 then
                    var.CURRENT_STATE = MEGA_SURVEY
                else
                    var.CURRENT_STATE = MINI_SURVEY
                end
            end
        end
    end
end

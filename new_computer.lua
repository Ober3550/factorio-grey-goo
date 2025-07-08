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
local MAX_MEGATILES = 484
local MAX_RESEARCH_TILES = 25

local PIN_OFFSET_X = -47
local PIN_OFFSET_Y = 10

local DEPLOYER_OFFSET_X = 6
local DEPLOYER_OFFSET_Y = 1

local newSignal = 0
local tagSignal = nil

-- Convert the input signals to local variables for readability
local currently_constructed_megatiles = red['signal-info']
local currently_constructed_research_tiles = red['signal-dot']
local available_logistic_bots = red['signal-A']
local total_logistic_bots = red['signal-B']
local available_construction_bots = red['signal-C']
local total_construction_bots = red['signal-D']
local accumulator_charge = red['signal-E']
local lastSignal = green['signal-P']
local small_modules_ready = red['signal-green']

local busy_construction_bots = total_construction_bots - available_construction_bots
-- We wait less the larger the factory is,
-- since overproduction in the late game is less catastrophic.
local waiting_on_construction_bots = busy_construction_bots > (currently_constructed_megatiles / 25) + 1
local currently_in_logistic_shock = available_logistic_bots < (total_logistic_bots / 10)
-- This will only happen in biter runs
local currently_in_construction_shock = total_construction_bots < 300

-- This combined logic ensures that we keep building power megatiles even if
-- the power situation has temporarily recovered
var.currently_in_power_shock = accumulator_charge < 40 or (var.currently_in_power_shock and accumulator_charge < 50)
var.need_power = (var.currently_in_power_shock or var.need_power)

local can_build_tile = not waiting_on_construction_bots and not currently_in_logistic_shock and
                           not currently_in_construction_shock

out = {}

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
local BRAIN_TILE = 115

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
    name = 'engine-unit',
    outSignal = 24
}, {
    name = 'barrel',
    outSignal = 85
}}, {{
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
}, {
    name = 'low-density-structure',
    outSignal = 31
}, {
    name = 'electric-engine-unit',
    outSignal = 35
}, {
    name = 'rocket-fuel',
    outSignal = 43
}}, {{
    name = 'battery',
    outSignal = 33
}, {
    name = 'processing-unit',
    outSignal = 36
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
    name = 'flying-robot-frame',
    outSignal = 37
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

local small_module_sequence = {{
    x = -16,
    y = 0
}, {
    x = -16,
    y = -16
}, {
    x = 0,
    y = -16
}, {
    x = 16,
    y = -16
}, {
    x = 16,
    y = 0
}, {
    x = 16,
    y = 16
}, {
    x = 0,
    y = 16
}, {
    x = -16,
    y = 16
}}

local blueprint_book = green['blueprint-book'] == 1
if blueprint_book then
    if not var.doneInit then
        if currently_constructed_megatiles == 1 then
            var.doneInit = true
            var.last_nuclear_megatile = 0
            var.researchDeadline = math.huge
            var.need_artillery = false

            -- We have to track tilesBuilt as a variable because we can't trust the 
            -- input from the outside world. If part of a tile has been placed down,
            -- but not the combinator that reports its existence, we could end up
            -- deploying two different blueprints on the same tile space.
            -- Instead we wait for the numbers from the circuit network to match 
            -- the expected number from the variable before proceeeding.
            var.tilesBuilt = red['blueprint-deployer']
            game.print('Initialized with ' .. var.tilesBuilt .. ' tiles built')

            game.print("deploying offset x: " .. DEPLOYER_OFFSET_X)
            game.print("deploying offset y: " .. DEPLOYER_OFFSET_Y)
            game.print("deploying index   : " .. BRAIN_TILE)
            out['green/signal-X'] = DEPLOYER_OFFSET_X
            out['green/signal-Y'] = DEPLOYER_OFFSET_Y
            out['green/construction-robot'] = BRAIN_TILE
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
    elseif var.tilesBuilt < 8 then
        if var.tilesBuilt == small_modules_ready then
            var.tilesBuilt = var.tilesBuilt + 1

            local small_module = mall_sequence[var.tilesBuilt]

            out['green/signal-X'] = DEPLOYER_OFFSET_X + small_module_sequence[var.tilesBuilt]['x']
            out['green/signal-Y'] = DEPLOYER_OFFSET_Y + small_module_sequence[var.tilesBuilt]['y']
            out['construction-robot'] = small_module['outSignal']
        end
    end
end

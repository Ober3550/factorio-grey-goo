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
    name = 'piercing-rounds-magazine',
    outSignal = 18
}}, {{
    name = 'plastic-bar',
    outSignal = 21
}, {
    name = 'lubricant-barrel',
    outSignal = 34
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
    name = 'transport-belt',
    outSignal = 13
}, {
    name = 'inserter',
    outSignal = 14
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

if not var.doneInit and red['blueprint-deployer'] > 0 then
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

if can_build_tile and currently_constructed_megatiles < MAX_MEGATILES then
    -- Megatile stuff
    if var.tilesBuilt % 8 == 0 and var.tilesBuilt / 8 >= currently_constructed_megatiles then
        if not var.is_surveying then
            var.is_surveying = true
            local n = currently_constructed_megatiles
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

            var.megablock_x = x * 48 + 2
            var.megablock_y = y * 48
            out['red/signal-X'] = var.megablock_x + 2
            out['red/signal-Y'] = var.megablock_y
            out['red/signal-W'] = 30
            out['red/signal-H'] = 30
            out['green/construction-robot'] = 109
            out['green/signal-X'] = var.megablock_x
            out['green/signal-Y'] = var.megablock_y
            out['green/signal-W'] = 50
            out['green/signal-H'] = 50
            game.print('Surveying megatile ' .. (currently_constructed_megatiles + 1))
            delay = 60
        else
            var.is_surveying = false

            -- If we're currently building something, keep building it.
            -- Unless it's blueprint 109, that's the tree-clearing blueprint
            -- applied during surveying
            if green['construction-robot'] > 0 and green['construction-robot'] ~= 109 then
                newSignal = green['construction-robot']
                -- The first Megatile should be nuclear
            elseif currently_constructed_megatiles == 1 then
                newSignal = MEGA_NUCLEAR
                var.tilesBuilt = var.tilesBuilt + 8
                -- If the megatile has uranium, or has abundant resources,
                -- it must be mined (we'll use a blank patch and let the
                -- smaller surveys divy it up)
            elseif green['uranium-ore'] > 100000 or green['uranium-ore'] + green['iron-ore'] + green['copper-ore'] +
                green['stone'] + green['coal'] > 1000000 then
                game.print((currently_constructed_megatiles + 1) .. '[img=item.laser-turret] [img=item.roboport]')
                newSignal = MEGA_BASE
                -- Only build power megatiles if we need power
            elseif var.need_power then
                -- - Don't build more than one nuclear plant in the first 9 megatiles
                -- - Don't build nuclear if we don't have at least 3 reactors
                --   in the logistic network (unless we're using infinichests,
                --   then go ahead, whatever)
                -- - Don't build nuclear if we built it in the last 2 megatiles
                if currently_constructed_megatiles > 10 and
                    (red['nuclear-reactor'] > 3 or (red['nuclear-reactor'] > -10000 and green['nuclear-reactor'] == 0)) and
                    currently_constructed_megatiles >= var.last_nuclear_megatile + 1 then
                    game.print((currently_constructed_megatiles + 1) ..
                                   '[img=item.nuclear-reactor] [img=item.steam-turbine]')
                    newSignal = MEGA_NUCLEAR
                    var.last_nuclear_megatile = currently_constructed_megatiles + 1
                else
                    game.print((currently_constructed_megatiles + 1) .. '[img=item.solar-panel] [img=item.accumulator]')
                    newSignal = MEGA_SOLAR
                end
                var.need_power = false
                var.tilesBuilt = var.tilesBuilt + 8
            elseif currently_constructed_megatiles < 9 then
                newSignal = MEGA_SOLAR
                var.tilesBuilt = var.tilesBuilt + 8
                -- If we're good on power, but light on oil products,
                -- build an oil processing megatile
            elseif lastSignal ~= 110 and
                (red['petroleum-gas-barrel'] < 0 or red['light-oil-barrel'] < 0 or red['heavy-oil-barrel'] < 0) then
                game.print((currently_constructed_megatiles + 1) ..
                               '[img=item.oil-refinery] [img=fluid.petroleum-gas] [img=fluid.light-oil] [img=fluid.heavy-oil]')
                newSignal = MEGA_COAL_LIQUEFACTION
                var.tilesBuilt = var.tilesBuilt + 8
                -- If we're good on power and oil, build a blank megatile
            else
                game.print((currently_constructed_megatiles + 1) .. '[img=item.laser-turret] [img=item.roboport]')
                newSignal = MEGA_BASE
            end
            var.is_paving = true

            out['construction-robot'] = newSignal
            lastSignal = newSignal

            local n = currently_constructed_megatiles
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

            -- Once the factory starts getting big, we want to build an 
            -- artillery turret after each time we round a corner.
            var.need_artillery = var.need_artillery or (currently_constructed_megatiles > 36 and steps == max_steps - 1)

            var.megablock_x = x * 48 + 2
            var.megablock_y = y * 48
            out['signal-X'] = var.megablock_x
            out['signal-Y'] = var.megablock_y
            delay = 60
        end

        -- If this isn't a megatile, check the tile and see if there are
        -- resources before building anything.
    elseif not var.is_surveying then
        var.is_surveying = true
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

        out['red/signal-X'] = var.megablock_x + x * 16 + 2
        out['red/signal-Y'] = var.megablock_y + y * 16
        out['red/signal-W'] = 10
        out['red/signal-H'] = 10
        game.print('Surveying tile ' .. (var.tilesBuilt + 1))
        delay = 60
    else
        if green['construction-robot'] > 0 then
            game.print('Redoing this for some reason...');
            newSignal = green['construction-robot']
        else
            if (green['uranium-ore'] > 100000 and red['uranium-ore'] < 100000) then
                tagSignal = {
                    type = "item",
                    name = "uranium-ore"
                }
                game.print(currently_constructed_megatiles .. ' * 8 + ' .. (var.tilesBuilt % 8 + 1) .. ' = ' ..
                               (var.tilesBuilt + 1) .. '[img=item.uranium-ore]')
                newSignal = SMALL_MINING_URANIUM
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
                game.print(currently_constructed_megatiles .. ' * 8 + ' .. (var.tilesBuilt % 8 + 1) .. ' = ' ..
                               (var.tilesBuilt + 1) .. '[img=item.' .. oreType .. ']')
                newSignal = SMALL_MINING
            elseif var.need_artillery then
                var.need_artillery = false
                tagSignal = {
                    type = "item",
                    name = 'artillery-targeting-remote'
                }
                newSignal = SMALL_ARTILLERY
                game.print(currently_constructed_megatiles .. ' * 8 + ' .. (var.tilesBuilt % 8 + 1) .. ' = ' ..
                               (var.tilesBuilt + 1) .. '[img=item.artillery-targeting-remote]')
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
                        return most_needed_item
                    end
                end

                if most_needed_item ~= nil then
                    tagSignal = {
                        type = "item",
                        name = most_needed_item.name
                    }
                    newSignal = most_needed_item.outSignal
                    game.print(currently_constructed_megatiles .. ' * 8 + ' .. (var.tilesBuilt % 8 + 1) .. ' = ' ..
                                   (var.tilesBuilt + 1) .. '[img=item.' .. most_needed_item.name .. ']')
                elseif currently_constructed_research_tiles < MAX_RESEARCH_TILES and game.tick > var.researchDeadline then
                    tagSignal = {
                        type = "virtual",
                        name = "signal-dot"
                    }
                    game.print(currently_constructed_megatiles .. ' * 8 + ' .. (var.tilesBuilt % 8 + 1) .. ' = ' ..
                                   (var.tilesBuilt + 1) .. ' Research!')
                    newSignal = SMALL_LABS
                    var.researchDeadline = math.huge
                    -- This is to prevent situations where we're waiting to see
                    -- if we can build more research but we're having a power crisis
                elseif var.currently_in_power_shock then
                    game.print(currently_constructed_megatiles .. ' * 8 + ' .. (var.tilesBuilt % 8 + 1) .. ' = ' ..
                                   (var.tilesBuilt + 1) .. ' Small Power Station')
                    newSignal = SMALL_SOLAR
                    -- If there's truly nothing we can build, start a timer and
                    -- if that's still the case when it's done, we'll build research.
                    -- This is to prevent new research tiles from sneaking in
                    -- during a really short pre-demand-shock period.
                elseif currently_constructed_research_tiles < MAX_RESEARCH_TILES and var.researchDeadline == math.huge then
                    game.print('Setting a research deadline in ' .. (5 * 60) .. ' seconds...')
                    var.researchDeadline = game.tick + (5 * 60 * 60)
                end
            end
        end

        out['construction-robot'] = newSignal
        lastSignal = newSignal

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

        local tileX = var.megablock_x + x * 16
        local tileY = var.megablock_y + y * 16
        out['signal-X'] = tileX
        out['signal-Y'] = tileY
        if tagSignal ~= nil then
            _api.game.get_player(1).force.add_chart_tag(_api.game.surfaces.nauvis, {
                position = {
                    x = tileX + PIN_OFFSET_X,
                    y = tileY + PIN_OFFSET_Y
                },
                icon = tagSignal
            })
        end
        if green['construction-robot'] == 0 and newSignal ~= 0 then
            var.tilesBuilt = var.tilesBuilt + 1
            var.is_surveying = false
            if var.researchDeadline ~= math.huge then
                game.print('Cancelling research deadline, ' .. math.ceil((var.researchDeadline - game.tick) / 60) ..
                               ' seconds were remaining')
                var.researchDeadline = math.huge
            end
        end
        delay = 120
    end
else
    var.is_surveying = false
end
out['signal-P'] = lastSignal
out['signal-check'] = (not currently_in_logistic_shock) and 1 or 0

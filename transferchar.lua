local PLUGIN = PLUGIN

PLUGIN.name = "TransferChar"
PLUGIN.author = "https://github.com/peyton2465"
PLUGIN.description = "Adds functionality to transfer Character saves between players temporarily. "
    .. "Transferred characters are returned to their original owner when the new owner "
    .. "Disconnects, changes out of the transferred character, or Server is restarted (in case of crashes)."

local function UpdateCharacterList(client, openMenu)
    if (!IsValid(client)) then return end

    ix.char.Restore(client, function(charList)
        net.Start(openMenu and "ixCharacterMenu" or "ixCharacterListUpdate")
            net.WriteUInt(#charList, 6)
            for _, v in ipairs(charList) do
                net.WriteUInt(v, 32)
            end
        net.Send(client)
    end, true)
end

local function ForceLoadCharacter(client, charID, callback)
    ix.char.Restore(client, function(charList)
        local character = ix.char.loaded[charID]
        
        if (character) then
            local currentChar = client:GetCharacter()
            
            if (currentChar) then
                currentChar:Save()
                for _, v in ipairs(currentChar:GetInventory(true)) do
                    if (istable(v)) then
                        v:RemoveReceiver(client)
                    end
                end
            end

            hook.Run("PrePlayerLoadedCharacter", client, character, currentChar)

            character:Setup()
            client:Spawn()

            hook.Run("PlayerLoadedCharacter", client, character, currentChar)
        end

        if (callback) then
            callback(character)
        end
    end, true)
end

if (SERVER) then
    util.AddNetworkString("ixCharacterListUpdate")

    local function RestoreCharacter(character, callback)
        if (!character) then return end

        local originalOwner = character:GetData("originalOwner")
        if (!originalOwner) then return end

        local charID = character:GetID()
        local currentOwner = character:GetPlayer()

        local function PerformRestore()
            -- Update the database to set the owner back to the original owner
            local query = mysql:Update("ix_characters")
                query:Update("steamid", originalOwner)
                query:Where("id", charID)
                query:Callback(function()
                    -- Remove the originalOwner data field
                    character:SetData("originalOwner", nil)
                    
                    -- We need to save the character to persist the removal of "originalOwner" data
                    character:Save(function()
                        -- Refresh the character list for the current owner (the admin)
                        if (IsValid(currentOwner)) then
                            ix.char.Restore(currentOwner, nil, true)
                            currentOwner:Notify("The character '" .. (character:GetName() or "#unknown") .. "' has been returned to its original owner " .. originalOwner .. ".")
                        end

                        -- Refresh the character list for the original owner if they are online
                        local originalPlayer = player.GetBySteamID64(originalOwner)
                        if (IsValid(originalPlayer)) then
                            UpdateCharacterList(originalPlayer, false)
                            originalPlayer:Notify("Your character '" .. (character:GetName() or "#unknown") .. "' has been returned to you.")
                        end
                        
                        print("[TransferChar] Restored character " .. charID .. " (" .. (character:GetName() or "Unknown") .. ") to original owner " .. originalOwner)

                        if (callback) then
                            callback()
                        end
                    end)
                end)
            query:Execute()
        end

        -- Call Save() first so spawnsaver captures the temporary owner's position
        if (IsValid(currentOwner) and currentOwner:GetCharacter() == character) then
            character:Save(function()
                PerformRestore()
            end)
        else
            PerformRestore()
        end

        -- Also update items to belong to the original owner
        local itemQuery = mysql:Update("ix_items")
            itemQuery:Update("player_id", originalOwner)
            itemQuery:Where("character_id", charID)
        itemQuery:Execute()
        
    end

    function PLUGIN:OnCharacterDisconnect(client, character)
        -- Check if character has an attribute for an original owner. 
        if (character:GetData("originalOwner")) then
            print("[TransferChar] Disconnect detected for transferred character " .. character:GetID())
            RestoreCharacter(character)
        end
    end

    function PLUGIN:PrePlayerLoadedCharacter(client, character, lastChar)
        -- If we switched FROM a borrowed character, save it first so spawnsaver captures the position
        if (lastChar and lastChar:GetData("originalOwner")) then
            print("[TransferChar] Character switch detected for transferred character " .. lastChar:GetID())
            RestoreCharacter(lastChar)
        end
    end

    function PLUGIN:DatabaseConnected()
        -- Restore any characters that might be stuck on temporary owners (e.g. crash)
        local query = mysql:Select("ix_characters")
            query:Select("id")
            query:Select("data")
            query:WhereLike("data", "%\"originalOwner\"%") -- Simple string search in JSON
            query:Callback(function(result)
                if (result) then
                    for _, row in ipairs(result) do
                        local data = util.JSONToTable(row.data or "")
                        if (data and data.originalOwner) then
                            -- Manually revert this offline character
                            local ownerID = data.originalOwner
                            local update = mysql:Update("ix_characters")
                                update:Update("steamid", ownerID)
                                data.originalOwner = nil
                                update:Update("data", util.TableToJSON(data))
                                update:Where("id", row.id)
                            update:Execute()

                            -- Correct item ownership
                            local itemUpdate = mysql:Update("ix_items")
                                itemUpdate:Update("player_id", ownerID)
                                itemUpdate:Where("character_id", row.id)
                            itemUpdate:Execute()
                            
                            print("[TransferChar] Restored stuck character " .. row.id .. " to " .. ownerID)
                        end
                    end
                end
            end)

        query:Execute()
    end

else

    net.Receive("ixCharacterListUpdate", function()
        local indices = net.ReadUInt(6)
        local charList = {}

        for i = 1, indices do
            charList[i] = net.ReadUInt(32)
        end

        if (charList) then
            ix.characters = charList
        end
    end)

end


ix.command.Add("TransferChar", {
    description = "Transfers a character to the calling player. Use TransferList to find the CharID.",
    superAdminOnly = true,
    arguments = {
        ix.type.number,
    },
    OnRun = function(self, client, charID)
        -- Find the character by ID
        local query = mysql:Select("ix_characters")
            query:Select("id")
            query:Select("steamid")
            query:Select("name")
            query:Select("data")
            query:Where("id", charID)
            
            query:Callback(function(result)
                if (result and #result > 0) then
                    local charData = result[1]
                    local charID = tonumber(charData.id)
                    local characterName = charData.name
                    local targetSteamID64 = charData.steamid
                    
                    -- Prevent self-transfer
                    if (client:SteamID64() == targetSteamID64) then
                        client:Notify("You cannot transfer your character to yourself.")
                        return
                    end
                    
                    -- Now transfer ownership to the calling client
                    local data = util.JSONToTable(charData.data or "") or {}
                    
                    -- Check if this character is currently loaded by the target player
                    local targetPlayerLocal = player.GetBySteamID64(targetSteamID64)
                    local bWasActive = false

                    local function PerformTransfer()
                        -- Check if character is already transferred
                        if (data.originalOwner) then
                            local ownerName = charData.steamid
                            local owner = player.GetBySteamID64(charData.steamid)
                            if (IsValid(owner)) then
                                ownerName = owner:Name()
                            end
                            client:Notify("This character is already transferred to " .. ownerName .. ".")
                            return
                        end
                        
                        -- Set originalOwner if it doesn't exist
                        if (!data.originalOwner) then
                            data.originalOwner = targetSteamID64
                        end

                        local update = mysql:Update("ix_characters")
                            update:Update("steamid", client:SteamID64())
                            update:Update("data", util.TableToJSON(data))
                            update:Where("id", charID)
                            update:Callback(function()
                                print("[TransferChar] Character " .. characterName .. " (" .. charID .. ") transferred to " .. client:Name() .. " (" .. client:SteamID64() .. ")")
                                client:Notify("Character '" .. characterName .. "' transferred to you.")
                                
                                -- Refresh character list for the new owner (admin) and force load
                                ForceLoadCharacter(client, charID, function(character)
                                    if (character) then
                                        client:Notify("You have been forced into the transferred character.")
                                    end
                                end)

                                -- Refresh character list for the original owner and sync client UI
                                if (IsValid(targetPlayerLocal)) then
                                    UpdateCharacterList(targetPlayerLocal, bWasActive)
                                end
                            end)
                        update:Execute()
                    end

                    -- Check if this character is currently loaded by the target player
                    if (IsValid(targetPlayerLocal)) then
                        local activeChar = targetPlayerLocal:GetCharacter()
                        if (activeChar and activeChar:GetID() == charID) then
                            -- Save the character first so spawnsaver captures the position
                            activeChar:Save(function()
                                -- Update local data with live character data including position
                                data = activeChar:GetData()

                                -- Kick them off the character after saving
                                targetPlayerLocal:Notify("Your character is being transferred by an admin.")
                                activeChar:Kick() 

                                bWasActive = true
                                PerformTransfer()
                            end)
                        else
                            targetPlayerLocal:Notify("Your character '" .. characterName .. "' has been temporarily transferred to '" .. client:Name() .. "'.")
                            PerformTransfer()
                        end
                    else
                        PerformTransfer()
                    end
                else
                    client:Notify("Character not found with that ID.")
                    print("[TransferChar] Failed transfer attempt by " .. client:Name() .. ": Character " .. charID .. " not found")
                end
            end)
        query:Execute()
    end
})

ix.command.Add("TransferList", {
    description = "Lists all characters belonging to a specific SteamID or Character Name (if they are online).",
    superAdminOnly = true,
    arguments = {
        ix.type.string,
    },
    OnRun = function(self, client, playerIdentifier)
        local targetSteamID64 = playerIdentifier
        local targetPlayer = ix.util.FindPlayer(playerIdentifier)
        
        if (IsValid(targetPlayer)) then
            targetSteamID64 = targetPlayer:SteamID64()
        end

        local query = mysql:Select("ix_characters")
            query:Select("id")
            query:Select("name")
            query:Select("data")
            query:Where("steamid", targetSteamID64)
            query:Callback(function(result)
                if (result and #result > 0) then
                    client:ChatPrint("Characters for " .. targetSteamID64 .. ":")
                    for _, row in ipairs(result) do
                        local data = util.JSONToTable(row.data or "") or {}
                        local extra = ""
                        if (data.originalOwner) then
                            extra = " [TRANSFERRED]"
                        end
                        client:ChatPrint(string.format("[%s] %s%s", row.id, row.name, extra))
                    end
                else
                    client:Notify("No characters found for that SteamID/Player.")
                end
            end)
        query:Execute()
    end
})

ix.command.Add("ForceChar", {
    description = "Forces a player to load a specific character ID (must be owned by them).",
    superAdminOnly = true,
    arguments = {
        ix.type.player,
        ix.type.number
    },
    OnRun = function(self, client, target, charID)
        if (!IsValid(target)) then
            client:Notify("Invalid target player.")
            return
        end
        
        -- Check if the character belongs to the target
        local query = mysql:Select("ix_characters")
            query:Select("id")
            query:Select("steamid")
            query:Select("name")
            query:Where("id", charID)
            query:Callback(function(result)
                if (result and #result > 0) then
                     local charData = result[1]
                     if (charData.steamid != target:SteamID64()) then
                        client:Notify("Target player does not own this character.")
                        return
                     end

                     local currentChar = target:GetCharacter()
                     if (currentChar and currentChar:GetID() == charID) then
                        client:Notify("Target is already on this character.")
                        return
                     end
                     
                     -- Force load
                     ForceLoadCharacter(target, charID, function(character)
                        if (character) then
                            client:Notify("Forced " .. target:Name() .. " into character '" .. charData.name .. "'.")
                            target:Notify("An admin forced you into character '" .. charData.name .. "'.")
                        else
                            client:Notify("Failed to load character.")
                        end
                     end)

                else
                    client:Notify("Character ID not found.")
                end
            end)
        query:Execute()
    end
})
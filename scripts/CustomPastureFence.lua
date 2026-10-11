--[[
    Custom Pasture Fence
    Lets the player swap the fence type of an animal pasture for any "newFence" store item.

    How the base game works (FS25, verified against the decompiled scripts):
    - PlaceableHusbandryFence:onLoad reads one fixed fence xml from the barn xml
      ("placeable.husbandry.fence#xmlFilename") and builds a single Fence from it.
    - The savegame only stores fence segment ids + positions, never the fence xml,
      so the fence type is re-read from the barn xml on every load.

    This mod:
    - saves the chosen fence xml as an extra attribute next to the husbandryFence savegame data,
    - wraps PlaceableHusbandryFence.onLoad to load that fence xml instead of the default one,
    - remaps segment ids the chosen fence does not have (e.g. "SEGMENT") to its own templates,
    - rebuilds a placed fence in place, keeping every segment's start/end position.
]]

CustomPastureFence = {}
CustomPastureFence.modName = g_currentModName
CustomPastureFence.SAVE_ATTRIBUTE = "#customFenceXml"
CustomPastureFence.SPEC_SAVE_KEY = ".husbandryFence"
-- Activatables with a real distance (gates, triggers) always win over this one.
CustomPastureFence.ACTIVATABLE_DISTANCE = 1000
CustomPastureFence.VISUAL_REFRESH_FRAMES = 5

CustomPastureFence.hooks = {}
CustomPastureFence.pendingVisualRefresh = {}
-- Fence chosen in the construction screen, per barn xml (lower case) -> fence save filename.
-- Used for the placement preview and for the barn that gets bought with it.
CustomPastureFence.placementChoices = {}

---------------------------------------------------------------------------------------------------
-- Filenames
---------------------------------------------------------------------------------------------------

-- Converts an absolute fence xml path to a portable form for the savegame
-- ("$data/...", "$moddir$ModName/...", "$pdlcdir$...").
function CustomPastureFence.toSaveFilename(filename)
    local saveName = NetworkUtil.convertToNetworkFilename(filename)
    if string.sub(saveName, 1, 1) == "$" then
        return saveName
    end

    local basePath = g_gameBasePath or ""
    if string.startsWith(string.lower(saveName), string.lower(basePath)) then
        return "$" .. string.sub(saveName, #basePath + 1)
    end

    return saveName
end

function CustomPastureFence.fromSaveFilename(saveName)
    local lower = string.lower(saveName)
    if string.startsWith(lower, "$moddir$") or string.startsWith(lower, "$pdlcdir") or string.startsWith(lower, "$mapdir$") then
        return NetworkUtil.convertFromNetworkFilename(saveName)
    end

    return Utils.getFilename(saveName, nil)
end

function CustomPastureFence.getStoreItemBySaveFilename(saveName)
    if saveName == nil then
        return nil
    end

    return g_storeManager:getItemByXMLFilename(CustomPastureFence.fromSaveFilename(saveName))
end

---------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------

function CustomPastureFence.getIsMultiplayer()
    return g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil and g_currentMission.missionDynamicInfo.isMultiplayer
end

-- All placeable store items that use the new fence construction brush.
function CustomPastureFence.getFenceStoreItems()
    local items = {}
    for _, storeItem in ipairs(g_storeManager:getItems()) do
        if storeItem.species == StoreSpecies.PLACEABLE
            and storeItem.brush ~= nil and storeItem.brush.type == "newFence"
            and storeItem.showInStore
            and g_storeManager:getIsItemUnlocked(storeItem) then
            table.insert(items, storeItem)
        end
    end

    table.sort(items, function(a, b)
        if a.name == b.name then
            return a.xmlFilenameLower < b.xmlFilenameLower
        end
        return a.name < b.name
    end)

    return items
end

function CustomPastureFence.getStoreItemLabel(storeItem)
    local fileBase = Utils.getFilenameInfo(storeItem.xmlFilename, true)
    local label = string.format("%s (%s)", storeItem.name, fileBase)
    if storeItem.dlcTitle ~= nil and storeItem.dlcTitle ~= "" then
        label = string.format("%s - %s", label, storeItem.dlcTitle)
    end
    return label
end

-- Returns the template id in `fence` that best replaces a segment.
-- Prefers `preferredId` when it exists with the same kind (gate / plain segment).
function CustomPastureFence.findTemplateId(fence, wantGate, gateLength, preferredId)
    local templates = fence.segmentTemplates

    if preferredId ~= nil then
        local template = templates[preferredId]
        if template ~= nil and (template.gate ~= nil) == wantGate then
            return preferredId
        end
    end

    local bestId = nil
    local bestDiff = nil
    for _, id in ipairs(fence:getSegmentTemplates()) do
        local template = templates[id]
        if (template.gate ~= nil) == wantGate then
            local diff = 0
            if wantGate and gateLength ~= nil and template.gate.length ~= nil then
                diff = math.abs(template.gate.length - gateLength)
            end
            if bestId == nil or diff < bestDiff then
                bestId = id
                bestDiff = diff
            end
        end
    end

    return bestId
end

-- Segment ids from the barn xml or savegame that the custom fence does not define are mapped
-- onto the custom fence's own templates. Only active for pastures using a custom fence.
function CustomPastureFence.resolveSegmentId(fence, segmentId)
    if segmentId == nil or fence.segmentTemplates[segmentId] ~= nil then
        return segmentId
    end

    local parent = fence.parentObject
    if parent == nil or parent.cpfFenceXml == nil then
        return segmentId
    end

    local wantGate = string.find(string.upper(segmentId), "GATE", 1, true) ~= nil
    return CustomPastureFence.findTemplateId(fence, wantGate) or CustomPastureFence.findTemplateId(fence, false) or segmentId
end

function CustomPastureFence.getPastureContour(placeable)
    local animalsSpec = placeable.spec_husbandryAnimals
    if animalsSpec ~= nil and animalsSpec.outdoorContourPolygon ~= nil then
        return animalsSpec.outdoorContourPolygon
    end

    if placeable.cpfContourPolygon == nil then
        local positions = placeable:getFenceContourPositions()
        if #positions >= 9 then
            local polygon = Polygon2D.new()
            polygon:setVerticesFromXYZ(positions)
            placeable.cpfContourPolygon = polygon
        end
    end

    return placeable.cpfContourPolygon
end

-- The owned pasture with a fence that the local player is standing in, if any.
function CustomPastureFence.getPastureAtPlayer()
    if g_localPlayer == nil or g_currentMission == nil or g_currentMission.placeableSystem == nil then
        return nil
    end

    local x, _, z = g_localPlayer:getPosition()
    if x == nil then
        return nil
    end

    local farmId = g_currentMission:getFarmId()
    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        local spec = placeable.spec_husbandryFence
        if spec ~= nil and spec.fence ~= nil and not spec.userIsCustomizing and placeable:getOwnerFarmId() == farmId then
            local polygon = CustomPastureFence.getPastureContour(placeable)
            if polygon ~= nil and polygon:getIsPosInside(x, z) then
                return placeable
            end
        end
    end

    return nil
end

---------------------------------------------------------------------------------------------------
-- Placeable hooks
---------------------------------------------------------------------------------------------------

-- Replaces PlaceableHusbandryFence:onLoad when a custom fence was saved for this placeable,
-- or was picked in the construction screen for a new one.
-- Mirrors the base implementation, but loads the chosen fence xml with its own base directory.
function CustomPastureFence.husbandryFenceOnLoad(self, superFunc, savegame)
    local defaultRaw = self.xmlFile:getValue("placeable.husbandry.fence#xmlFilename")
    if defaultRaw ~= nil then
        self.cpfDefaultFenceXml = Utils.getFilename(defaultRaw, self.baseDirectory)
    end

    local saved = nil
    if defaultRaw ~= nil then
        if savegame ~= nil and savegame.xmlFile ~= nil then
            saved = savegame.xmlFile:getString(savegame.key .. CustomPastureFence.SPEC_SAVE_KEY .. CustomPastureFence.SAVE_ATTRIBUTE)
        elseif self.configFileName ~= nil then
            saved = CustomPastureFence.placementChoices[string.lower(self.configFileName)]
        end
    end

    if saved == nil then
        return superFunc(self, savegame)
    end

    -- Remember the choice even when it cannot be applied, so it survives the next save.
    self.cpfFenceXml = saved

    if CustomPastureFence.getIsMultiplayer() then
        return superFunc(self, savegame)
    end

    local storeItem = CustomPastureFence.getStoreItemBySaveFilename(saved)
    if storeItem == nil then
        Logging.warning("[CustomPastureFence] Saved fence '%s' is not available (mod removed?). Using the original fence for '%s'.", saved, self:getName())
        return superFunc(self, savegame)
    end

    local spec = self.spec_husbandryFence
    spec.userIsCustomizing = false
    spec.hasCustomizableFence = nil
    spec.canBePlaced = true

    if g_iconGenerator ~= nil then
        return
    end

    self.fenceXmlFile = XMLFile.load("placeableHusbandryfence", storeItem.xmlFilename, Fence.xmlSchema)
    if self.fenceXmlFile == nil then
        Logging.warning("[CustomPastureFence] Could not load fence xml '%s'. Using the original fence.", storeItem.xmlFilename)
        return superFunc(self, savegame)
    end

    local fenceI3dFilename = self.fenceXmlFile:getString("placeable.base.filename")
    if string.isNilOrWhitespace(fenceI3dFilename) then
        Logging.warning("[CustomPastureFence] No i3d in fence xml '%s'. Using the original fence.", storeItem.xmlFilename)
        self.fenceXmlFile:delete()
        self.fenceXmlFile = nil
        return superFunc(self, savegame)
    end

    fenceI3dFilename = Utils.getFilename(fenceI3dFilename, storeItem.baseDir)
    local arguments = {
        fenceI3dFilename = fenceI3dFilename,
        loadingTask = self:createLoadingTask()
    }
    spec.sharedLoadRequestId = g_i3DManager:loadSharedI3DFileAsync(fenceI3dFilename, false, false, self.onFenceI3DLoaded, self, arguments)
end

function CustomPastureFence.husbandryFenceSaveToXMLFile(self, xmlFile, key, _)
    if self.cpfFenceXml ~= nil then
        xmlFile:setString(key .. CustomPastureFence.SAVE_ATTRIBUTE, self.cpfFenceXml)
    end
end

function CustomPastureFence.fenceGetSegmentTemplateById(self, superFunc, segmentId)
    return superFunc(self, CustomPastureFence.resolveSegmentId(self, segmentId))
end

function CustomPastureFence.fenceCreateNewSegment(self, superFunc, segmentId)
    return superFunc(self, CustomPastureFence.resolveSegmentId(self, segmentId))
end

---------------------------------------------------------------------------------------------------
-- Swapping a placed fence
---------------------------------------------------------------------------------------------------

-- Rebuilds the pasture fence from `xmlFilename`, keeping every segment's position.
-- Returns success, plus a result table { gatesRemoved, segmentsFailed } or an error l10n key.
function CustomPastureFence.applyFence(placeable, xmlFilename, baseDir)
    local spec = placeable.spec_husbandryFence
    local oldFence = spec ~= nil and spec.fence or nil
    if oldFence == nil then
        return false, "cpf_error_failed"
    end
    if spec.userIsCustomizing then
        return false, "cpf_error_busy"
    end

    local xmlFile = XMLFile.load("cpfFenceXml", xmlFilename, Fence.xmlSchema)
    if xmlFile == nil then
        Logging.error("[CustomPastureFence] Could not load fence xml '%s'", xmlFilename)
        return false, "cpf_error_failed"
    end

    local i3dFilename = xmlFile:getString("placeable.base.filename")
    if string.isNilOrWhitespace(i3dFilename) then
        Logging.error("[CustomPastureFence] No i3d defined in fence xml '%s'", xmlFilename)
        xmlFile:delete()
        return false, "cpf_error_failed"
    end
    i3dFilename = Utils.getFilename(i3dFilename, baseDir)

    local i3dNode, sharedLoadRequestId = g_i3DManager:loadSharedI3DFile(i3dFilename, false, false)
    if i3dNode == nil or i3dNode == 0 then
        Logging.error("[CustomPastureFence] Could not load fence i3d '%s'", i3dFilename)
        if sharedLoadRequestId ~= nil then
            g_i3DManager:releaseSharedI3DFile(sharedLoadRequestId)
        end
        xmlFile:delete()
        return false, "cpf_error_failed"
    end

    local components = I3DUtil.loadI3DComponents(i3dNode)
    local i3dMappings = I3DUtil.loadI3DMapping(xmlFile, "placeable", components)
    local newFence = Fence.new(xmlFile, "placeable.fence", i3dFilename, components, i3dMappings, placeable)
    local loaded = newFence:load(xmlFile, "placeable.fence")
    delete(i3dNode)
    xmlFile:delete()

    if not loaded then
        newFence:delete()
        g_i3DManager:releaseSharedI3DFile(sharedLoadRequestId)
        return false, "cpf_error_failed"
    end

    -- Map every existing segment onto a template of the new fence before touching the old one.
    local result = { gatesRemoved = 0, segmentsFailed = 0 }
    local segmentData = {}
    for _, segment in ipairs(oldFence:getSegments()) do
        local sx, sy, sz = segment:getStartPos()
        local ex, ey, ez = segment:getEndPos()
        if sx ~= nil and ex ~= nil then
            local gate = segment.metadata.gate
            local isGate = gate ~= nil
            local newId = CustomPastureFence.findTemplateId(newFence, isGate, isGate and gate.length or nil, segment:getId())
            if newId == nil and isGate then
                -- No gate in the new fence: leave an opening instead of closing the pasture.
                result.gatesRemoved = result.gatesRemoved + 1
            elseif newId ~= nil then
                table.insert(segmentData, {
                    id = newId,
                    isGate = isGate,
                    isReversed = segment.isReversed,
                    isCustomizable = segment.husbandryFenceIsCustomizable,
                    isDefault = segment.husbandryFenceIsDefaultSegment,
                    sx = sx, sy = sy, sz = sz,
                    ex = ex, ey = ey, ez = ez
                })
            end
        end
    end

    if #segmentData == 0 then
        Logging.error("[CustomPastureFence] Fence '%s' has no usable segment templates", xmlFilename)
        newFence:delete()
        g_i3DManager:releaseSharedI3DFile(sharedLoadRequestId)
        return false, "cpf_error_failed"
    end

    -- Remove the old fence.
    spec.previewSegments = nil
    oldFence:delete()
    if spec.sharedLoadRequestId ~= nil then
        g_i3DManager:releaseSharedI3DFile(spec.sharedLoadRequestId)
    end
    spec.sharedLoadRequestId = sharedLoadRequestId
    spec.fence = newFence

    -- Build the new segments along the old positions, in the old order (the order defines the contour).
    for _, data in ipairs(segmentData) do
        local segment = newFence:createNewSegment(data.id)
        if segment == nil then
            result.segmentsFailed = result.segmentsFailed + 1
        else
            segment:setStartPos(data.sx, data.sy, data.sz)
            segment:setEndPos(data.ex, data.ey, data.ez)
            if data.isGate then
                segment.isReversed = data.isReversed == true
            end
            segment.husbandryFenceIsCustomizable = data.isCustomizable
            segment.husbandryFenceIsDefaultSegment = data.isDefault

            if not (segment:updateMeshes(true, false) and segment:finalize(true)) then
                segment:delete()
                result.segmentsFailed = result.segmentsFailed + 1
            end
        end
    end
    newFence:finalize()

    -- Rebuild the animals' navigation mesh from the new fence contour.
    placeable.cpfContourPolygon = nil
    placeable:finalizeHusbandryFence()

    local animalsSpec = placeable.spec_husbandryAnimals
    if animalsSpec ~= nil then
        animalsSpec.updateVisuals = true
        CustomPastureFence.pendingVisualRefresh[placeable] = CustomPastureFence.VISUAL_REFRESH_FRAMES
    end

    return true, result
end

-- storeItem nil means "back to the original fence".
function CustomPastureFence.changeFence(placeable, storeItem)
    local xmlFilename, baseDir, saveName, label

    if storeItem == nil
        or (placeable.cpfDefaultFenceXml ~= nil and storeItem.xmlFilenameLower == string.lower(placeable.cpfDefaultFenceXml)) then
        xmlFilename = placeable.cpfDefaultFenceXml
        baseDir = placeable.baseDirectory
        saveName = nil
        label = g_i18n:getText("cpf_option_original")
    else
        xmlFilename = storeItem.xmlFilename
        baseDir = storeItem.baseDir
        saveName = CustomPastureFence.toSaveFilename(storeItem.xmlFilename)
        label = storeItem.name
    end

    if xmlFilename == nil then
        return
    end

    -- Set before building so segment id remapping is active for a custom fence.
    local previousSaveName = placeable.cpfFenceXml
    placeable.cpfFenceXml = saveName

    local success, result = CustomPastureFence.applyFence(placeable, xmlFilename, baseDir)
    if not success then
        placeable.cpfFenceXml = previousSaveName
        InfoDialog.show(g_i18n:getText(result))
        return
    end

    local message = string.format(g_i18n:getText("cpf_info_changed"), label)
    if result.gatesRemoved > 0 then
        message = message .. " " .. string.format(g_i18n:getText("cpf_info_gatesRemoved"), result.gatesRemoved)
    end
    if result.segmentsFailed > 0 then
        message = message .. " " .. string.format(g_i18n:getText("cpf_info_segmentsFailed"), result.segmentsFailed)
    end
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, message)
end

-- Shows the fence list. `currentSaveName` nil means the original fence is current.
-- Calls onChosen(storeItem) with nil for "original fence"; not called on cancel or no change.
function CustomPastureFence.showFencePicker(placeableName, currentSaveName, onChosen)
    local storeItems = CustomPastureFence.getFenceStoreItems()
    local currentLower = nil
    if currentSaveName ~= nil then
        currentLower = string.lower(CustomPastureFence.fromSaveFilename(currentSaveName))
    end
    local currentSuffix = " " .. g_i18n:getText("cpf_option_current")

    local options = {}
    local choices = {}
    local defaultIndex = 1

    local originalLabel = g_i18n:getText("cpf_option_original")
    if currentLower == nil then
        originalLabel = originalLabel .. currentSuffix
    end
    table.insert(options, originalLabel)
    table.insert(choices, false)

    for _, storeItem in ipairs(storeItems) do
        local label = CustomPastureFence.getStoreItemLabel(storeItem)
        if currentLower ~= nil and storeItem.xmlFilenameLower == currentLower then
            label = label .. currentSuffix
            defaultIndex = #options + 1
        end
        table.insert(options, label)
        table.insert(choices, storeItem)
    end

    local text = string.format(g_i18n:getText("cpf_dialog_text"), placeableName)
    OptionDialog.show(function(index)
        if index == nil or index < 1 or choices[index] == nil or index == defaultIndex then
            return
        end
        local storeItem = choices[index]
        onChosen(storeItem ~= false and storeItem or nil)
    end, text, g_i18n:getText("cpf_dialog_title"), options, defaultIndex)
end

function CustomPastureFence.openDialog(placeable)
    if placeable == nil or placeable.spec_husbandryFence == nil or placeable.spec_husbandryFence.fence == nil then
        return
    end

    CustomPastureFence.showFencePicker(placeable:getName(), placeable.cpfFenceXml, function(storeItem)
        if placeable.isDeleted or placeable.spec_husbandryFence.fence == nil then
            return
        end
        CustomPastureFence.changeFence(placeable, storeItem)
    end)
end

---------------------------------------------------------------------------------------------------
-- Construction screen: pick the fence while placing a new barn (extra brush button)
---------------------------------------------------------------------------------------------------

function CustomPastureFence.getBrushPreviewFence(brush)
    local placeable = brush.placeable
    if placeable == nil or placeable.spec_husbandryFence == nil or placeable.spec_husbandryFence.fence == nil then
        return nil
    end
    return placeable
end

function CustomPastureFence.brushHusbandryNew(subclass_mt, superFunc, cursor)
    local brush = superFunc(subclass_mt, cursor)
    brush.supportsFourthButton = true
    return brush
end

function CustomPastureFence.brushGetButtonFourthText(brush)
    local preview = CustomPastureFence.getBrushPreviewFence(brush)
    if preview == nil or CustomPastureFence.getIsMultiplayer() then
        return nil
    end

    local label = g_i18n:getText("cpf_option_original")
    local storeItem = CustomPastureFence.getStoreItemBySaveFilename(preview.cpfFenceXml)
    if storeItem ~= nil then
        label = storeItem.name
    end
    return string.format(g_i18n:getText("cpf_construction_fence"), label)
end

function CustomPastureFence.brushOnButtonFourth(brush)
    local preview = CustomPastureFence.getBrushPreviewFence(brush)
    if preview == nil or brush.isLoading or brush.isPlacing or CustomPastureFence.getIsMultiplayer() then
        return
    end

    local placeableKey = string.lower(preview.configFileName)
    local defaultLower = preview.cpfDefaultFenceXml ~= nil and string.lower(preview.cpfDefaultFenceXml) or nil

    CustomPastureFence.showFencePicker(preview:getName(), preview.cpfFenceXml, function(storeItem)
        if storeItem == nil or storeItem.xmlFilenameLower == defaultLower then
            CustomPastureFence.placementChoices[placeableKey] = nil
        else
            CustomPastureFence.placementChoices[placeableKey] = CustomPastureFence.toSaveFilename(storeItem.xmlFilename)
        end

        -- Reload the preview so it is built (and placement-checked) with the chosen fence.
        if brush.isActive and not brush.isPlacing then
            brush:unloadPlaceable()
            brush:loadPlaceable()
            brush:setInputTextDirty()
        end
    end)
end

---------------------------------------------------------------------------------------------------
-- Activatable: "Change pasture fence" while standing inside an owned pasture
---------------------------------------------------------------------------------------------------

CustomPastureFenceActivatable = {}
local CustomPastureFenceActivatable_mt = Class(CustomPastureFenceActivatable)

function CustomPastureFenceActivatable.new()
    local self = setmetatable({}, CustomPastureFenceActivatable_mt)
    self.activateText = g_i18n:getText("cpf_action_changeFence")
    self.placeable = nil
    return self
end

function CustomPastureFenceActivatable:getIsActivatable()
    self.placeable = nil
    if g_gui:getIsGuiVisible() or CustomPastureFence.getIsMultiplayer() or g_server == nil then
        return false
    end
    if g_localPlayer == nil or g_localPlayer:getIsInVehicle() then
        return false
    end

    self.placeable = CustomPastureFence.getPastureAtPlayer()
    return self.placeable ~= nil
end

function CustomPastureFenceActivatable:getDistance(_, _, _)
    return CustomPastureFence.ACTIVATABLE_DISTANCE
end

function CustomPastureFenceActivatable:run()
    CustomPastureFence.openDialog(self.placeable)
end

---------------------------------------------------------------------------------------------------
-- Mod lifecycle (hooks are installed per mission and removed again, so they never stack)
---------------------------------------------------------------------------------------------------

function CustomPastureFence:installHook(target, name, newFunc)
    local original = target[name]
    table.insert(self.hooks, { target = target, name = name, original = original })
    target[name] = newFunc(original)
end

function CustomPastureFence:loadMap(_)
    self:installHook(PlaceableHusbandryFence, "onLoad", function(original)
        return Utils.overwrittenFunction(original, CustomPastureFence.husbandryFenceOnLoad)
    end)
    self:installHook(PlaceableHusbandryFence, "saveToXMLFile", function(original)
        return Utils.appendedFunction(original, CustomPastureFence.husbandryFenceSaveToXMLFile)
    end)
    self:installHook(Fence, "getSegmentTemplateById", function(original)
        return Utils.overwrittenFunction(original, CustomPastureFence.fenceGetSegmentTemplateById)
    end)
    self:installHook(Fence, "createNewSegment", function(original)
        return Utils.overwrittenFunction(original, CustomPastureFence.fenceCreateNewSegment)
    end)
    self:installHook(ConstructionBrushHusbandry, "new", function(original)
        return Utils.overwrittenFunction(original, CustomPastureFence.brushHusbandryNew)
    end)
    self:installHook(ConstructionBrushHusbandry, "getButtonFourthText", function(_)
        return CustomPastureFence.brushGetButtonFourthText
    end)
    self:installHook(ConstructionBrushHusbandry, "onButtonFourth", function(_)
        return CustomPastureFence.brushOnButtonFourth
    end)

    self.activatable = CustomPastureFenceActivatable.new()
    if g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:addActivatable(self.activatable)
    end
end

function CustomPastureFence:deleteMap()
    if self.activatable ~= nil and g_currentMission ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self.activatable)
    end
    self.activatable = nil

    for i = #self.hooks, 1, -1 do
        local hook = self.hooks[i]
        hook.target[hook.name] = hook.original
    end
    self.hooks = {}
    self.pendingVisualRefresh = {}
    self.placementChoices = {}
end

-- Animal visuals take a few frames to update after the husbandry is recreated; wake the
-- placeable up afterwards so the animals reappear on the rebuilt navigation mesh.
function CustomPastureFence:update(_)
    for placeable, frames in pairs(self.pendingVisualRefresh) do
        if frames <= 0 then
            self.pendingVisualRefresh[placeable] = nil
            if not placeable.isDeleted then
                placeable:raiseActive()
            end
        else
            self.pendingVisualRefresh[placeable] = frames - 1
        end
    end
end

addModEventListener(CustomPastureFence)

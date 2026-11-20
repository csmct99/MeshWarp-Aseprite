-- Global Constants
local CanvasSize = 450
local WorkAreaSize = 250
local HandleRadius = 5

-- Resolves the horizontal axis coordinate during inverse bilinear interpolation.
local function calculateHorizontalAxis(pointDiffX, pointDiffY, edgeX1, edgeY1, edgeX2, edgeY2, crossEdgeX, crossEdgeY, verticalPosition)
    -- Expands the bilinear equation to solve for the horizontal fraction.
    -- We pick the axis with the larger denominator to maximize floating-point precision and prevent division by zero.
    local denominatorX = edgeX1 + crossEdgeX * verticalPosition
    local denominatorY = edgeY1 + crossEdgeY * verticalPosition
    
    if math.abs(denominatorX) > math.abs(denominatorY) then
        return (pointDiffX - edgeX2 * verticalPosition) / denominatorX
    else
        if math.abs(denominatorY) < 0.000001 then return -1.0 end
        return (pointDiffY - edgeY2 * verticalPosition) / denominatorY
    end
end

-- Maps a point inside an arbitrary quadrilateral to normalized (u, v) space.
local function calculateInverseBilinear(pointX, pointY, point1, point2, point3, point4)
    local edgeX1 = point2.x - point1.x
    local edgeY1 = point2.y - point1.y
    local edgeX2 = point4.x - point1.x
    local edgeY2 = point4.y - point1.y
    local crossEdgeX = point1.x - point2.x + point3.x - point4.x
    local crossEdgeY = point1.y - point2.y + point3.y - point4.y
    local pointDiffX = pointX - point1.x
    local pointDiffY = pointY - point1.y

    -- The inverse bilinear mapping resolves to a quadratic equation: A*v^2 + B*v + C = 0.
    -- These coefficients are derived from the 2D cross products of the quad's edges.
    local coeffA = crossEdgeX * edgeY2 - crossEdgeY * edgeX2
    local coeffB = edgeX1 * edgeY2 - edgeY1 * edgeX2 + pointDiffX * crossEdgeY - pointDiffY * crossEdgeX
    local coeffC = pointDiffX * edgeY1 - pointDiffY * edgeX1

    local horizontalPosition, verticalPosition

    if math.abs(coeffA) < 0.000001 then
        -- Fallback for linear cases (e.g., the quad is a perfect parallelogram) where the quadratic term approaches zero.
        if math.abs(coeffB) < 0.000001 then return nil, nil end
        verticalPosition = -coeffC / coeffB
        horizontalPosition = calculateHorizontalAxis(pointDiffX, pointDiffY, edgeX1, edgeY1, edgeX2, edgeY2, crossEdgeX, crossEdgeY, verticalPosition)
    else
        -- Calculate both roots of the quadratic equation using the standard quadratic formula.
        local discriminant = coeffB * coeffB - 4.0 * coeffC * coeffA
        if discriminant < 0.0 then return nil, nil end
        
        local discriminantRoot = math.sqrt(discriminant)

        local vertical1 = (-coeffB - discriminantRoot) / (2.0 * coeffA)
        local horizontal1 = calculateHorizontalAxis(pointDiffX, pointDiffY, edgeX1, edgeY1, edgeX2, edgeY2, crossEdgeX, crossEdgeY, vertical1)

        local vertical2 = (-coeffB + discriminantRoot) / (2.0 * coeffA)
        local horizontal2 = calculateHorizontalAxis(pointDiffX, pointDiffY, edgeX1, edgeY1, edgeX2, edgeY2, crossEdgeX, crossEdgeY, vertical2)

        -- Select the root that falls within the valid [0, 1] bounds of the quadrilateral.
        horizontalPosition, verticalPosition = horizontal1, vertical1
        if verticalPosition < -0.001 or verticalPosition > 1.001 or horizontalPosition < -0.001 or horizontalPosition > 1.001 then
            horizontalPosition, verticalPosition = horizontal2, vertical2
        end
    end

    if horizontalPosition >= -0.001 and horizontalPosition <= 1.001 and verticalPosition >= -0.001 and verticalPosition <= 1.001 then
        return math.max(0, math.min(1, horizontalPosition)), math.max(0, math.min(1, verticalPosition))
    end
    
    return nil, nil
end

-- Precomputes per-cell geometry once per render: the four corners, the axis-aligned
-- bounds used for culling, and the source-space offset of the cell. The bounds are
-- invariant for a whole frame, so recomputing them per output pixel (as the renderer
-- used to) is wasted work.
local function buildGridCells(destinationPoints, gridResolution, sourceWidth, sourceHeight)
    local quadWidth = sourceWidth / gridResolution
    local quadHeight = sourceHeight / gridResolution
    local pointsPerRow = gridResolution + 1
    local cells = {}

    for row = 0, gridResolution - 1 do
        for column = 0, gridResolution - 1 do
            local index1 = row * pointsPerRow + column + 1
            local index2 = index1 + 1
            local index4 = (row + 1) * pointsPerRow + column + 1
            local index3 = index4 + 1

            local point1 = destinationPoints[index1]
            local point2 = destinationPoints[index2]
            local point3 = destinationPoints[index3]
            local point4 = destinationPoints[index4]

            -- Plain comparisons instead of math.min/max: this runs once per cell, and the
            -- vararg math functions are relatively expensive interpreter-to-C calls.
            local minimumX, maximumX = point1.x, point1.x
            if point2.x < minimumX then minimumX = point2.x elseif point2.x > maximumX then maximumX = point2.x end
            if point3.x < minimumX then minimumX = point3.x elseif point3.x > maximumX then maximumX = point3.x end
            if point4.x < minimumX then minimumX = point4.x elseif point4.x > maximumX then maximumX = point4.x end

            local minimumY, maximumY = point1.y, point1.y
            if point2.y < minimumY then minimumY = point2.y elseif point2.y > maximumY then maximumY = point2.y end
            if point3.y < minimumY then minimumY = point3.y elseif point3.y > maximumY then maximumY = point3.y end
            if point4.y < minimumY then minimumY = point4.y elseif point4.y > maximumY then maximumY = point4.y end

            cells[#cells + 1] = {
                point1 = point1,
                point2 = point2,
                point3 = point3,
                point4 = point4,
                minimumX = minimumX,
                maximumX = maximumX,
                minimumY = minimumY,
                maximumY = maximumY,
                sourceX = column * quadWidth,
                sourceY = row * quadHeight,
                quadWidth = quadWidth,
                quadHeight = quadHeight,
            }
        end
    end

    return cells
end

-- Maps an output pixel to a specific source coordinate within an arbitrary N x N grid structure.
-- Employs AABB boundary culling (precomputed per cell) to ensure high grid resolutions remain performant.
local function findSourceCoordinate(worldX, worldY, cells)
    for cellIndex = 1, #cells do
        local cell = cells[cellIndex]

        -- Fast Axis-Aligned Bounding Box (AABB) culling.
        -- Avoids running the heavy inverse bilinear math if the pixel is completely outside this specific grid cell.
        if worldX >= cell.minimumX - 0.01 and worldX <= cell.maximumX + 0.01 and
           worldY >= cell.minimumY - 0.01 and worldY <= cell.maximumY + 0.01 then
            local normalizedX, normalizedY = calculateInverseBilinear(
                worldX, worldY, cell.point1, cell.point2, cell.point3, cell.point4)
            if normalizedX and normalizedY then
                return cell.sourceX + normalizedX * cell.quadWidth,
                       cell.sourceY + normalizedY * cell.quadHeight
            end
        end
    end

    return nil, nil
end

-- Rebuilds the distortion grid to a new resolution while preserving the current perspective layout.
local function recalculateGridPoints(previousPoints, oldResolution, newResolution)
    local updatedPoints = {}
    local pointsPerRow = oldResolution + 1
    
    for row = 0, newResolution do
        for column = 0, newResolution do
            local normalizedX = column / newResolution
            local normalizedY = row / newResolution
            
            local previousColumn = math.floor(normalizedX * oldResolution)
            if previousColumn == oldResolution then previousColumn = oldResolution - 1 end
            
            local previousRow = math.floor(normalizedY * oldResolution)
            if previousRow == oldResolution then previousRow = oldResolution - 1 end
            
            local quadFractionX = (normalizedX * oldResolution) - previousColumn
            local quadFractionY = (normalizedY * oldResolution) - previousRow
            
            local index1 = previousRow * pointsPerRow + previousColumn + 1
            local index2 = index1 + 1
            local index4 = (previousRow + 1) * pointsPerRow + previousColumn + 1
            local index3 = index4 + 1
            
            local point1 = previousPoints[index1]
            local point2 = previousPoints[index2]
            local point3 = previousPoints[index3]
            local point4 = previousPoints[index4]
            
            -- Standard forward bilinear interpolation.
            -- Maps the normalized sub-grid coordinate to the actual global coordinate space of the parent quad.
            local topEdgeX = point1.x + (point2.x - point1.x) * quadFractionX
            local topEdgeY = point1.y + (point2.y - point1.y) * quadFractionX
            
            local bottomEdgeX = point4.x + (point3.x - point4.x) * quadFractionX
            local bottomEdgeY = point4.y + (point3.y - point4.y) * quadFractionX
            
            local finalPointX = topEdgeX + (bottomEdgeX - topEdgeX) * quadFractionY
            local finalPointY = topEdgeY + (bottomEdgeY - topEdgeY) * quadFractionY
            
            table.insert(updatedPoints, {x = finalPointX, y = finalPointY})
        end
    end
    
    return updatedPoints
end

-- Extracts the RGBA components of a pixel, converting natively across all Aseprite color modes.
local function extractPixelRgba(image, xCoord, yCoord, isIndexed, palette, transparentIndex, isGrayscale, pixelColorTools)
    if xCoord < 0 or xCoord >= image.width or yCoord < 0 or yCoord >= image.height then
        return 0, 0, 0, 0
    end
    
    local pixelValue = image:getPixel(xCoord, yCoord)
    
    if isIndexed then
        if pixelValue == transparentIndex then return 0, 0, 0, 0 end
        local mappedColor = palette:getColor(pixelValue)
        return mappedColor.red, mappedColor.green, mappedColor.blue, mappedColor.alpha
    elseif isGrayscale then
        local grayValue = pixelColorTools.grayaV(pixelValue)
        return grayValue, grayValue, grayValue, pixelColorTools.grayaA(pixelValue)
    else
        return pixelColorTools.rgbaR(pixelValue), pixelColorTools.rgbaG(pixelValue), pixelColorTools.rgbaB(pixelValue), pixelColorTools.rgbaA(pixelValue)
    end
end

-- Samples a sub-pixel fractional coordinate using a 4-point bilinear interpolation blend.
-- Utilizes pre-multiplied alpha weighting to prevent dark fringing on transparent edges.
local function getBilinearSampledColor(image, sourceX, sourceY, isIndexed, palette, transparentIndex, isGrayscale, pixelColorTools)
    -- Source coordinates are continuous (pixel i spans [i, i + 1) and is centered at i + 0.5),
    -- so shift to neighbor-index space before selecting the four taps.
    local adjustedX = sourceX - 0.5
    local adjustedY = sourceY - 0.5
    
    -- Clamp the taps to the image instead of letting out-of-bounds neighbors read as transparent.
    -- This keeps edge pixels fully opaque and makes sampling a no-op warp an exact identity.
    local leftX = math.max(0, math.floor(adjustedX))
    local topY = math.max(0, math.floor(adjustedY))
    local rightX = math.min(image.width - 1, leftX + 1)
    local bottomY = math.min(image.height - 1, topY + 1)
    
    local fractionX = math.max(0, math.min(1, adjustedX - leftX))
    local fractionY = math.max(0, math.min(1, adjustedY - topY))
    
    local redTopLeft, greenTopLeft, blueTopLeft, alphaTopLeft = extractPixelRgba(image, leftX, topY, isIndexed, palette, transparentIndex, isGrayscale, pixelColorTools)
    local redTopRight, greenTopRight, blueTopRight, alphaTopRight = extractPixelRgba(image, rightX, topY, isIndexed, palette, transparentIndex, isGrayscale, pixelColorTools)
    local redBottomLeft, greenBottomLeft, blueBottomLeft, alphaBottomLeft = extractPixelRgba(image, leftX, bottomY, isIndexed, palette, transparentIndex, isGrayscale, pixelColorTools)
    local redBottomRight, greenBottomRight, blueBottomRight, alphaBottomRight = extractPixelRgba(image, rightX, bottomY, isIndexed, palette, transparentIndex, isGrayscale, pixelColorTools)
    
    -- Calculate area weights for the four neighboring pixels.
    -- As the fractional position moves closer to a pixel's center, its corresponding weight approaches 1.0.
    local weightTopLeft = (1 - fractionX) * (1 - fractionY)
    local weightTopRight = fractionX * (1 - fractionY)
    local weightBottomLeft = (1 - fractionX) * fractionY
    local weightBottomRight = fractionX * fractionY
    
    local blendedAlpha = alphaTopLeft * weightTopLeft + alphaTopRight * weightTopRight + alphaBottomLeft * weightBottomLeft + alphaBottomRight * weightBottomRight
    if blendedAlpha <= 0 then return pixelColorTools.rgba(0, 0, 0, 0) end
    
    local blendedRed = (redTopLeft * alphaTopLeft * weightTopLeft + redTopRight * alphaTopRight * weightTopRight + redBottomLeft * alphaBottomLeft * weightBottomLeft + redBottomRight * alphaBottomRight * weightBottomRight) / blendedAlpha
    local blendedGreen = (greenTopLeft * alphaTopLeft * weightTopLeft + greenTopRight * alphaTopRight * weightTopRight + greenBottomLeft * alphaBottomLeft * weightBottomLeft + greenBottomRight * alphaBottomRight * weightBottomRight) / blendedAlpha
    local blendedBlue = (blueTopLeft * alphaTopLeft * weightTopLeft + blueTopRight * alphaTopRight * weightTopRight + blueBottomLeft * alphaBottomLeft * weightBottomLeft + blueBottomRight * alphaBottomRight * weightBottomRight) / blendedAlpha
    
    return pixelColorTools.rgba(math.floor(blendedRed + 0.5), math.floor(blendedGreen + 0.5), math.floor(blendedBlue + 0.5), math.floor(blendedAlpha + 0.5))
end

-- Unified handler that processes the dynamic destination layout and plots mapped source pixels.
local function renderDistortedImage(sourceImage, destinationPoints, gridResolution, previewAlpha, samplingMode, renderScale)
    renderScale = renderScale or 1.0
    
    local minimumX = destinationPoints[1].x
    local maximumX = destinationPoints[1].x
    local minimumY = destinationPoints[1].y
    local maximumY = destinationPoints[1].y
    
    for i = 2, #destinationPoints do
        minimumX = math.min(minimumX, destinationPoints[i].x)
        maximumX = math.max(maximumX, destinationPoints[i].x)
        minimumY = math.min(minimumY, destinationPoints[i].y)
        maximumY = math.max(maximumY, destinationPoints[i].y)
    end
    
    -- Align the output pixel grid to the canvas pixel grid. Without this, a fractional
    -- bounding box would place the result at a fractional offset, and Apply would truncate
    -- that offset to an integer cel position, shifting the warp by a sub-pixel amount.
    local originX = math.floor(minimumX)
    local originY = math.floor(minimumY)

    -- Extent this render covers at 100% preview resolution.
    local nativeWidth = math.max(1, math.ceil(maximumX - originX))
    local nativeHeight = math.max(1, math.ceil(maximumY - originY))

    local outputWidth = math.max(1, math.ceil(nativeWidth * renderScale))
    local outputHeight = math.max(1, math.ceil(nativeHeight * renderScale))

    -- Sample on a grid that spans exactly the native extent, so a reduced-resolution render
    -- is a coarser view of the same area (and never overshoots it).
    local worldStepX = nativeWidth / outputWidth
    local worldStepY = nativeHeight / outputHeight

    local isPreview = (previewAlpha ~= nil) and (previewAlpha < 255)
    local useRgbMode = isPreview or (samplingMode == "Bilinear")
    local outputImage = Image(outputWidth, outputHeight, useRgbMode and ColorMode.RGB or sourceImage.colorMode)
    
    local pixelColorTools = app.pixelColor
    local isIndexed = sourceImage.colorMode == ColorMode.INDEXED
    local isGrayscale = sourceImage.colorMode == ColorMode.GRAY
    local palette = isIndexed and app.activeSprite.palettes[1] or nil
    local transparentIndex = isIndexed and app.activeSprite.transparentColor or -1

    -- Destinations and their AABBs are constant for the whole frame: build them once here
    -- instead of recomputing per output pixel.
    local gridCells = buildGridCells(destinationPoints, gridResolution, sourceImage.width, sourceImage.height)

    for y = 0, outputHeight - 1 do
        for x = 0, outputWidth - 1 do
            local worldX = originX + (x + 0.5) * worldStepX
            local worldY = originY + (y + 0.5) * worldStepY

            local sampleX, sampleY = findSourceCoordinate(worldX, worldY, gridCells)
            
            if sampleX and sampleY then
                if samplingMode == "Bilinear" then
                    local sampledColor = getBilinearSampledColor(sourceImage, sampleX, sampleY, isIndexed, palette, transparentIndex, isGrayscale, pixelColorTools)
                    
                    if isPreview then
                        local extractedRed = pixelColorTools.rgbaR(sampledColor)
                        local extractedGreen = pixelColorTools.rgbaG(sampledColor)
                        local extractedBlue = pixelColorTools.rgbaB(sampledColor)
                        local extractedAlpha = math.floor(pixelColorTools.rgbaA(sampledColor) * (previewAlpha / 255.0))
                        sampledColor = pixelColorTools.rgba(extractedRed, extractedGreen, extractedBlue, extractedAlpha)
                    end
                    outputImage:drawPixel(x, y, sampledColor)
                    
                else
                    -- Continuous coordinate -> containing pixel index, clamped to the image.
                    local nearestSourceX = math.max(0, math.min(sourceImage.width - 1, math.floor(sampleX)))
                    local nearestSourceY = math.max(0, math.min(sourceImage.height - 1, math.floor(sampleY)))
                    
                    local rawColor = sourceImage:getPixel(nearestSourceX, nearestSourceY)
                    
                    if isPreview then
                        local extractedRed, extractedGreen, extractedBlue, extractedAlpha = extractPixelRgba(sourceImage, nearestSourceX, nearestSourceY, isIndexed, palette, transparentIndex, isGrayscale, pixelColorTools)
                        extractedAlpha = math.floor(extractedAlpha * (previewAlpha / 255.0))
                        rawColor = pixelColorTools.rgba(extractedRed, extractedGreen, extractedBlue, extractedAlpha)
                    end
                    
                    outputImage:drawPixel(x, y, rawColor)
                end
            end
        end
    end
    
    -- The native extent is the size this render would have at 100% preview resolution. The
    -- caller needs it to place a reduced-resolution preview on the canvas pixel grid.
    return outputImage, Point(originX, originY), nativeWidth, nativeHeight
end

-- Nearest-neighbor scale used to expand a reduced-resolution preview back to the native
-- canvas pixel grid before it is baked into the composite. Without this step a "Preview
-- Res %" below 100 would shrink the preview instead of making it coarser.
local function upscaleImageNearest(sourceImage, targetWidth, targetHeight)
    targetWidth = math.max(1, targetWidth)
    targetHeight = math.max(1, targetHeight)

    if sourceImage.width == targetWidth and sourceImage.height == targetHeight then
        return sourceImage
    end

    local scaledImage = Image(targetWidth, targetHeight, sourceImage.colorMode)
    local sourcePerTargetX = sourceImage.width / targetWidth
    local sourcePerTargetY = sourceImage.height / targetHeight

    for y = 0, targetHeight - 1 do
        -- Sample at target pixel centers so the upscaled blocks stay aligned to the grid.
        local sourceY = math.min(sourceImage.height - 1, math.floor((y + 0.5) * sourcePerTargetY))
        for x = 0, targetWidth - 1 do
            local sourceX = math.min(sourceImage.width - 1, math.floor((x + 0.5) * sourcePerTargetX))
            scaledImage:drawPixel(x, y, sourceImage:getPixel(sourceX, sourceY))
        end
    end

    return scaledImage
end

-- Helper utility to draw primitive rectangles representing interaction handles.
local function drawInteractiveHandle(graphicsContext, x, y, size, fillColor, strokeColor)
    graphicsContext:beginPath()
    graphicsContext:moveTo(x, y)
    graphicsContext:lineTo(x + size, y)
    graphicsContext:lineTo(x + size, y + size)
    graphicsContext:lineTo(x, y + size)
    graphicsContext:closePath()
    
    graphicsContext.color = fillColor
    graphicsContext:fill()
    graphicsContext.color = strokeColor
    graphicsContext:stroke()
end

-- Renders a generic transparency checkerboard bounded to the UI frame.
local function drawTransparencyCheckerboard(graphicsContext, x, y, width, height, checkerSize)
    local colorDark = Color{r=60, g=60, b=60}
    local colorLight = Color{r=80, g=80, b=80}
    
    local integerX = math.max(math.floor(x), 0)
    local integerY = math.max(math.floor(y), 0)
    local rightBound = math.min(math.floor(x + width), CanvasSize)
    local bottomBound = math.min(math.floor(y + height), CanvasSize)
    
    local boundedWidth = rightBound - integerX
    local boundedHeight = bottomBound - integerY
    
    if boundedWidth <= 0 or boundedHeight <= 0 then return end
    
    local offsetX = integerX - math.floor(x)
    local offsetY = integerY - math.floor(y)
    
    local startColumn = math.floor(offsetX / checkerSize)
    local startRow = math.floor(offsetY / checkerSize)
    
    for checkerY = startRow, math.ceil((offsetY + boundedHeight) / checkerSize) - 1 do
        for checkerX = startColumn, math.ceil((offsetX + boundedWidth) / checkerSize) - 1 do
            graphicsContext.color = ((checkerX + checkerY) % 2 == 0) and colorDark or colorLight
            
            local boxX = math.floor(x) + checkerX * checkerSize
            local boxY = math.floor(y) + checkerY * checkerSize
            
            local drawX = math.max(integerX, boxX)
            local drawY = math.max(integerY, boxY)
            local drawRight = math.min(rightBound, boxX + checkerSize)
            local drawBottom = math.min(bottomBound, boxY + checkerSize)
            
            graphicsContext:fillRect(Rectangle(drawX, drawY, drawRight - drawX, drawBottom - drawY))
        end
    end
end

-- Erases the selected pixels from the provided image before plotting the new distortion.
local function clearSelectedPixels(targetImage, sprite, selection, bounds, celPosition)
    local backgroundColor = (sprite.colorMode == ColorMode.INDEXED) and sprite.transparentColor or Color{r=0, g=0, b=0, a=0}
    for y = bounds.y, bounds.y + bounds.height - 1 do
        for x = bounds.x, bounds.x + bounds.width - 1 do
            if selection.isEmpty or selection:contains(x, y) then
                local canvasX, canvasY = x - celPosition.x, y - celPosition.y
                if canvasX >= 0 and canvasX < targetImage.width and canvasY >= 0 and canvasY < targetImage.height then
                    targetImage:drawPixel(canvasX, canvasY, backgroundColor)
                end
            end
        end
    end
end

-- Color that keeps uncovered pixels transparent in the sprite's color mode.
local function transparentBackgroundColor(sprite)
    if sprite.colorMode == ColorMode.INDEXED then
        return Color{ index = sprite.transparentColor }
    end
    return Color{ r = 0, g = 0, b = 0, a = 0 }
end

-- Bounds (in canvas pixels) of the native-resolution image that holds the background art
-- and the warped preview. Kept integral so the two share one pixel grid.
local function calculateCompositeBounds(spriteWidth, spriteHeight, previewOffset, previewWidth, previewHeight, includeContext)
    if includeContext then
        return math.min(0, previewOffset.x),
               math.min(0, previewOffset.y),
               math.max(spriteWidth, previewOffset.x + previewWidth),
               math.max(spriteHeight, previewOffset.y + previewHeight)
    end
    return previewOffset.x,
           previewOffset.y,
           previewOffset.x + previewWidth,
           previewOffset.y + previewHeight
end

-- The main entry point for the extension.
local function initializeMeshWarpTool()
    local sprite = app.activeSprite
    local cel = app.activeCel
    
    if not sprite then return app.alert("No active sprite found.") end
    if not cel then return app.alert("No active cel found on the current layer.") end

    local selection = sprite.selection
    local sourceBounds = selection.bounds
    if sourceBounds.isEmpty then
        sourceBounds = cel.bounds
    end

    local sourceImage = Image(sourceBounds.width, sourceBounds.height, sprite.colorMode)
    sourceImage:drawImage(cel.image, Point(-(sourceBounds.x - cel.bounds.x), -(sourceBounds.y - cel.bounds.y)))

    local showContext = true
    local viewBox = Rectangle()
    local viewScale = 1
    local viewOffsetX = 0
    local viewOffsetY = 0
    
    local currentGridResolution = 2
    local samplingMode = "Nearest Neighbor"

    local cameraZoom = 1.0
    local cameraPanX = 0
    local cameraPanY = 0
    local isPanning = false
    local lastMouseX = 0
    local lastMouseY = 0

    local destinationPoints = {}
    for row = 0, currentGridResolution do
        for column = 0, currentGridResolution do
            table.insert(destinationPoints, {
                x = sourceBounds.x + (column / currentGridResolution) * sourceBounds.width,
                y = sourceBounds.y + (row / currentGridResolution) * sourceBounds.height
            })
        end
    end

    local activePointIndex = 0
    local isDragging = false
    local needsUpdate = true
    -- While a handle is held, renders are driven by this timer instead of one render per
    -- mouse-move event. nil when the running Aseprite build has no Timer class.
    local dragRenderTimer = nil
    local isDialogOpen = true
    local previewImage = nil
    local previewOffset = Point(0,0)
    -- Size the preview occupies on the canvas grid (i.e. its size at 100% preview resolution).
    local previewNativeWidth = 1
    local previewNativeHeight = 1

    local rawContextImage = nil
    -- The preview is baked into the background art at native resolution, so both are
    -- rasterized as one bitmap and therefore share the same pixel grid on screen.
    local compositeImage = nil
    local compositeOffset = Point(0, 0)

    app.transaction("Temp Capture Context", function()
        local tempCelImage = cel.image:clone()
        clearSelectedPixels(tempCelImage, sprite, selection, sourceBounds, cel.position)
        cel.image = tempCelImage
    end)
    
    rawContextImage = Image(sprite.width, sprite.height, sprite.colorMode)
    rawContextImage:drawSprite(sprite, app.activeFrame)
    app.undo()

    local function updateViewMetrics()
        if showContext then
            viewBox = Rectangle(0, 0, sprite.width, sprite.height)
        else
            viewBox = sourceBounds
        end
        viewScale = WorkAreaSize / math.max(viewBox.width, viewBox.height)
        viewOffsetX = (CanvasSize - (viewBox.width * viewScale)) / 2
        viewOffsetY = (CanvasSize - (viewBox.height * viewScale)) / 2
        needsUpdate = true
    end

    local function globalToUi(globalX, globalY)
        local baseUiX = viewOffsetX + (globalX - viewBox.x) * viewScale
        local baseUiY = viewOffsetY + (globalY - viewBox.y) * viewScale
        
        local centerX = CanvasSize / 2
        local centerY = CanvasSize / 2
        
        -- Translate to the center of the canvas, apply the zoom and pan camera offsets, and translate back.
        local finalUiX = (baseUiX - centerX + cameraPanX) * cameraZoom + centerX
        local finalUiY = (baseUiY - centerY + cameraPanY) * cameraZoom + centerY
        return finalUiX, finalUiY
    end

    local function uiToGlobal(uiX, uiY)
        local centerX = CanvasSize / 2
        local centerY = CanvasSize / 2
        
        local baseUiX = (uiX - centerX) / cameraZoom + centerX - cameraPanX
        local baseUiY = (uiY - centerY) / cameraZoom + centerY - cameraPanY
        
        local globalX = viewBox.x + (baseUiX - viewOffsetX) / viewScale
        local globalY = viewBox.y + (baseUiY - viewOffsetY) / viewScale
        return globalX, globalY
    end

    -- Bakes the warped preview into the background art at native (canvas-pixel) resolution.
    -- Both are canvas-aligned with integer offsets, so this copy is 1:1 and exact; the
    -- result is drawn to the dialog in a single blit, which keeps the warp and the art on
    -- the same pixel grid regardless of view scale, camera zoom or integer rounding.
    local function rebuildComposite()
        -- Expand the (possibly reduced-resolution) preview onto the native canvas grid so
        -- it occupies exactly the same world extent at any "Preview Res %" setting.
        local nativePreview = upscaleImageNearest(previewImage, previewNativeWidth, previewNativeHeight)

        local compositeMinX, compositeMinY, compositeMaxX, compositeMaxY = calculateCompositeBounds(
            sprite.width, sprite.height, previewOffset,
            nativePreview.width, nativePreview.height, showContext)

        compositeOffset = Point(compositeMinX, compositeMinY)
        -- Match the preview's color mode so a semi-transparent or bilinear preview is not
        -- quantized into the sprite palette before it is displayed.
        compositeImage = Image(compositeMaxX - compositeMinX,
                               compositeMaxY - compositeMinY,
                               nativePreview.colorMode)
        compositeImage:clear(compositeImage.bounds, transparentBackgroundColor(sprite))

        if showContext then
            compositeImage:drawImage(rawContextImage, Point(-compositeMinX, -compositeMinY))
        end
        -- Preview alpha (opacity) is already baked into the preview, so blend at 255.
        compositeImage:drawImage(nativePreview, Point(previewOffset.x - compositeMinX,
                                                      previewOffset.y - compositeMinY))
    end

    updateViewMetrics()
    local dialog = Dialog("Mesh Warp Tool")

    -- dialog:repaint() invokes the canvas onpaint callback synchronously, so repainting on
    -- every mouse-move event ties the render rate to the input device (potentially hundreds
    -- of renders per second). While dragging, render from this 30 Hz pump instead: events
    -- only update the mesh, intermediate positions are coalesced, and the latest state is
    -- always what gets drawn. Other interactions keep repainting immediately.
    if Timer then
        dragRenderTimer = Timer {
            interval = 1 / 30,
            ontick = function()
                if not isDialogOpen then
                    dragRenderTimer:stop()
                    return
                end
                if not needsUpdate then
                    return
                end
                -- onpaint clears needsUpdate, so an idle drag does no work.
                local ok, err = pcall(dialog.repaint, dialog)
                if not ok then
                    -- The dialog was closed externally; stop the pump.
                    dragRenderTimer:stop()
                    if err then print(err) end
                end
            end
        }
    end

    dialog:slider {
        id = "gridResolution",
        label = "Grid Size:",
        min = 1,
        max = 6,
        value = currentGridResolution,
        onchange = function()
            local newResolution = dialog.data.gridResolution
            if newResolution ~= currentGridResolution then
                destinationPoints = recalculateGridPoints(destinationPoints, currentGridResolution, newResolution)
                currentGridResolution = newResolution
                activePointIndex = 0
                needsUpdate = true
                dialog:repaint()
            end
        end
    }
    
    dialog:slider {
        id = "previewScale",
        label = "Preview Res %:",
        min = 10,
        max = 100,
        value = 100,
        onchange = function()
            needsUpdate = true
            dialog:repaint()
        end
    }

    dialog:combobox {
        id = "samplingMode",
        label = "Sampling:",
        option = samplingMode,
        options = { "Nearest Neighbor", "Bilinear" },
        onchange = function()
            samplingMode = dialog.data.samplingMode
            needsUpdate = true
            dialog:repaint()
        end
    }

    dialog:slider {
        id = "previewOpacity",
        label = "Opacity:",
        min = 0,
        max = 255,
        value = 255,
        onchange = function()
            needsUpdate = true
            dialog:repaint()
        end
    }

    dialog:canvas {
        id = "preview",
        width = CanvasSize,
        height = CanvasSize,
        onpaint = function(event)
            local graphicsContext = event.context
            
            graphicsContext.color = Color{r=40, g=40, b=40}
            graphicsContext:fillRect(Rectangle(0, 0, CanvasSize, CanvasSize))

            local backgroundX, backgroundY = globalToUi(viewBox.x, viewBox.y)
            local backgroundRight, backgroundBottom = globalToUi(viewBox.x + viewBox.width, viewBox.y + viewBox.height)
            local backgroundWidth = backgroundRight - backgroundX
            local backgroundHeight = backgroundBottom - backgroundY

            drawTransparencyCheckerboard(graphicsContext, backgroundX, backgroundY, backgroundWidth, backgroundHeight, 10 * cameraZoom)

            local currentAlpha = (dialog.data and dialog.data.previewOpacity) or 255
            local currentScale = (dialog.data and dialog.data.previewScale) or 100
            local renderScale = currentScale / 100.0

            if needsUpdate then
                previewImage, previewOffset, previewNativeWidth, previewNativeHeight =
                    renderDistortedImage(sourceImage, destinationPoints, currentGridResolution, currentAlpha, samplingMode, renderScale)
                rebuildComposite()
                needsUpdate = false
            end

            if compositeImage then
                local compositeUiX, compositeUiY = globalToUi(compositeOffset.x, compositeOffset.y)
                local compositeUiRight, compositeUiBottom = globalToUi(
                    compositeOffset.x + compositeImage.width,
                    compositeOffset.y + compositeImage.height)

                -- Round both edges from the same transform so the single bitmap lands as
                -- close to the canvas grid as an integer blit allows.
                local drawX = math.floor(compositeUiX + 0.5)
                local drawY = math.floor(compositeUiY + 0.5)
                local drawRight = math.floor(compositeUiRight + 0.5)
                local drawBottom = math.floor(compositeUiBottom + 0.5)

                graphicsContext:drawImage(
                    compositeImage,
                    Rectangle(0, 0, compositeImage.width, compositeImage.height),
                    Rectangle(drawX, drawY,
                              math.max(1, drawRight - drawX),
                              math.max(1, drawBottom - drawY))
                )
            end

            graphicsContext.color = Color{r=200, g=200, b=200}
            local pointsPerRow = currentGridResolution + 1
            
            for row = 0, currentGridResolution do
                for column = 0, currentGridResolution - 1 do
                    local index1 = row * pointsPerRow + column + 1
                    local index2 = index1 + 1
                    local uiX1, uiY1 = globalToUi(destinationPoints[index1].x, destinationPoints[index1].y)
                    local uiX2, uiY2 = globalToUi(destinationPoints[index2].x, destinationPoints[index2].y)
                    graphicsContext:beginPath()
                    graphicsContext:moveTo(uiX1, uiY1)
                    graphicsContext:lineTo(uiX2, uiY2)
                    graphicsContext:stroke()
                end
            end
            
            for column = 0, currentGridResolution do
                for row = 0, currentGridResolution - 1 do
                    local index1 = row * pointsPerRow + column + 1
                    local index2 = (row + 1) * pointsPerRow + column + 1
                    local uiX1, uiY1 = globalToUi(destinationPoints[index1].x, destinationPoints[index1].y)
                    local uiX2, uiY2 = globalToUi(destinationPoints[index2].x, destinationPoints[index2].y)
                    graphicsContext:beginPath()
                    graphicsContext:moveTo(uiX1, uiY1)
                    graphicsContext:lineTo(uiX2, uiY2)
                    graphicsContext:stroke()
                end
            end

            for index, point in ipairs(destinationPoints) do
                local uiX, uiY = globalToUi(point.x, point.y)
                local fillColor = (index == activePointIndex) and Color{r=255, g=50, b=50} or Color{r=50, g=150, b=255}
                local strokeColor = Color{r=255, g=255, b=255}
                
                drawInteractiveHandle(graphicsContext, uiX - HandleRadius, uiY - HandleRadius, HandleRadius * 2, fillColor, strokeColor)
            end
            
            graphicsContext.color = Color{r=120, g=120, b=120}
            graphicsContext:strokeRect(Rectangle(math.floor(backgroundX), math.floor(backgroundY), math.floor(backgroundWidth), math.floor(backgroundHeight)))
        end,
        onwheel = function(event)
            local mouseX, mouseY = event.x, event.y
            local centerX = CanvasSize / 2
            local centerY = CanvasSize / 2
            
            local oldBaseUiX = (mouseX - centerX) / cameraZoom + centerX - cameraPanX
            local oldBaseUiY = (mouseY - centerY) / cameraZoom + centerY - cameraPanY
            
            if event.deltaY > 0 then
                cameraZoom = cameraZoom / 1.15
            elseif event.deltaY < 0 then
                cameraZoom = cameraZoom * 1.15
            end
            
            cameraZoom = math.max(0.1, math.min(cameraZoom, 15.0))
            
            cameraPanX = (mouseX - centerX) / cameraZoom + centerX - oldBaseUiX
            cameraPanY = (mouseY - centerY) / cameraZoom + centerY - oldBaseUiY
            
            dialog:repaint()
        end,
        onmousedown = function(event)
            local mouseX, mouseY = event.x, event.y
            
            if event.button == MouseButton.MIDDLE or event.button == MouseButton.RIGHT then
                isPanning = true
                lastMouseX = mouseX
                lastMouseY = mouseY
                return
            end

            for index, point in ipairs(destinationPoints) do
                local uiX, uiY = globalToUi(point.x, point.y)
                local distance = math.sqrt((mouseX - uiX)^2 + (mouseY - uiY)^2)
                
                if distance <= HandleRadius * 2.5 then
                    activePointIndex = index
                    isDragging = true
                    if dragRenderTimer then dragRenderTimer:start() end
                    dialog:repaint()
                    break
                end
            end
            
            if not isDragging then
                isPanning = true
                lastMouseX = mouseX
                lastMouseY = mouseY
            end
        end,
        onmousemove = function(event)
            if isPanning then
                local deltaX = event.x - lastMouseX
                local deltaY = event.y - lastMouseY
                cameraPanX = cameraPanX + deltaX / cameraZoom
                cameraPanY = cameraPanY + deltaY / cameraZoom
                lastMouseX = event.x
                lastMouseY = event.y
                dialog:repaint()
            elseif isDragging and activePointIndex > 0 then
                local globalX, globalY = uiToGlobal(event.x, event.y)
                destinationPoints[activePointIndex].x = globalX
                destinationPoints[activePointIndex].y = globalY
                
                needsUpdate = true
                if not dragRenderTimer then
                    -- Older Aseprite without Timer: keep the original per-event repaint.
                    dialog:repaint()
                end
            end
        end,
        onmouseup = function(event)
            isDragging = false
            isPanning = false
            activePointIndex = 0
            if dragRenderTimer then dragRenderTimer:stop() end
            -- Guarantee one final frame with the released handle position.
            needsUpdate = true
            dialog:repaint()
        end
    }

    dialog:check {
        id = "showContext",
        text = "Show Full Canvas Context",
        selected = true,
        onclick = function()
            showContext = dialog.data.showContext
            updateViewMetrics()
            dialog:repaint()
        end
    }

    dialog:separator()

    dialog:button {
        id = "apply",
        text = "Apply Mesh Warp",
        onclick = function()
            app.transaction(function()
                local finalImage, offset = renderDistortedImage(sourceImage, destinationPoints, currentGridResolution, 255, samplingMode, 1.0)
                if not finalImage then return end

                local newCelImage = cel.image:clone()
                local celPosition = cel.position
                
                clearSelectedPixels(newCelImage, sprite, selection, sourceBounds, celPosition)

                local finalGlobalX = offset.x
                local finalGlobalY = offset.y
                local minX = math.min(celPosition.x, finalGlobalX)
                local minY = math.min(celPosition.y, finalGlobalY)
                local maxX = math.max(celPosition.x + newCelImage.width, finalGlobalX + finalImage.width)
                local maxY = math.max(celPosition.y + newCelImage.height, finalGlobalY + finalImage.height)
                
                local compositeImage = Image(maxX - minX, maxY - minY, sprite.colorMode)
                compositeImage:clear(compositeImage.bounds, transparentBackgroundColor(sprite))
                compositeImage:drawImage(newCelImage, Point(celPosition.x - minX, celPosition.y - minY))
                compositeImage:drawImage(finalImage, Point(finalGlobalX - minX, finalGlobalY - minY))
                
                cel.image = compositeImage
                cel.position = Point(minX, minY)
            end)
            isDialogOpen = false
            if dragRenderTimer then dragRenderTimer:stop() end
            dialog:close()
        end
    }

    dialog:button {
        id = "cancel",
        text = "Cancel",
        onclick = function()
            isDialogOpen = false
            if dragRenderTimer then dragRenderTimer:stop() end
            dialog:close()
        end
    }

    dialog:show { wait = false }
end

initializeMeshWarpTool()
--!strict
local Theme = require(script.Parent.Theme)
local Data = require(script.Parent.ProviderLogoData)
local Icons = require(script.Parent.Icons)
local ProviderLogo = {}
-- Local PNGs load through rbxasset. A compact rendering of the same PNG keeps
-- logos visible on portable installations and after a Studio version update.
function ProviderLogo.build(id: string?, size: number): Frame
    local frame = Instance.new("Frame")
    frame.Name = "ProviderLogo"
    frame.Size = UDim2.fromOffset(size, size)
    Theme.passThrough(frame)
    local runs = if id then Data[id] else nil
    if not runs then
        local mark = Icons.glyph("ProviderCustom", size, Theme.Colors.Highlight)
        mark.Name = "Fallback"; mark.Size = UDim2.fromScale(1, 1); mark.Parent = frame
        return frame
    end
    local fallback = Instance.new("Frame")
    fallback.Name = "BundledLogo"; fallback.Size = UDim2.fromScale(1, 1); Theme.passThrough(fallback); fallback.Parent = frame
    for index, run in runs do
        local pixel = Instance.new("Frame")
        pixel.Name = "Run" .. index
        pixel.Position = UDim2.fromScale(run[1] / 20, run[2] / 20)
        pixel.Size = UDim2.fromScale(run[3] / 20, 1 / 20)
        pixel.BackgroundColor3 = Color3.fromRGB(run[4], run[5], run[6])
        pixel.BackgroundTransparency = 1 - run[7] / 255
        pixel.BorderSizePixel = 0; pixel.Active = false; pixel.Parent = fallback
    end
    local image = Instance.new("ImageLabel")
    image.Name = "PNG"; image.Size = UDim2.fromScale(1, 1); image.BackgroundTransparency = 1
    image.Image = "rbxasset://ForgePilot/providers/" .. id .. ".png"
    image.ScaleType = Enum.ScaleType.Fit; image.Visible = false; image.Parent = frame
    image:GetPropertyChangedSignal("IsLoaded"):Connect(function() image.Visible = image.IsLoaded; fallback.Visible = not image.IsLoaded end)
    image.Visible = image.IsLoaded; fallback.Visible = not image.IsLoaded
    return frame
end
return ProviderLogo

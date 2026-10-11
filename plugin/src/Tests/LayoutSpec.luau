--!nocheck
--[[
	ForgePilot / Tests / LayoutSpec — geometry regression suite (development only).

	NOT part of the Rojo tree and never shipped in the RBXM. It runs inside the
	mock Roblox runtime driven by .devtools/run-layout.mjs, which places the real
	plugin instance tree with the deterministic solver in .devtools/roblox-layout.luau
	and then hands the resulting geometry here.

	The previous suites only checked that modules returned tables, so the visible
	defects — overlapping Settings tabs, toggles under their own label, clipped
	suggestions, controls spilling out of a 320px window — passed every time.
	Every assertion below reads real AbsolutePosition / AbsoluteSize / Visible /
	ZIndex values at real viewport sizes instead.

	Each tab is activated before it is measured, because a hidden branch of the
	tree is never laid out and "it looks fine" would be a vacuous pass.
]]

local LayoutSpec = {}

local WIDTHS = { 320, 360, 420, 500, 640, 800 }
local HEIGHTS = { 400, 600, 800 }
local SECTIONS = { "chat", "builder", "history", "logs", "settings" }
local SETTINGS_SECTIONS = { "General", "AI & Provider", "Agent", "Retry", "Data" }

-- Frames whose children are deliberately layered rather than flowed, and
-- decorative layers that are meant to sit underneath the content.
local STACKED_PARENTS = {
	Track = true,
	Knob = true,
	-- Track, its stroke, the knob and the transparent Hit target are all drawn
	-- on the same rectangle by design.
	SwitchHolder = true,
	Backdrop = true,
	Glow = true,
	ForgePilotMark = true,
	BrandMark = true,
	NoScrollbar = true,
}

local DECORATIVE = {
	Backdrop = true,
	Glow = true,
}

local function isGui(inst)
	return inst:IsA("GuiObject")
end

local function byName(parent, name)
	local found = parent:FindFirstChild(name)
	if found and isGui(found) then
		return found
	end
	return nil
end

local function rectOf(layout, inst)
	if not inst then
		return nil
	end
	return layout.rectOf(inst)
end

--- The nearest ancestor that actually clips its children, if any.
---
--- Content inside a ScrollingFrame is bounded by that scroller rather than by
--- the window, so the window-bounds rule does not apply to it — a settings
--- subtab strip that scrolls horizontally is exactly this case.
local function clippingAncestor(inst)
	local cursor = inst.Parent
	while cursor and isGui(cursor) do
		if cursor.ClipsDescendants == true then
			return cursor
		end
		cursor = cursor.Parent
	end
	return nil
end

local function overlapArea(a, b, slack)
	if not (a and b) then
		return 0
	end
	slack = slack or 0.5
	local w = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
	local h = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
	if w <= slack or h <= slack then
		return 0
	end
	return w * h
end

--- Overlays are allowed to sit outside the window and on top of everything.
local function isOverlay(inst)
	local cursor = inst
	while cursor and isGui(cursor) do
		local name = cursor.Name
		if name == "Toast" or name == "OverlayLayer" or name == "WelcomeOverlay" then
			return true
		end
		if (cursor.ZIndex or 1) >= 40 then
			return true
		end
		cursor = cursor.Parent
	end
	return false
end

local function describe(inst)
	return string.format(
		"%s (%.0f,%.0f %.0fx%.0f)",
		inst:GetFullName(),
		inst.AbsolutePosition.X,
		inst.AbsolutePosition.Y,
		inst.AbsoluteSize.X,
		inst.AbsoluteSize.Y
	)
end

--=============================================================================
-- GENERIC SWEEP
--=============================================================================

local function sweep(layout, gui, width, height)
	local problems = {}
	local checked = 0

	for _, node in ipairs(gui:GetDescendants()) do
		if isGui(node) and node.Visible ~= false then
			local r = rectOf(layout, node)
			if r then
				checked += 1
				-- A non-finite rectangle poisons every descendant and every
				-- comparison against it, so it must be caught before anything
				-- else looks at the numbers.
				if
					r.x ~= r.x
					or r.y ~= r.y
					or r.w ~= r.w
					or r.h ~= r.h
					or r.x == math.huge
					or r.x == -math.huge
					or r.y == math.huge
					or r.y == -math.huge
				then
					problems[#problems + 1] = string.format(
						"non-finite geometry (NaN/Inf): %s resolved to x=%s y=%s w=%s h=%s",
						describe(node), tostring(r.x), tostring(r.y), tostring(r.w), tostring(r.h)
					)
				else
					local clipped = clippingAncestor(node)
					if not isOverlay(node) and not clipped then
					if r.x < -1 or r.x + r.w > width + 1 then
						problems[#problems + 1] = string.format(
							"horizontal overflow: %s (window %dpx)", describe(node), width
						)
					end
					if r.y < -1 or r.y + r.h > height + 1 then
						problems[#problems + 1] = string.format(
							"vertical overflow: %s (window %dpx tall)", describe(node), height
						)
					end
				end

				if node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox") then
					local info = layout.textInfoOf(node)
					if info and info.neededHeight and info.neededHeight > r.h + 1.5 then
						problems[#problems + 1] = string.format(
							"clipped text: %s needs %.1fpx (size %d, %d line(s)) but has %.1fpx",
							describe(node), info.neededHeight, node.TextSize,
							math.ceil(info.neededHeight / (node.TextSize * 1.25)), r.h
						)
					end
					-- A non-wrapped, non-truncated label has no defence against
					-- a long value: it paints straight over its neighbours.
					if info and not info.wrapped and not info.neededHeight and node.TextTruncate == Enum.TextTruncate.None then
						local pad = 0
						if r.w > 0 and info.width > r.w + pad then
							local parent = node.Parent
							local managed = false
							if parent then
								for _, child in ipairs(parent:GetChildren()) do
									if child.ClassName == "UIListLayout" and child.Enabled ~= false then
										managed = true
									end
								end
							end
							if managed then
								problems[#problems + 1] = string.format(
									"unclipped long text in a horizontal row: %s needs %.0fpx but has %.0fpx",
									describe(node), info.width, r.w
								)
							end
						end
					end
				end
				end
			end
		end
	end

	for _, parent in ipairs(gui:GetDescendants()) do
		if isGui(parent) and parent.Visible ~= false and not STACKED_PARENTS[parent.Name] then
			local managed = false
			for _, child in ipairs(parent:GetChildren()) do
				if (child.ClassName == "UIListLayout" or child.ClassName == "UIGridLayout")
					and child.Enabled ~= false then
					managed = true
				end
			end
			if not managed then
				local flow = {}
				for _, child in ipairs(parent:GetChildren()) do
					if
						isGui(child)
						and child.Visible ~= false
						and not isOverlay(child)
						and not DECORATIVE[child.Name]
					then
						local r = rectOf(layout, child)
						if r and r.w > 1 and r.h > 1 then
							flow[#flow + 1] = { inst = child, r = r }
						end
					end
				end
				for i = 1, #flow do
					for j = i + 1, #flow do
						local area = overlapArea(flow[i].r, flow[j].r, 1)
						if area > 0 then
							problems[#problems + 1] = string.format(
								"overlapping siblings in %s:\n          %s\n       <> %s\n          (%.0f px2, window %dpx)",
								parent:GetFullName(),
								describe(flow[i].inst),
								describe(flow[j].inst),
								area,
								width
							)
						end
					end
				end
			end
		end
	end

	return problems, checked
end

--=============================================================================
-- STRUCTURAL CHECKS
--=============================================================================

local function checkShell(layout, gui, width, problems)
	local root = byName(gui, "Root")
	if not root then
		problems[#problems + 1] = "no Root frame"
		return
	end
	local header, nav, content = byName(root, "Header"), byName(root, "Nav"), byName(root, "Content")
	for name, node in { Header = header, Nav = nav, Content = content } do
		if not node then
			problems[#problems + 1] = string.format("the shell is missing %s", name)
		end
	end
	if not (header and nav and content) then
		return
	end

	local hr, nr, cr = rectOf(layout, header), rectOf(layout, nav), rectOf(layout, content)
	local rootRect = rectOf(layout, root)
	if not (hr and nr and cr and rootRect) then
		problems[#problems + 1] = "the shell regions were not laid out"
		return
	end
	if overlapArea(hr, nr) > 0 then
		problems[#problems + 1] = "the header overlaps the navigation bar"
	end
	if overlapArea(nr, cr) > 0 then
		problems[#problems + 1] = "the navigation bar overlaps the page content"
	end
	if cr.y < nr.y + nr.h - 0.5 then
		problems[#problems + 1] = "the page content starts above the navigation bar"
	end
	if cr.y + cr.h > rootRect.y + rootRect.h + 1 then
		problems[#problems + 1] = string.format(
			"the page content runs %.0fpx past the bottom of the window",
			cr.y + cr.h - (rootRect.y + rootRect.h)
		)
	end

	local track = byName(nav, "Track")
	if not track then
		problems[#problems + 1] = "the navigation strip has no Track"
		return
	end
	local trackRect = rectOf(layout, track)
	local previousRight = nil
	local count = 0
	for _, child in ipairs(track:GetChildren()) do
		if isGui(child) and child.Visible ~= false then
			count += 1
			local r = rectOf(layout, child)
			if not r then
				problems[#problems + 1] = "a navigation tab was not laid out"
			else
				if trackRect and (r.x < trackRect.x - 1 or r.x + r.w > trackRect.x + trackRect.w + 1) then
					problems[#problems + 1] = string.format(
						"a navigation tab escapes the strip: %s (window %dpx)", describe(child), width
					)
				end
				if previousRight and r.x < previousRight - 0.5 then
					problems[#problems + 1] = string.format(
						"navigation tabs overlap: %s (window %dpx)", describe(child), width
					)
				end
				if r.h < 20 then
					problems[#problems + 1] = string.format(
						"a navigation tab is only %.0fpx tall: %s", r.h, describe(child)
					)
				end
				previousRight = r.x + r.w
			end
		end
	end
	if count ~= 5 then
		problems[#problems + 1] = string.format("expected 5 navigation tabs, found %d", count)
	end
end

local function checkSettings(layout, view, width, problems)
	local tabs = view:FindFirstChild("SectionTabs", true)
	local page = view:FindFirstChild("Page", true)
	if not (isGui(tabs) and isGui(page)) then
		problems[#problems + 1] = "SettingsView is missing SectionTabs or Page"
		return
	end

	local tabsRect, pageRect = rectOf(layout, tabs), rectOf(layout, page)
	if not (tabsRect and pageRect) then
		problems[#problems + 1] = "the Settings regions were not laid out"
		return
	end
	if overlapArea(tabsRect, pageRect) > 0 then
		problems[#problems + 1] = "the Settings subtabs overlap the settings content"
	end
	if pageRect.y < tabsRect.y + tabsRect.h - 0.5 then
		problems[#problems + 1] = "the settings content starts above the subtab strip"
	end
	if tabsRect.x < -1 or tabsRect.x + tabsRect.w > width + 1 then
		problems[#problems + 1] = "the subtab strip itself escapes the window"
	end

	-- Tabs tile from left to right and never overlap. When the strip is wide
	-- enough for all five they must also all fit; when it is not, the strip must
	-- be scrollable rather than squashing them into each other.
	local previousRight = nil
	local seen = 0
	local rightmost = nil
	for _, child in ipairs(tabs:GetChildren()) do
		if isGui(child) and child.Visible ~= false then
			seen += 1
			local r = rectOf(layout, child)
			if not r then
				problems[#problems + 1] = "a Settings subtab was not laid out"
			else
				if previousRight and r.x < previousRight - 0.5 then
					problems[#problems + 1] = string.format(
						"Settings subtabs overlap: %s (window %dpx)", describe(child), width
					)
				end
				if r.h < 18 then
					problems[#problems + 1] = string.format(
						"a Settings subtab is only %.0fpx tall: %s", r.h, describe(child)
					)
				end
				previousRight = r.x + r.w
				rightmost = r.x + r.w
			end
		end
	end
	if seen ~= 5 then
		problems[#problems + 1] = string.format("expected 5 Settings subtabs, found %d", seen)
	end
	if rightmost and rightmost > tabsRect.x + tabsRect.w + 1 then
		if not tabs:IsA("ScrollingFrame") or tabs.ScrollingDirection ~= Enum.ScrollingDirection.X then
			problems[#problems + 1] = string.format(
				"the subtabs do not fit and the strip cannot scroll (%.0f > %.0f, window %dpx)",
				rightmost - tabsRect.x,
				tabsRect.w,
				width
			)
		end
	end
end

--- Toggles must sit on the right of their row and be vertically centred in it.
local function checkToggles(layout, root, width, problems)
	local count = 0
	for _, node in ipairs(root:GetDescendants()) do
		if isGui(node) and node.Name == "ToggleRow" then
			count += 1
			local track = node:FindFirstChild("Track", true)
			if not track or not isGui(track) then
				problems[#problems + 1] = "a toggle row has no Track: " .. describe(node)
			else
				local rowRect, trackRect = rectOf(layout, node), rectOf(layout, track)
				if rowRect and trackRect then
					local offset = (trackRect.y + trackRect.h / 2) - (rowRect.y + rowRect.h / 2)
					if math.abs(offset) > 1.5 then
						problems[#problems + 1] = string.format(
							"a toggle is %.1fpx off the vertical centre of its row (window %dpx): %s",
							offset, width, describe(node)
						)
					end
					if math.abs((trackRect.x + trackRect.w) - (rowRect.x + rowRect.w)) > 1.5 then
						problems[#problems + 1] = string.format(
							"a toggle is not flush right in its row (window %dpx, %.0fpx short): %s",
							width,
							(rowRect.x + rowRect.w) - (trackRect.x + trackRect.w),
							describe(node)
						)
					end
					local caption = byName(node, "Label")
					if overlapArea(rectOf(layout, caption), trackRect) > 0 then
						problems[#problems + 1] = "a toggle sits on top of its own label: " .. describe(node)
					end
				end
			end
		end
	end
	return count
end

--- Children of a horizontal UIListLayout must tile inside it.
---
--- Roblox lays those children out from their own Size, so a button left at
--- `UDim2.new(1, 0, ...)` claims the whole row and paints over its
--- neighbours. The engine hides this, so the gate has to look.
local function checkHorizontalRows(layout, gui, width, problems)
	for _, parent in ipairs(gui:GetDescendants()) do
		if isGui(parent) and parent.Visible ~= false then
			local horizontal = false
			for _, child in ipairs(parent:GetChildren()) do
				if child.ClassName == "UIListLayout" and child.Enabled ~= false then
					if child.FillDirection == Enum.FillDirection.Horizontal then
						horizontal = true
					end
				end
			end
			if horizontal then
				-- A ScrollingFrame is an explicit "this row scrolls" answer, and
				-- its canvas is SUPPOSED to be wider than the window.
				if parent:IsA("ScrollingFrame") then
					continue
				end
				local parentRect = rectOf(layout, parent)
				if parentRect then
					local right = parentRect.x + parentRect.w
					local previousRight = nil
					local previousName = nil
					for _, child in ipairs(parent:GetChildren()) do
						if isGui(child) and child.Visible ~= false and not isOverlay(child) then
							local r = rectOf(layout, child)
							if r then
								if r.x + r.w > right + 1 then
									problems[#problems + 1] = string.format(
										"%s runs %.0fpx past its horizontal row: %s (row ends at %.0f, window %dpx)",
										child:GetFullName(),
										r.x + r.w - right,
										parent:GetFullName(),
										right,
										width
									)
								end
								if previousRight and r.x < previousRight - 1 then
									problems[#problems + 1] = string.format(
										"%s overlaps %s inside their row (window %dpx)",
										child:GetFullName(), previousName, width
									)
								end
								previousRight = r.x + r.w
								previousName = child:GetFullName()
							end
						end
					end
				end
			end
		end
	end
end

--=============================================================================
-- OVERLAY / CLICK-BLOCKER CHECKS
--=============================================================================

--- Opens every dropdown in the page and checks each menu lands inside the
--- window. A menu parented to its own button is clipped by every ScrollingFrame
--- between it and the edge, which is exactly how the old one behaved.
local function checkDropdowns(layout, gui, view, width, problems)
	local opened = 0
	for _, node in ipairs(view:GetDescendants()) do
		if isGui(node) and node:IsA("TextButton") and node.Name == "Dropdown" then
			node.MouseButton1Click:Fire()
			local overlayHost = node:FindFirstChild("OverlayLayer", true)
			if overlayHost then
				for _, child in ipairs(overlayHost:GetChildren()) do
					if child:IsA("ScrollingFrame") and child.Name == "Menu" and child.Visible then
						local menuRect = rectOf(layout, child)
						if not menuRect then
							problems[#problems + 1] =
								"an open dropdown menu was not laid out: " .. child:GetFullName()
						elseif menuRect.x < 0 or menuRect.x + menuRect.w > width + 1 then
							problems[#problems + 1] = string.format(
								"an open dropdown menu escapes the window: %s (%.0f..%.0f of %dpx)",
								child:GetFullName(), menuRect.x, menuRect.x + menuRect.w, width
							)
						end
						opened += 1
					end
				end
			end
			node.MouseButton1Click:Fire()
		end
	end
	return opened
end

--- An invisible element that still swallows clicks is invisible to the user
--- and impossible to dismiss, so it is treated as a defect.
---
--- Only elements that are actually drawn are considered (the solver does not
--- measure a hidden branch), and only a transparent Active frame that covers a
--- real control AND paints above it counts — a decorative backdrop behind the
--- interface is not a blocker.
local function checkClickBlockers(layout, gui, problems)
	for _, node in ipairs(gui:GetDescendants()) do
		if isGui(node) and node.Visible ~= false and layout.isLaidOut(node) then
			local covers = node.AbsoluteSize.X >= 8 and node.AbsoluteSize.Y >= 8
			if
				covers
				and node.Active == true
				and node.BackgroundTransparency >= 1
				and not node:IsA("TextButton")
				and not node:IsA("TextBox")
				and (node.ZIndex or 1) < 40
				and not DECORATIVE[node.Name]
			then
				local frame = rectOf(layout, node)
				if frame then
					for _, target in ipairs(gui:GetDescendants()) do
						if
							isGui(target)
							and target.Visible ~= false
							and layout.isLaidOut(target)
							and (target:IsA("TextButton") or target:IsA("TextBox"))
							and target ~= node
							-- Roblox hit-tests deepest-first and hands input to the
							-- closest SELECTABLE ancestor, so neither a container's
							-- own descendants nor a non-selectable child of a
							-- control can take its clicks away.
							and not target:IsDescendantOf(node)
							and not node:IsDescendantOf(target)
							and (target.ZIndex or 1) <= (node.ZIndex or 1)
						then
							local targetRect = rectOf(layout, target)
							if targetRect then
								local inside = targetRect.x >= frame.x - 1
									and targetRect.y >= frame.y - 1
									and targetRect.x + targetRect.w <= frame.x + frame.w + 1
									and targetRect.y + targetRect.h <= frame.y + frame.h + 1
								if inside and (targetRect.w * targetRect.h) > 100 then
									problems[#problems + 1] = string.format(
										"an invisible %s covers the control %s and would swallow clicks",
										node:GetFullName(), target:GetFullName()
									)
									break
								end
							end
						end
					end
				end
			end
		end
	end
end

--- The Settings page must not paint outside its own frame.
local function checkPageContainment(layout, view, frameName, width, problems)
	local host = view:FindFirstChild(frameName, true)
	if not (isGui(host) and isGui(view)) then
		return
	end
	local hostRect = rectOf(layout, host)
	if not hostRect then
		return
	end
	for _, node in ipairs(host:GetDescendants()) do
		if isGui(node) and node.Visible ~= false and not isOverlay(node) then
			local r = rectOf(layout, node)
			if r and (r.x < hostRect.x - 1 or r.x + r.w > hostRect.x + hostRect.w + 1) then
				problems[#problems + 1] = string.format(
					"settings content escapes the page frame: %s (%.0f..%.0f of %.0f..%.0f, window %dpx)",
					node:GetFullName(), r.x, r.x + r.w, hostRect.x, hostRect.x + hostRect.w, width
				)
				break
			end
		end
	end
end

--=============================================================================
-- ENTRY
--=============================================================================

function LayoutSpec.run(options)
	local layout = options.layout
	local gui = options.gui
	local views = options.views
	local EventBus = require(script.Parent.Parent.Core.EventBus)

	local results = {}
	local function check(name, condition, message)
		results[#results + 1] = { name = name, ok = condition == true, message = message or "assertion failed" }
	end

	if not gui then
		check("the dock widget was created", false, "ApplicationController.getGui() returned nil")
		return { passed = 0, failed = 1, results = results, text = "no gui" }
	end

	-- The first-run welcome overlay is a modal on purpose; drop it so it cannot
	-- be mistaken for the main window's own geometry.
	local overlay = gui:FindFirstChild("WelcomeOverlay")
	if overlay then
		overlay:Destroy()
	end

	local root = byName(gui, "Root")
	check("the main window has a Root frame", root ~= nil, "the Root frame is missing")

	local total = 0
	local sections = options.sections
	if not sections then
		sections = SECTIONS
	end

	for _, height in ipairs(HEIGHTS) do
		for _, width in ipairs(WIDTHS) do
			local tag = string.format("%dx%d", width, height)

			for _, section in ipairs(sections) do
				EventBus.emit(EventBus.Events.Navigate, { section = section })
				layout.compute(gui, width, height)
				print(string.format("[LAYOUT] %s / %s done", tag, section))

				local problems, checked = sweep(layout, gui, width, height)
				total += checked
				local joined = table.concat(problems, "\n        ")
				if #problems == 0 then
					joined = string.format(
						"a generic sweep of %d laid-out elements found nothing",
						checked
					)
				end
				check(
					string.format("[%s/%s] no overlapping, clipped or out-of-window geometry", tag, section),
					#problems == 0,
					joined
				)

				if section == "settings" then
					local settingsProblems = {}
					checkSettings(layout, views and views.settings, width, settingsProblems)
					check(
						string.format("[%s] Settings subtabs tile and clear the content", tag),
						#settingsProblems == 0,
						table.concat(settingsProblems, "\n        ")
					)

					local toggleProblems = {}
					local toggles = root and checkToggles(layout, root, width, toggleProblems) or 0
					if toggles > 0 then
						check(
							string.format("[%s] %d toggles are right-aligned and vertically centred", tag, toggles),
							#toggleProblems == 0,
							table.concat(toggleProblems, "\n        ")
						)
					end
				end

				if section == "chat" then
					local shellProblems = {}
					checkShell(layout, gui, width, shellProblems)
					check(
						string.format("[%s] header, navigation and content never collide", tag),
						#shellProblems == 0,
						table.concat(shellProblems, "\n        ")
					)
				end

				-- Rows built with a horizontal UIListLayout tile from each child's
				-- own size, so a child sized too wide silently paints over its
				-- neighbours.
				local rowProblems = {}
				checkHorizontalRows(layout, gui, width, rowProblems)
				check(
					string.format("[%s] horizontal rows tile instead of overlapping", tag),
					#rowProblems == 0,
					table.concat(rowProblems, "\n        ")
				)

				-- Dropdowns must open inside the window at every width.
				local dropdownProblems = {}
				local menus = checkDropdowns(layout, gui, views and views[section], width, dropdownProblems)
				if menus > 0 then
					check(
						string.format("[%s] %d open dropdown menus stay inside the window", tag, menus),
						#dropdownProblems == 0,
						table.concat(dropdownProblems, "\n        ")
					)
				end

				-- Nothing invisible may intercept clicks.
				local blockerProblems = {}
				checkClickBlockers(layout, gui, blockerProblems)
				check(
					string.format("[%s] no invisible element swallows clicks", tag),
					#blockerProblems == 0,
					table.concat(blockerProblems, "\n        ")
				)

				if section == "settings" then
					local containment = {}
					checkPageContainment(layout, views.settings, "Page", width, containment)
					check(
						string.format("[%s] settings content stays inside the page frame", tag),
						#containment == 0,
						table.concat(containment, "\n        ")
					)
				end

				if options.dumpSize == tag and section == (options.dumpSection or "settings") then
					print(string.format("\n--- geometry dump @ %s / %s ---", tag, section))
					local function dump(node, depth)
						if isGui(node) and node.Visible ~= false then
							local r = layout.rectOf(node)
							if r then
								print(string.format(
									"%s%-42s %-14s x=%4.0f y=%5.0f w=%4.0f h=%5.0f z=%d",
									string.rep("  ", depth), node.Name, node.ClassName, r.x, r.y, r.w, r.h,
									node.ZIndex or 1
								))
							end
						end
						for _, child in ipairs(node:GetChildren()) do
							if isGui(child) then
								dump(child, depth + 1)
							end
						end
					end
					if root then
						dump(root, 0)
					end
				end
			end
		end
	end

	-- Restore the default section so the harness leaves the window as it found it.
	EventBus.emit(EventBus.Events.Navigate, { section = sections[1] })

	local passed, failed = 0, 0
	local lines = { "----- failures -----" }
	for _, entry in ipairs(results) do
		if entry.ok then
			passed += 1
		else
			failed += 1
			lines[#lines + 1] = string.format("FAIL  %s", entry.name)
			for line in string.gmatch(tostring(entry.message), "[^\n]+") do
				lines[#lines + 1] = string.format("        %s", line)
			end
		end
	end
	lines[#lines + 1] = "---------------------"

	return {
		passed = passed,
		failed = failed,
		results = results,
		elements = total,
		text = table.concat(lines, "\n"),
	}
end

return LayoutSpec
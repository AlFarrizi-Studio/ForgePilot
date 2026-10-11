local EventBus=module('Core/EventBus')
local Settings=module('Core/SettingsManager');Settings.init(pluginMock)
local Sessions=module('Core/SessionManager');Sessions.init(pluginMock)
local State=module('Core/StateManager')
local Theme=module('Utilities/Theme')
local Components=module('UI/Components')
local Agent=module('AI/AgentController')
for path in sources do
 if not path:find('Main.plugin',1,true) then
  local ok,err=pcall(module,path);check('load '..path,ok,err)
 end
end
local gui=module('UI/DockWidget').build(pluginMock)
local content=module('UI/DockWidget').content
local views={};local apis={}
for _,name in {'ChatView','BuilderView','HistoryView','ActivityLogs','SettingsView'} do
 local ok,frame,api=pcall(function()
  if name=='ChatView' then return module('UI/'..name).build(content,{onNavigate=function(section) EventBus.emit(EventBus.Events.Navigate,{section=section}) end}) end
  return module('UI/'..name).build(content)
 end)
 check('build '..name,ok,frame)
 if ok then views[name]=frame;apis[name]=api end
end
check('fixed controls honour zero grow ratio',Theme.flexItem(newInstance('Frame'),0,0).FlexMode==EnumMock.UIFlexMode.Custom)
local f=newInstance('Frame');Theme.flexItem(f,1,1);Theme.flexItem(f,0,0);check('resize reuses flex item',#f:GetChildren()==1 and f:FindFirstChildOfClass('UIFlexItem').GrowRatio==0)
local Renderer=module('UI/MessageRenderer')
check('rich text escapes angle brackets',Renderer.formatInline('<Part> & **bold**')=='&lt;Part&gt; &amp; <b>bold</b>')
check('inline code has no stray percent escape',Renderer.formatInline('`print(100%)`'):find('print(100%)',1,true)~=nil)
local frame,api=Renderer.render({id='stream',role='assistant',content='',streaming=true},{})
frame.Parent=content;api.appendDelta('Hello ');api.appendDelta('there.');advance(.04)
check('stream deltas update existing label',frame:FindFirstChild('Live',true).Text=='Hello there.')
check('message controller is separate from Instance',type(api)=='table' and type(api.appendDelta)=='function')
frame:Destroy();advance(.04)
local conv=Sessions.createConversation();local user=Sessions.addMessage('user','Original message')
local placeholder=Sessions.addMessage('assistant','',{streaming=true})
check('assistant placeholder preserves streaming flag',placeholder.streaming==true)
local events=0;local unsub=EventBus.on(EventBus.Events.MessageUpdated,function(payload) if payload.message.id==placeholder.id then events+=1 end end)
Sessions.updateMessage(placeholder.id,{streaming=false,content='Reply'})
check('completed message announces update',events==1);unsub()
local tool=Sessions.addMessage('tool','result',{toolCallId='call-123'})
check('tool results retain their call id',tool.toolCallId=='call-123')
local second=Sessions.createConversation();Sessions.appendToMessage(placeholder.id,' appended')
check('updates target owner even after changing active chat',placeholder.content=='Reply appended' and #second.messages==0)
State.reset();State.beginRun();State.transition('THINKING',{force=true});State.cancel()
check('cancel keeps request lock until completion',State.isBusy())
check('switching chat while request winds down is blocked',Sessions.setActive(conv.id)==false)
State.endRun();check('finishing request releases lock',not State.isBusy())
State.reset();Sessions.setActive(conv.id)
State.transition("THINKING",{force=true})
local resolved=nil
local subscription=EventBus.on(EventBus.Events.ApprovalRequested,function() taskMock.delay(.3,function() Agent.resolveApproval(true) end) end)
taskMock.spawn(function() resolved=Agent.awaitApproval('create_part',{},'approval-test') end)
check('approval waits before user response',resolved==nil)
advance(.35);check('approval accepts actual response',resolved==true);subscription()
State.reset();State.transition("THINKING",{force=true});resolved=nil
subscription=EventBus.on(EventBus.Events.ApprovalRequested,function() taskMock.delay(.1,function() State.cancel() end) end)
taskMock.spawn(function() resolved=Agent.awaitApproval('create_part',{},'cancel-test') end);advance(.2)
check('stop cancels approval without executing',resolved==false and State.get()=='CANCELLED');subscription()
State.reset()
local accepted=nil
local row,_,selected,setSelected=Components.dropdown('Protocol',{'Chat','Responses'},function(value) accepted=value end,{})
row.Parent=content;setSelected('Responses');check('programmatic dropdown selection stays in sync',selected()=='Responses' and row:FindFirstChild('Dropdown',true).Text=='Responses')
row:FindFirstChild('Dropdown',true).MouseButton1Click:Fire();check('dropdown opens',content:FindFirstChild('Menu',true).Visible)
Components.closeMenus();check('dropdown closes on navigation',not content:FindFirstChild('Menu',true).Visible);row:Destroy()
-- Chat accepts a real send, then streams and completes without rebuilding prior turns.
local registry=module('AI/UniversalProviderRegistry');local profile=registry.newProfile('custom');profile.modelId='mock-model';profile.authStyle='none';profile.displayName='Mock provider';profile.streaming=true;profile.toolCalling=false
Settings.addProvider(profile);Settings.setActiveProvider(profile.id)
local originalSend=Agent.sendTurn
Agent.sendTurn=function(_,_,_,callbacks)
 callbacks.onDelta('A clean ','text');taskMock.wait(.05);callbacks.onDelta('answer.','text')
 return {text='A clean answer.',reasoning='',toolCalls={},usage={inputTokens=10,outputTokens=4},durationMs=100,cancelled=false}
end
local chatAPI=apis.ChatView
if chatAPI then
 State.reset();Sessions.createConversation()
 chatAPI.input.setText('Hello');local send=views.ChatView:FindFirstChild('Send',true);send.MouseButton1Click:Fire();advance(.2)
 local current=Sessions.getActive()
 check('chat sends and stores both turns',#current.messages==2 and current.messages[1].content=='Hello' and current.messages[2].content=='A clean answer.')
 check('send clears draft only after acceptance',chatAPI.input.getText()=='')
 check('completion restores send control',views.ChatView:FindFirstChild('Send',true)~=nil and not State.isBusy())
 local userFrame=views.ChatView:FindFirstChild('Message_'..current.messages[1].id,true)
 local edit=userFrame:FindFirstChild('Action_Edit',true);edit.MouseButton1Click:Fire();chatAPI.input.setText('Edited hello');views.ChatView:FindFirstChild('Send',true).MouseButton1Click:Fire();advance(.2)
 check('editing replaces previous branch',#current.messages==2 and current.messages[1].content=='Edited hello')
 views.ChatView:FindFirstChild('Action_Regenerate',true).MouseButton1Click:Fire();advance(.2)
 check('regenerate replaces previous response',#current.messages==2 and current.messages[2].content=='A clean answer.')
 Settings.setActiveProvider(nil);chatAPI.input.setText('Keep this draft');views.ChatView:FindFirstChild('Send',true).MouseButton1Click:Fire();advance(.1)
 check('failed provider validation preserves draft',chatAPI.input.getText()=='Keep this draft')
end
Agent.sendTurn=originalSend
local health=module('Utilities/UIHealthCheck').run()
check('bundled UI checks pass without network',health.passed==health.total and health.total==8,table.concat(health.errors,'; '))
local inputCount=0
local keyboardFrame,keyboardAPI=module('UI/ChatInput').build({onSend=function() inputCount+=1;return true end,onStop=function() end,onPickFiles=function() end,onOpenSettings=function() end,onModeChange=function() end})
keyboardFrame.Parent=content
keyboardAPI.setText('Keyboard message');keyboardAPI.focus()
local keyboardBox=keyboardFrame:FindFirstChild('Input')
keyboardBox.InputBegan:Fire({KeyCode=EnumMock.KeyCode.Return})
gui.InputBegan:Fire({KeyCode=EnumMock.KeyCode.Return});advance(.02)
check('Enter sends once across box and plugin events',inputCount==1 and keyboardAPI.getText()=='')
keyboardAPI.setText('Two lines');keyboardAPI.focus()
gui.InputBegan:Fire({KeyCode=EnumMock.KeyCode.LeftShift});keyboardBox.InputBegan:Fire({KeyCode=EnumMock.KeyCode.Return});advance(.02)
check('Shift Enter inserts one new line and restores focus',inputCount==1 and keyboardBox:IsFocused() and keyboardAPI.getText()=='Two lines\n')
gui.InputEnded:Fire({KeyCode=EnumMock.KeyCode.LeftShift});keyboardAPI.destroy();keyboardFrame:Destroy()
local questionManager=module('AI/QuestionManager');local questionReturned=false
State.reset();State.transition('THINKING',{force=true})
taskMock.spawn(function() questionManager.ask({taskId='question-stop',prompt='Choose a style'});questionReturned=true end)
advance(.05);State.cancel();advance(.15)
check('Stop releases a pending question',questionReturned and questionManager.getPending()==nil)
State.reset();Settings.setActiveProvider(profile.id)
local exceptionConversation=Sessions.createConversation();Sessions.addMessage('user','Trigger a failure')
Agent.sendTurn=function() error('Mock transport failure') end
local exceptionResult=Agent.runTask({userText='Trigger a failure',mode='plan',conversation=exceptionConversation})
check('unexpected errors release request lock',not exceptionResult.ok and not State.isBusy() and State.get()=='FAILED')
check('unexpected errors finalize assistant placeholder',exceptionConversation.messages[2].streaming==false and exceptionConversation.messages[2].error~=nil)
State.reset();profile.toolCalling=true
local detector=module('AI/ModelCapabilityDetector');detector.setOverride(profile.id,profile.modelId,'tool_calling','supported')
local multiConversation=Sessions.createConversation();Sessions.addMessage('user','Inspect then answer')
local originalExecute=Agent.executeTool;local turnCount=0;local nativePair=false
Agent.executeTool=function(name,arguments)
 return {toolName=name,arguments=arguments,ok=false,verified=false,message='Mock tool failed',durationMs=1}
end
Agent.sendTurn=function(_,spec,_,callbacks)
 turnCount+=1
 if turnCount==1 then
  return {text='Checking the project.',reasoning='',toolCalls={{id='call-round-one',name='inspect_workspace',arguments={}}},durationMs=1,cancelled=false}
 end
 for _,message in spec.messages do if message.role=='tool' and message.toolCallId=='call-round-one' then nativePair=true end end
 callbacks.onDelta('The inspection failed.','text')
 return {text='The inspection failed.',reasoning='',toolCalls={},durationMs=1,cancelled=false}
end
local multiResult=Agent.runTask({userText='Inspect then answer',mode='plan',conversation=multiConversation})
check('each tool round owns a separate assistant message',multiResult.ok and #multiConversation.messages==4 and multiConversation.messages[2].content=='Checking the project.' and multiConversation.messages[4].content=='The inspection failed.',jsonEncode({result=multiResult,messages=multiConversation.messages}))
check('native followup request retains tool call id',nativePair and multiConversation.messages[3].toolCallId=='call-round-one')
check('failed tool result stays failed',multiConversation.messages[2].toolCalls and multiConversation.messages[2].toolCalls[1].state=='failed')
Agent.executeTool=originalExecute;Agent.sendTurn=originalSend;profile.toolCalling=false;detector.clearOverrides(profile.id,profile.modelId)
State.reset();local internalConversation=Sessions.createConversation();Sessions.addMessage('user','Continue');Sessions.addMessage('tool','Structured result')
local structuredResult=false
Agent.sendTurn=function(_,spec)
 for _,message in spec.messages do if message.content=='Tool result:\nStructured result' then structuredResult=message.role=='user' end end
 return {text='Done.',reasoning='',toolCalls={},durationMs=1,cancelled=false}
end
Agent.runTask({userText='Continue',mode='plan',conversation=internalConversation})
check('structured action results avoid native tool protocol',structuredResult)
Sessions.recordUsage(internalConversation.id,{inputTokens=10,outputTokens=7,reasoningTokens=3})
Sessions.recordUsage(internalConversation.id,nil)
local tokenTotals=Sessions.getTotals()
check('token accounting tolerates missing usage and avoids double counting',tokenTotals.input==10 and tokenTotals.output==7 and tokenTotals.reasoning==3 and tokenTotals.total==17)
Sessions.addMessage('assistant','A cancelled tool request',{toolCalls={{id='unanswered-call',name='inspect_workspace',arguments={}}}})
local unmatchedOmitted=false
Agent.sendTurn=function(_,spec)
 unmatchedOmitted=true
 for _,message in spec.messages do for _,call in (message.toolCalls or {}) do if call.id=='unanswered-call' then unmatchedOmitted=false end end end
 return {text='A new answer.',reasoning='',toolCalls={},durationMs=1,cancelled=false}
end
Agent.runTask({userText='Continue after Stop',mode='plan',conversation=internalConversation})
check('cancelled native call does not break the next request',unmatchedOmitted)
Agent.sendTurn=originalSend;State.reset()
Sessions.setConversationMeta(internalConversation.id,{mode='build'})
check('chat and builder modes stay synchronized',views.ChatView:FindFirstChild('Mode',true).Text=='Build' and apis.BuilderView.getMode()=='build')
EventBus.emit(EventBus.Events.Navigate,{section='settings',tab='Data'})
State.beginRun();local before=#internalConversation.messages
views.SettingsView:FindFirstChild('Clearcontext',true).MouseButton1Click:Fire()
check('data reset is blocked while a request is active',#internalConversation.messages==before);State.endRun()
-- Geometry approximation for regression checks; this is not the Studio renderer.
local rectangles={}
local function axis(dim,available) return dim.Scale*available+dim.Offset end
local function paddingOf(node,w,h)
 local p=node:FindFirstChildOfClass('UIPadding')
 if not p then return 0,0,0,0 end
 return axis(p.PaddingLeft,w),axis(p.PaddingRight,w),axis(p.PaddingTop,h),axis(p.PaddingBottom,h)
end
local function visibleChildren(node)
 local children={};for _,child in node:GetChildren() do if child:IsA('GuiObject') and child.Visible then children[#children+1]=child end end
 table.sort(children,function(a,b) return a.LayoutOrder<b.LayoutOrder end);return children
end
local function autoX(node) return node.AutomaticSize==EnumMock.AutomaticSize.X or node.AutomaticSize==EnumMock.AutomaticSize.XY end
local function autoY(node) return node.AutomaticSize==EnumMock.AutomaticSize.Y or node.AutomaticSize==EnumMock.AutomaticSize.XY end
local measure
measure=function(node,pw,ph,depth)
 depth=depth or 0;assert(depth<60,'recursive geometry')
 local w=math.max(0,axis(node.Size.X,pw));local h=math.max(0,axis(node.Size.Y,ph))
 local l,r,t,b=paddingOf(node,w,h)
 if node:IsA('TextLabel') or node:IsA('TextButton') or node:IsA('TextBox') then
  local plain=if node.RichText then node.Text:gsub('<[^>]*>',''):gsub('&lt;','<'):gsub('&gt;','>'):gsub('&amp;','&') else node.Text
  local bounds=methods.GetTextSize(nil,plain,node.TextSize,node.Font,vector(if node.TextWrapped then math.max(1,w-l-r) else 1000000,1000000))
  if autoX(node) then w=math.max(w,bounds.X+l+r) end
  if autoY(node) then h=math.max(h,bounds.Y+t+b) end
 elseif autoY(node) then
  local list=node:FindFirstChildOfClass('UIListLayout');local grid=node:FindFirstChildOfClass('UIGridLayout')
  local children=visibleChildren(node);local extent=0
  if list then
   local horizontal=list.FillDirection==EnumMock.FillDirection.Horizontal
   for index,child in children do
    local _,ch=measure(child,w-l-r,0,depth+1)
    if horizontal then extent=math.max(extent,ch) else extent+=ch+(if index>1 then list.Padding.Offset else 0) end
   end
  elseif grid then
   local columns=math.max(1,grid.FillDirectionMaxCells);local rows=math.ceil(#children/columns)
   extent=rows*grid.CellSize.Y.Offset+math.max(0,rows-1)*grid.CellPadding.Y.Offset
  else
   for _,child in children do local _,ch=measure(child,w-l-r,0,depth+1);extent=math.max(extent,child.Position.Y.Offset+ch) end
  end
  h=math.max(h,extent+t+b)
 end
 local constraint=node:FindFirstChildOfClass('UISizeConstraint')
 if constraint then w=math.clamp(w,constraint.MinSize.X,constraint.MaxSize.X);h=math.clamp(h,constraint.MinSize.Y,constraint.MaxSize.Y) end
 return w,h
end
local function arrange(node,w,h,x,y,depth)
 depth=depth or 0
 rectangles[node]={x=x,y=y,w=w,h=h}
 node._props.AbsoluteSize=vector(w,h);node._props.AbsolutePosition=vector(x,y)
 local l,r,t,b=paddingOf(node,w,h);local iw=math.max(0,w-l-r);local ih=math.max(0,h-t-b)
 local list=node:FindFirstChildOfClass('UIListLayout');local grid=node:FindFirstChildOfClass('UIGridLayout');local children=visibleChildren(node)
 local extentW,extentH=0,0
 if list then
  local horizontal=list.FillDirection==EnumMock.FillDirection.Horizontal
  local available=if horizontal then iw else ih
  local entries={};local total=math.max(0,#children-1)*list.Padding.Offset;local grows=0;local shrinks=0
  for _,child in children do
   local cw,ch=measure(child,iw,ih)
   local basis=if horizontal then cw else ch;local flex=child:FindFirstChildOfClass('UIFlexItem')
   local grow,shrink=0,0
   if flex then
    if flex.FlexMode==EnumMock.UIFlexMode.Custom then grow=flex.GrowRatio;shrink=flex.ShrinkRatio
    elseif flex.FlexMode==EnumMock.UIFlexMode.Fill then grow=1;shrink=1 end
   end
   entries[#entries+1]={child=child,w=cw,h=ch,basis=basis,grow=grow,shrink=shrink}
   total+=basis;grows+=grow;shrinks+=shrink*basis
  end
  local spare=available-total
  for _,entry in entries do
   local amount=if spare>=0 and grows>0 then spare*entry.grow/grows elseif spare<0 and shrinks>0 then spare*entry.shrink*entry.basis/shrinks else 0
   if horizontal then entry.w=math.max(0,entry.w+amount) else entry.h=math.max(0,entry.h+amount) end
  end
  local offset=0
  local mainTotal=math.max(0,#entries-1)*list.Padding.Offset
  for _,entry in entries do mainTotal+=if horizontal then entry.w else entry.h end
  local alignment=if horizontal then list.HorizontalAlignment.Name else list.VerticalAlignment.Name
  if alignment=='Center' then offset=math.max(0,(available-mainTotal)/2) elseif alignment=='Right' or alignment=='Bottom' then offset=math.max(0,available-mainTotal) end
  for _,entry in entries do
   local cross=0;local crossAlignment=if horizontal then list.VerticalAlignment.Name else list.HorizontalAlignment.Name
   local crossAvailable=if horizontal then ih else iw;local crossSize=if horizontal then entry.h else entry.w
   if crossAlignment=='Center' then cross=math.max(0,(crossAvailable-crossSize)/2) elseif crossAlignment=='Bottom' or crossAlignment=='Right' then cross=math.max(0,crossAvailable-crossSize) end
   local cx=x+l+(if horizontal then offset else cross);local cy=y+t+(if horizontal then cross else offset)
   if node:IsA('ScrollingFrame') then cx-=node.CanvasPosition.X;cy-=node.CanvasPosition.Y end
   arrange(entry.child,entry.w,entry.h,cx,cy,depth+1)
   if horizontal then offset+=entry.w+list.Padding.Offset else offset+=entry.h+list.Padding.Offset end
   extentW=math.max(extentW,cx-x+entry.w+(if node:IsA('ScrollingFrame') then node.CanvasPosition.X else 0)+r)
   extentH=math.max(extentH,cy-y+entry.h+(if node:IsA('ScrollingFrame') then node.CanvasPosition.Y else 0)+b)
  end
  list._props.AbsoluteContentSize=vector(if horizontal then mainTotal else iw,if horizontal then ih else mainTotal)
 elseif grid then
  local cw=axis(grid.CellSize.X,iw);local ch=axis(grid.CellSize.Y,ih);local gx=axis(grid.CellPadding.X,iw);local gy=axis(grid.CellPadding.Y,ih)
  local columns=if grid.FillDirectionMaxCells>0 then grid.FillDirectionMaxCells else math.max(1,math.floor((iw+gx)/(cw+gx)))
  for index,child in children do local col=(index-1)%columns;local row=math.floor((index-1)/columns);arrange(child,cw,ch,x+l+col*(cw+gx),y+t+row*(ch+gy),depth+1);extentH=math.max(extentH,t+(row+1)*ch+row*gy+b) end
  extentW=iw;grid._props.AbsoluteContentSize=vector(extentW,extentH)
 else
  for _,child in children do
   local cw,ch=measure(child,iw,ih)
   local cx=x+l+axis(child.Position.X,iw)-child.AnchorPoint.X*cw
   local cy=y+t+axis(child.Position.Y,ih)-child.AnchorPoint.Y*ch
   if node:IsA('ScrollingFrame') then cx-=node.CanvasPosition.X;cy-=node.CanvasPosition.Y end
   arrange(child,cw,ch,cx,cy,depth+1)
   extentW=math.max(extentW,cx-x+cw+r);extentH=math.max(extentH,cy-y+ch+b)
  end
 end
 if node:IsA('ScrollingFrame') then
  local canvasW=axis(node.CanvasSize.X,w);local canvasH=axis(node.CanvasSize.Y,h)
  if node.AutomaticCanvasSize==EnumMock.AutomaticSize.Y or node.AutomaticCanvasSize==EnumMock.AutomaticSize.XY then canvasH=math.max(canvasH,extentH) end
  if node.AutomaticCanvasSize==EnumMock.AutomaticSize.X or node.AutomaticCanvasSize==EnumMock.AutomaticSize.XY then canvasW=math.max(canvasW,extentW) end
  node._props.AbsoluteCanvasSize=vector(canvasW,canvasH);node._props.AbsoluteWindowSize=vector(w,h)
 end
end
local function compute(w,h)
 for _=1,3 do
  rectangles={}
  local root=gui:FindFirstChild('Root');arrange(root,w,h,0,0)
  for node in rectangles do if node._signals.AbsoluteSize then node._signals.AbsoluteSize:Fire() end end
 end
 rectangles={};arrange(gui:FindFirstChild('Root'),w,h,0,0)
end
local function rect(node) return rectangles[node] end
for name,view in views do view.Visible=name=='ChatView' end
Settings.setActiveProvider(profile.id);State.reset();Sessions.createConversation()
module('UI/DockWidget').navigate('chat');chatAPI.input.setText('')
Sessions.addMessage('user','Help me make a clean welcome screen.')
Sessions.addMessage('assistant','Absolutely. Here is a simple plan:\n\n## Welcome screen\n- A clear title and one primary button\n- Comfortable spacing and a purple accent\n- A short fade when the player joins\n\n```lua\nlocal TweenService = game:GetService("TweenService")\n-- Keep animations short and subtle.\n```',{model='mock-model',elapsedMs=1200})
for _,width in {300,320,380,440,560,760} do
 for _,height in {400,560,740} do
  compute(width,height)
  local chat=views.ChatView
  local composer=rect(chat:FindFirstChild('Composer',true));local transcript=rect(chat:FindFirstChild('Transcript',true));local nav=rect(gui:FindFirstChild('Nav',true));local contentRect=rect(content)
  check(string.format('chat geometry %dx%d',width,height),composer and transcript and composer.y>=transcript.y+transcript.h-1 and composer.y+composer.h<=contentRect.y+contentRect.h+1 and transcript.h>=40)
  local good=true
  for _,section in module('UI/DockWidget').SectionOrder do local r=rect(gui:FindFirstChild('Tab_'..section,true));good=good and r~=nil and r.w>20 and r.x+r.w<=width+1 end
  check(string.format('navigation visible %dx%d',width,height),good)
 end
end
local function allInside(row)
 local r=rect(row);if not r then return false end
 for _,child in visibleChildren(row) do
  local c=rect(child)
  if not c or c.w<=0 or c.x<r.x-1 or c.x+c.w>r.x+r.w+1 or c.y+c.h>r.y+r.h+1 then return false end
 end
 return true
end
for name,view in views do
 for other,otherView in views do otherView.Visible=other==name end
 if name=='SettingsView' then
  for _,tab in {'General','AI & Provider','Agent Access','Agent','Retry','Data'} do
   EventBus.emit(EventBus.Events.Navigate,{section='settings',tab=tab})
   for _,width in {300,440,760} do
    compute(width,560)
    local valid=rect(view) and rect(view).w>0
    for node in rectangles do if node.Name=='ButtonRow' then valid=valid and allInside(node) end end
    check('settings controls fit '..tab..' '..width,valid)
   end
  end
 else
  for _,width in {300,440,760} do
   compute(width,560)
   local good=rect(view) and rect(view).w>0 and rect(view).h>0
   for node,r in rectangles do good=good and r.x==r.x and r.y==r.y and r.w==r.w and r.h==r.h end
   check('page geometry '..name..' '..width,good)
  end
 end
end
for name,view in views do view.Visible=name=='ChatView' end
module('UI/DockWidget').navigate('chat')
compute(440,740)
-- Emit an exact geometry snapshot for local visual QA of this approximation.
local snapshot={width=440,height=740,items={}}
local function export(node,visible,clip)
 if node:IsA('GuiObject') then
  visible=visible and node.Visible
  if visible and rectangles[node] then
   local r=rectangles[node];local p=node._props
   local item={name=node.Name,class=node.ClassName,x=r.x,y=r.y,w=r.w,h=r.h,background=p.BackgroundColor3 and p.BackgroundColor3:ToHex() or nil,alpha=p.BackgroundTransparency,text=p.Text,textTransparency=p.TextTransparency,fontSize=p.TextSize,textColor=p.TextColor3 and p.TextColor3:ToHex() or nil,align=p.TextXAlignment and p.TextXAlignment.Name,vertical=p.TextYAlignment and p.TextYAlignment.Name,wrap=p.TextWrapped,rich=p.RichText,clip=clip,radius=node:FindFirstChildOfClass('UICorner') and node:FindFirstChildOfClass('UICorner').CornerRadius.Offset or nil}
   snapshot.items[#snapshot.items+1]=item
   local left,right,top,bottom=paddingOf(node,r.w,r.h)
   item.padding={left=left,right=right,top=top,bottom=bottom}
   item.placeholder=p.PlaceholderText
   item.rotation=p.Rotation
   item.font=p.Font and p.Font.Name or nil
   local stroke=node:FindFirstChildOfClass('UIStroke')
   if stroke then item.stroke=stroke.Color:ToHex();item.strokeAlpha=stroke.Transparency;item.strokeWidth=stroke.Thickness end
   if node.ClipsDescendants or node:IsA('ScrollingFrame') then clip={x=r.x,y=r.y,w=r.w,h=r.h} end
  end
 end
 for _,child in node:GetChildren() do export(child,visible,clip) end
end
local overlay=content:FindFirstChild('OverlayLayer');overlay.Visible=false
export(gui:FindFirstChild('Root'),true,nil)
print('LAYOUT_SNAPSHOT '..jsonEncode(snapshot))

local controller=module('Core/ApplicationController')
local report=controller.init(pluginMock)
check('application startup reports success',report.ok)
for _,stage in report.stages do check('application stage '..stage.stage..' '..stage.modulePath,stage.ok,stage.cause) end
controller.destroy()
check('application teardown clears GUI',controller.getGui()==nil)
print('RUNTIME RESULT '..#failures..' failures')
if #failures>0 then for _,failure in failures do print(failure) end;error('Runtime tests failed') end

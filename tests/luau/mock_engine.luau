local now = 0
local failures = {}
local realTypeof = typeof
local function check(name, condition, detail)
 if not condition then failures[#failures+1]=name..': '..tostring(detail or '') end
 print((if condition then 'PASS ' else 'FAIL ')..name)
end
local function warnMock(...) local t={...}; for i,v in t do t[i]=tostring(v) end; print('WARN '..table.concat(t,' ')) end
local function enumValue(kind,name,value)
 return setmetatable({Name=name,Value=value,EnumType=kind,_type='EnumItem'}, {__tostring=function() return 'Enum.'..kind..'.'..name end})
end
local EnumMock={}
for kind,list in enums do
 local values={}; for name,value in list do values[name]=enumValue(kind,name,value) end
 EnumMock[kind]=setmetatable(values,{__index=function(_,key) error('Invalid enum '..kind..'.'..tostring(key)) end})
end
local function vector(x,y,z,kind)
 local t={X=x or 0,Y=y or 0,_type=kind or 'Vector2'}; if z~=nil then t.Z=z end
 return setmetatable(t,{
  __index=function(self,key)
   if key=='Magnitude' then return math.sqrt(self.X^2+self.Y^2+(self.Z or 0)^2) end
   if key=='Lerp' then return function(a,b,f) return vector(a.X+(b.X-a.X)*f,a.Y+(b.Y-a.Y)*f,if a.Z then a.Z+(b.Z-a.Z)*f else nil,a._type) end end
  end,
  __add=function(a,b) return vector(a.X+b.X,a.Y+b.Y,if a.Z then a.Z+b.Z else nil,a._type) end,
  __sub=function(a,b) return vector(a.X-b.X,a.Y-b.Y,if a.Z then a.Z-b.Z else nil,a._type) end,
  __mul=function(a,b) if type(a)=='number' then a,b=b,a end; return vector(a.X*b,a.Y*b,if a.Z then a.Z*b else nil,a._type) end,
  __tostring=function(a) return string.format('%s,%s,%s',a.X,a.Y,a.Z or '') end,
 })
end
local Vector2Mock={new=function(x,y) return vector(x,y) end,zero=vector(0,0)}
local Vector3Mock={new=function(x,y,z) return vector(x,y,z or 0,'Vector3') end,zero=vector(0,0,0,'Vector3'),one=vector(1,1,1,'Vector3')}
local function udim(scale,offset) return {Scale=scale or 0,Offset=offset or 0,_type='UDim'} end
local UDimMock={new=udim}
local function udim2(xs,xo,ys,yo) return {X=udim(xs,xo),Y=udim(ys,yo),_type='UDim2'} end
local UDim2Mock={new=udim2,fromOffset=function(x,y) return udim2(0,x,0,y) end,fromScale=function(x,y) return udim2(x,0,y,0) end}
local function color(r,g,b)
 return setmetatable({R=r,G=g,B=b,_type='Color3'},{__index={Lerp=function(a,c,f) return color(a.R+(c.R-a.R)*f,a.G+(c.G-a.G)*f,a.B+(c.B-a.B)*f) end,ToHex=function(a) return string.format('%02x%02x%02x',math.floor(a.R*255+.5),math.floor(a.G*255+.5),math.floor(a.B*255+.5)) end}})
end
local Color3Mock={new=color,fromRGB=function(r,g,b) return color(r/255,g/255,b/255) end,fromHex=function(s) s=s:gsub('#',''); return color(tonumber(s:sub(1,2),16)/255,tonumber(s:sub(3,4),16)/255,tonumber(s:sub(5,6),16)/255) end}
local function signal()
 local callbacks={}
 local result={_type='RBXScriptSignal'}
 function result:Connect(fn)
  local conn={Connected=true,_type='RBXScriptConnection'}
  function conn:Disconnect() self.Connected=false end
  function conn:Once() return conn end
  callbacks[#callbacks+1]={connection=conn,callback=fn}; return conn
 end
 function result:Once(fn) local c; c=self:Connect(function(...) c:Disconnect();fn(...) end);return c end
 function result:Fire(...)
  local entries=table.clone(callbacks)
  for _,entry in entries do if entry.connection.Connected then entry.callback(...) end end
 end
 function result:Wait() return coroutine.yield(0.001) end
 return result
end
local scheduled={}
local taskMock={}
local function schedule(fn,at,args)
 local co=if type(fn)=='thread' then fn else coroutine.create(fn)
 scheduled[#scheduled+1]={co=co,at=at,args=args or {}};return co
end
function taskMock.spawn(fn,...) local co=if type(fn)=='thread' then fn else coroutine.create(fn);local ok,delay=coroutine.resume(co,...);if not ok then error(delay) end;if coroutine.status(co)~='dead' then scheduled[#scheduled+1]={co=co,at=now+(tonumber(delay) or 0),args={}} end;return co end
function taskMock.defer(fn,...) return schedule(fn,now,{...}) end
function taskMock.delay(delay,fn,...) return schedule(fn,now+delay,{...}) end
function taskMock.wait(delay) return coroutine.yield(delay or 0.016) end
function taskMock.cancel(co) for i=#scheduled,1,-1 do if scheduled[i].co==co then table.remove(scheduled,i) end end end
local function advance(duration)
 local untilTime=now+duration;local rounds=0
 while true do
  local at=math.huge;local selected=nil
  for index,entry in scheduled do if entry.at<at then at=entry.at;selected=index end end
  if not selected or at>untilTime then break end
  rounds+=1;assert(rounds<100000,'scheduler did not settle');now=at
  local item=table.remove(scheduled,selected)
  local ok,delay=coroutine.resume(item.co,table.unpack(item.args));if not ok then error(delay) end
  if coroutine.status(item.co)~='dead' then scheduled[#scheduled+1]={co=item.co,at=now+math.max(.001,tonumber(delay) or .016),args={}} end
 end
 now=untilTime
end
local function member(class,key)
 local meta=classes[class];if not meta then return nil end
 return meta.members[key] or (meta.super~='<<<ROOT>>>' and member(meta.super,key))
end
local function isa(class,target)
 if class==target then return true end
 local def=classes[class];return def~=nil and def.super~='<<<ROOT>>>' and isa(def.super,target)
end
local methods={};local allInstances={};local nextInstanceId=0
local newInstance
local instanceMeta={}
function instanceMeta.__index(self,key)
 if key:sub(1,1)=="_" then return rawget(self,key) end
 if key=='ClassName' then return self._class end
 if key=='Parent' then return self._parent end
 local value=self._props[key];if value~=nil then return value end
 if methods[key] and member(self._class,key)=='Function' then return methods[key] end
 local kind=member(self._class,key)
 if kind=='Event' then local event=signal();self._props[key]=event;return event end
 if kind=='Function' then error('Unimplemented method '..self._class..'.'..key) end
 if kind=='Property' then return nil end
 for _,child in self._children do if child.Name==key then return child end end
 error(key..' is not a valid member of '..self._class..' '..tostring(self.Name))
end
function instanceMeta.__newindex(self,key,value)
 if key:sub(1,1)=='_' then rawset(self,key,value);return end
 assert(member(self._class,key)=='Property',key..' is not a valid writable member of '..self._class)
 if key=='Parent' then
  if self._parent then local index=table.find(self._parent._children,self);if index then table.remove(self._parent._children,index) end end
  self._parent=value
  if value then
   value._children[#value._children+1]=self
   value.ChildAdded:Fire(self)
   local cursor=value
   while cursor do cursor.DescendantAdded:Fire(self);cursor=cursor.Parent end
  end
  self.AncestryChanged:Fire(self,value)
 else
  local old=self._props[key];self._props[key]=value
  if old~=value and self._signals[key] then self._signals[key]:Fire() end
 end
end
function instanceMeta.__tostring(self) return self._props.Name or self._class end
function newInstance(class)
 assert(classes[class],'Unknown class '..class)
 local instance=setmetatable({_class=class,_children={},_props={Name=class},_signals={},_attributes={}},instanceMeta)
 if isa(class,'GuiObject') then
  local p=instance._props
  p.Size=udim2(0,100,0,100);p.Position=udim2();p.AnchorPoint=vector(0,0);p.Visible=true;p.Active=false;p.Selectable=false;p.Interactable=true;p.Rotation=0
  p.BackgroundTransparency=0;p.BackgroundColor3=color(.7,.7,.7);p.BorderSizePixel=1;p.ClipsDescendants=false;p.ZIndex=1;p.LayoutOrder=0;p.AutomaticSize=EnumMock.AutomaticSize.None
  p.AbsoluteSize=vector(400,600);p.AbsolutePosition=vector(0,0)
 end
 if isa(class,'TextLabel') or isa(class,'TextButton') or isa(class,'TextBox') then
  local p=instance._props;p.Text='';p.TextSize=14;p.Font=EnumMock.Font.Gotham;p.TextColor3=color(1,1,1);p.TextTransparency=0;p.TextWrapped=false;p.RichText=false;p.TextTruncate=EnumMock.TextTruncate.None;p.TextXAlignment=EnumMock.TextXAlignment.Center;p.TextYAlignment=EnumMock.TextYAlignment.Center;p.TextBounds=vector(0,16)
 end
 if class=='TextBox' then instance._props.CursorPosition=-1;instance._props.SelectionStart=-1 end
 if class=='ScrollingFrame' then
  local p=instance._props;p.CanvasSize=udim2();p.CanvasPosition=vector(0,0);p.AbsoluteCanvasSize=vector(400,600);p.AbsoluteWindowSize=vector(400,600);p.AutomaticCanvasSize=EnumMock.AutomaticSize.None;p.ScrollingDirection=EnumMock.ScrollingDirection.Y;p.ScrollBarThickness=5
 end
 if class=='UIListLayout' then
  local p=instance._props;p.FillDirection=EnumMock.FillDirection.Vertical;p.Padding=udim();p.SortOrder=EnumMock.SortOrder.LayoutOrder;p.HorizontalAlignment=EnumMock.HorizontalAlignment.Left;p.VerticalAlignment=EnumMock.VerticalAlignment.Top;p.HorizontalFlex=EnumMock.UIFlexAlignment.None;p.VerticalFlex=EnumMock.UIFlexAlignment.None;p.Wraps=false;p.AbsoluteContentSize=vector(0,0)
 end
 if class=='UIFlexItem' then instance._props.GrowRatio=1;instance._props.ShrinkRatio=1;instance._props.FlexMode=EnumMock.UIFlexMode.None end
 if class=='UISizeConstraint' then instance._props.MinSize=vector(0,0);instance._props.MaxSize=vector(1000000,1000000) end
 if class=='UIPadding' then for _,key in {'PaddingLeft','PaddingRight','PaddingTop','PaddingBottom'} do instance._props[key]=udim() end end
 if class=='UIGridLayout' then local p=instance._props;p.CellSize=udim2(0,100,0,100);p.CellPadding=udim2(0,5,0,5);p.FillDirectionMaxCells=0;p.FillDirection=EnumMock.FillDirection.Horizontal;p.SortOrder=EnumMock.SortOrder.LayoutOrder;p.AbsoluteContentSize=vector(0,0) end
 nextInstanceId+=1;instance._mockId=nextInstanceId;allInstances[nextInstanceId]=instance;return instance
end
function methods:IsA(target) return isa(self._class,target) end
function methods:GetChildren() return table.clone(self._children) end
function methods:GetTags() return table.clone(self._tags or {}) end
function methods:AddTag(tag) self._tags=self._tags or {};if not table.find(self._tags,tag) then self._tags[#self._tags+1]=tag end end
function methods:GetDescendants() local list={};local function walk(node) for _,child in node._children do list[#list+1]=child;walk(child) end end;walk(self);return list end
function methods:FindFirstChild(name,recursive) for _,child in self._children do if child.Name==name then return child end end;if recursive then for _,child in self._children do local found=methods.FindFirstChild(child,name,true);if found then return found end end end;return nil end
function methods:WaitForChild(name) return methods.FindFirstChild(self,name) end
function methods:FindFirstChildOfClass(class) for _,child in self._children do if child.ClassName==class then return child end end;return nil end
function methods:FindFirstChildWhichIsA(class) for _,child in self._children do if child:IsA(class) then return child end end;return nil end
function methods:FindFirstAncestorOfClass(class) local p=self.Parent;while p do if p.ClassName==class then return p end;p=p.Parent end;return nil end
function methods:FindFirstAncestorWhichIsA(class) local p=self.Parent;while p do if p:IsA(class) then return p end;p=p.Parent end;return nil end
function methods:IsDescendantOf(target) local p=self.Parent;while p do if p==target then return true end;p=p.Parent end;return false end
function methods:GetFullName() return if self.Parent then self.Parent:GetFullName()..'.'..self.Name else self.Name end
function methods:GetPropertyChangedSignal(key) assert(member(self._class,key)=='Property','Invalid property '..key);self._signals[key]=self._signals[key] or signal();return self._signals[key] end
function methods:GetAttribute(name) return self._attributes[name] end
function methods:SetAttribute(name,value) self._attributes[name]=value end
function methods:GetAttributes() return table.clone(self._attributes) end
function methods:Destroy() if self._destroyed then return end;self.Destroying:Fire();for _,child in table.clone(self._children) do child:Destroy() end;self.Parent=nil;self._destroyed=true;allInstances[self._mockId]=nil end
function methods:ClearAllChildren() for _,child in table.clone(self._children) do child:Destroy() end end
function methods:CaptureFocus() self._focused=true;self.Focused:Fire() end
function methods:IsFocused() return self._focused==true end
function methods:ReleaseFocus(submitted) self._focused=false;self.FocusLost:Fire(submitted==true) end
local function jsonEncode(value)
 local function quote(v) return '"'..v:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t')..'"' end
 local function encode(v)
  if v==nil then return 'null' end
  if type(v)=='string' then return quote(v) end
  if type(v)=='number' or type(v)=='boolean' then return tostring(v) end
  assert(type(v)=='table','Cannot JSON encode '..type(v))
  local entries={};local array=#v>0;local keys={};for k in v do keys[#keys+1]=k;if type(k)~='number' then array=false end end
  if array then for _,x in v do entries[#entries+1]=encode(x) end;return '['..table.concat(entries,',')..']' end
  table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
  for _,k in keys do entries[#entries+1]=quote(tostring(k))..':'..encode(v[k]) end
  return '{'..table.concat(entries,',')..'}'
 end
 return encode(value)
end
local function jsonDecode(text)
 local position=1
 local function ws() local _,last=text:find('^%s*',position);position=(last or position-1)+1 end
 local parse
 local function stringValue()
  assert(text:sub(position,position)=='"');position+=1;local parts={}
  while position<=#text do local ch=text:sub(position,position);position+=1;if ch=='"' then return table.concat(parts) end
   if ch=='\\' then local esc=text:sub(position,position);position+=1;ch=({n='\n',r='\r',t='\t',b='\b',f='\f'})[esc] or esc;if esc=='u' then ch=utf8.char(tonumber(text:sub(position,position+3),16));position+=4 end end
   parts[#parts+1]=ch
  end;error('Unclosed JSON string')
 end
 parse=function()
  ws();local ch=text:sub(position,position)
  if ch=='"' then return stringValue() end
  if ch=='{' or ch=='[' then
   local object=ch=='{';local ending=if object then '}' else ']';position+=1;ws();local result={}
   if text:sub(position,position)==ending then position+=1;return result end
   while true do
    local key=if object then stringValue() else #result+1
    if object then ws();assert(text:sub(position,position)==':');position+=1 end
    result[key]=parse();ws();local sep=text:sub(position,position);position+=1;if sep==ending then break end;assert(sep==',','Bad JSON separator');ws()
   end;return result
  end
  for word,value in {['true']=true,['false']=false} do if text:sub(position,position+#word-1)==word then position+=#word;return value end end
  if text:sub(position,position+3)=='null' then position+=4;return nil end
  local value=text:match('^[-+%d.eE]+',position);assert(value and tonumber(value),'Bad JSON number');position+=#value;return tonumber(value)
 end
 local result=parse();ws();assert(position>#text,'Trailing JSON');return result
end
local services={}
local gameMock=newInstance('DataModel');gameMock.Name='ExamplePlace';gameMock.PlaceId=123
local workspaceMock=newInstance('Workspace');workspaceMock.Name='Workspace';workspaceMock.Parent=gameMock
services.Workspace=workspaceMock
local requestCount=0
function methods:GetService(class)
 if services[class] then return services[class] end
 local service=newInstance(class);service.Name=class;service.Parent=gameMock;services[class]=service;return service
end
function methods:Get() return self._selection or {} end
function methods:Set(selection) self._selection=selection end
function methods:GetTextSize(text,size,font,bounds)
 if text=='' then return vector(0,0) end
 local widths={};for line in (text..'\n'):gmatch('(.-)\n') do widths[#widths+1]=(utf8.len(line) or #line)*size*.53 end
 local rows=0;local w=0;for _,width in widths do w=math.max(w,width);rows+=math.max(1,math.ceil(width/math.max(1,bounds.X))) end
 return vector(math.min(w,bounds.X),rows*(size+3))
end
function methods:JSONEncode(v) return jsonEncode(v) end
function methods:JSONDecode(v) return jsonDecode(v) end
function methods:GenerateGUID() self._guid=(self._guid or 0)+1;return 'mock-guid-'..self._guid end
function methods:UrlEncode(text) return (text:gsub('([^%w%-_%.~])',function(c) return string.format('%%%02X',string.byte(c)) end)) end
function methods:RequestAsync() requestCount+=1;return {Success=false,StatusCode=503,StatusMessage='Mock offline',Headers={},Body='{"error":{"message":"Mock network disabled"}}'} end
function methods:CreateWebStreamClient() error('Mock engine has no live stream transport') end
function methods:IsKeyDown() return false end
function methods:IsModifierKeyDown(modifier)
 return modifier==EnumMock.ModifierKey.Shift and self._shift==true
end
function methods:GetCanUndo() return false,'' end
function methods:GetCanRedo() return false,'' end
function methods:IsRecordingInProgress() return false end
function methods:TryBeginRecording() return 'mock-recording' end
function methods:FinishRecording() end
function methods:SetWaypoint() end
function methods:PromptImportFilesAsync() return {} end
function methods:GetSetting(name) return self._settings and self._settings[name] end
function methods:SetSetting(name,value) self._settings=self._settings or {};self._settings[name]=value end
function methods:CreateToolbar(name) local toolbar=newInstance('PluginToolbar');toolbar.Name=name;return toolbar end
function methods:CreateButton(name) local button=newInstance('PluginToolbarButton');button.Name=name;return button end
function methods:SetActive(value) self._active=value end
function methods:CreateDockWidgetPluginGuiAsync(name,info)
 local gui=newInstance('DockWidgetPluginGui');gui.Name=name;gui.Enabled=info[2];gui._props.AbsoluteSize=vector(info[4],info[5]);gui._props.AbsolutePosition=vector(0,0);return gui
end
local pluginMock=newInstance('Plugin')
local osMock=table.clone(os);osMock.clock=function() return now end
local globals={
 Instance={new=newInstance},Enum=EnumMock,UDim=UDimMock,UDim2=UDim2Mock,Vector2=Vector2Mock,Vector3=Vector3Mock,Color3=Color3Mock,
 ColorSequence={new=function(...) return {_type='ColorSequence',...} end},NumberSequence={new=function(...) return {_type='NumberSequence',...} end},
 ColorSequenceKeypoint={new=function(...) return {...} end},NumberSequenceKeypoint={new=function(...) return {...} end},
 DateTime={now=function() return {FormatLocalTime=function() return '12:00:00' end,UnixTimestampMillis=1780000000000} end,fromUnixTimestampMillis=function(value) return {FormatLocalTime=function() return '12:00:00' end,UnixTimestampMillis=value} end},
 TweenInfo={new=function(...) return {...} end},DockWidgetPluginGuiInfo={new=function(...) return {...} end},
 task=taskMock,game=gameMock,workspace=workspaceMock,plugin=pluginMock,warn=warnMock,os=osMock,tick=function() return now end,
 typeof=function(v) return if type(v)=='table' and rawget(v,'_type') then v._type elseif type(v)=='table' and rawget(v,'_class') then 'Instance' else realTypeof(v) end,
}
function methods:Create(instance,info,goal)
 local complete=signal();return {Play=function() for k,v in goal do instance[k]=v end;complete:Fire(EnumMock.PlaybackState.Completed) end,Cancel=function() end,Completed=complete}
end
local moduleRoot=newInstance('Script');moduleRoot.Name='ForgePilot'
local nodes={}
for path,source in sources do
 local node=moduleRoot;local pieces=path:split('/')
 for i,piece in pieces do
  local name=piece;local child=node:FindFirstChild(name)
  if not child then child=newInstance(if i==#pieces then 'ModuleScript' else 'Folder');child.Name=name;child.Parent=node end
  node=child
 end
 node.Source=source;nodes[path]=node
end
local cache={};local loading={}
local requireMock
requireMock=function(module)
 assert(module and module:IsA('ModuleScript'),'Expected ModuleScript')
 if cache[module] then return cache[module] end
 assert(not loading[module],'Cyclic require '..module:GetFullName());loading[module]=true
 local fn,errorMessage=loadstring(module.Source,'@'..module:GetFullName());assert(fn,errorMessage)
 local env=setmetatable({script=module,require=requireMock},{__index=function(_,key) return globals[key] or getfenv(0)[key] end})
 setfenv(fn,env);local ok,value=pcall(fn);loading[module]=nil;if not ok then error(module:GetFullName()..': '..tostring(value)) end
 cache[module]=value;return value
end
local function module(path) return requireMock(nodes[path]) end

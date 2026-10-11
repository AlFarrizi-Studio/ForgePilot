-- Real modules and widget handlers; all network responses stay local.
local function runChatRegressions()
 local JSON=module('Utilities/JSONValidator')
 local tools=module('Roblox/ToolValidator')
 local service=module('AI/ProviderService')
 local transport=module('Utilities/UniversalHTTPClient')
 local registry=module('AI/UniversalProviderRegistry')
 local fixture=registry.newProfile('custom')
 fixture.baseUrl='https://fixture.invalid/v1';fixture.modelId='fixture-model';fixture.authStyle='none';fixture.streaming=false
 local spec={messages={{role='user',content='Keep this literal: "properties":[]'}},tools=tools.toDefinitions('build'),toolChoice='auto',streaming=false,maxOutputTokens=64}
 for _,protocol in {'openai_chat','openai_responses','openrouter','gemini_openai','anthropic_messages','gemini_native'} do
  fixture.protocol=protocol
  local request,reason=service.prepare(fixture,spec,nil,false)
  check('tool request builds '..protocol,request~=nil,reason)
  if request then
   check('empty schema dictionaries stay objects '..protocol,request.body:find('"properties":[]',1,true)==nil and request.body:find('"properties":{}',1,true)~=nil)
   check('unconstrained arguments avoid invalid any type '..protocol,request.body:find('"type":"any"',1,true)==nil)
   check('schema required and empty defaults remain arrays '..protocol,request.body:find('"required":[]',1,true)~=nil and request.body:find('"default":[]',1,true)~=nil)
   print('TOOL_REQUEST_JSON '..protocol..' '..request.body)
  end
  local followup=table.clone(spec)
  followup.messages={{role='user',content='Inspect'}, {role='assistant',content='',toolCalls={{id='empty-call',name='inspect_selection',arguments={}}}}, {role='tool',toolCallId='empty-call',content='Done.'}, {role='user',content='Continue'}}
  local paired=service.prepare(fixture,followup,nil,false)
  check('no-argument tool followup builds '..protocol,paired~=nil)
  if paired then
   local expected=if protocol=='anthropic_messages' then '"input":{}' elseif protocol=='gemini_native' then '"args":{}' else '"arguments":"{}"'
   check('no-argument tool followup keeps object arguments '..protocol,paired.body:find(expected,1,true)~=nil)
  end
 end
 for _,tool in tools.all() do
  local rule=tool.parameters.position
  if rule and rule.validate then
   check('vector tool accepts documented lowercase components',rule.validate({x=0,y=10,z=0}))
   check('vector tool rejects non-numeric components',not rule.validate({x='bad',y=10,z=0}))
  end
 end
 fixture.protocol='openai_chat'
 local nested=JSON.toolParameters({type='object',properties={payload={type='object',properties={}},anything={}},required={},anyOf={{type='object',properties={}}}})
 local nestedText=JSON.encode(nested)
 check('nested and unconstrained schemas retain object shapes',nestedText and nestedText:find('"anything":{}',1,true)~=nil and nestedText:find('"properties":[]',1,true)==nil)
 check('empty function arguments encode as an object',JSON.encodeObject({})=='{}')
 check('ordinary empty lists still encode as arrays',JSON.encode({})=='[]')
 local cycle={};cycle.loop=cycle
 check('cyclic JSON returns a controlled error',JSON.encode(cycle)==nil)
 check('non-finite JSON returns a controlled error',JSON.encode({value=math.huge})==nil)
 local escaped='"properties":[]\n\\quote\t'
 local encoded=JSON.encode({text=escaped})
 check('serializer preserves quoted user content',encoded and JSON.decode(encoded).text==escaped)
 local built=service.prepare(fixture,spec,nil,false)
 local originalRequest=methods.RequestAsync;local sentBody=nil
 methods.RequestAsync=function(_,request) sentBody=request.Body;return {StatusCode=200,Headers={},Body='{"choices":[{"message":{"content":"OK"}}]}'} end
 local response=transport.postJson(built.url,built.headers,built.jsonBody,{timeoutMs=15000})
 check('actual HTTP request preserves the adapter schema',response.ok and sentBody==built.body and sentBody:find('"properties":[]',1,true)==nil)
 local invalid=transport.postJson(built.url,built.headers,cycle)
 check('transport serialization failures return without throwing',not invalid.ok and invalid.transportError~=nil)
 local badRequests=0
 methods.RequestAsync=function() badRequests+=1;return {StatusCode=400,Headers={},Body='{"error":{"message":"Tool 2 function has invalid parameters schema: [] is not of type object","type":"BadRequestError","code":400}}'} end
 local bad=service.complete(fixture,spec,nil,{})
 check('invalid tool schemas stop after one request',not bad.ok and badRequests==1 and bad.error and not bad.error.retryable)
 methods.RequestAsync=originalRequest
 local spam=0
 local unsubscribe=EventBus.on(EventBus.Events.Toast,function(payload) if tostring(payload.message):find('Sending your API key',1,true) then spam+=1 end end)
 for _=1,3 do service.prepare(fixture,spec,'offline-fixture-key',false) end
 unsubscribe();check('custom provider preparation does not spam key toasts',spam==0)

 local retries=module('UI/RetryStatusUI')
 local cancelCount=0
 local card,retry=retries.build({operationId='retry-ui-fixture',providerName='Fixture',model='fixture-model',category='RATE_LIMITED',reason='Wait 60 seconds.',maxRetries=5,attempt=1,delaySeconds=60,paused=false,onCancel=function() cancelCount+=1 end})
 card.Parent=content
 local queued=#scheduled
 for index=1,20 do retry.setAttempt(index,60) end
 check('retry rescheduling keeps only one countdown worker',#scheduled<=queued+1)
 local heartbeatTicks=0
 taskMock.spawn(function() for _=1,10 do taskMock.wait(.1);heartbeatTicks+=1 end end)
 local countdown=card:FindFirstChild('Countdown')
 local before=countdown.Text;advance(1.25)
 check('retry countdown yields to other work',heartbeatTicks==10 and countdown.Text~=before)
 EventBus.emit('retry:state',{operationId='other-operation',state='RETRY_CANCELLED',reason='Wrong operation'})
 check('retry events are isolated by operation id',card:FindFirstChild('Headline',true).Text=='Provider Rate Limited')
 EventBus.emit('retry:state',{operationId='retry-ui-fixture',state='WAITING_FOR_QUOTA',paused=true,pauseReason='A longer provider wait.'})
 check('paused retry displays its current reason',card:FindFirstChild('Status').Text:find('A longer provider wait.',1,true)~=nil)
 EventBus.emit('retry:state',{operationId='retry-ui-fixture',state='RETRY_SCHEDULED',attempt=2,delaySeconds=2})
 advance(.25)
 check('scheduled retry restarts countdown',countdown.Text:find('Next Attempt:',1,true)~=nil)
 EventBus.emit('retry:state',{operationId='retry-ui-fixture',state='RETRYING'})
 local retrying=countdown.Text;advance(.5)
 check('old countdown does not overwrite the retrying state',countdown.Text==retrying)
 card:FindFirstChild('CancelRetry',true).MouseButton1Click:Fire();advance(.5)
 check('retry cancellation stops the countdown',cancelCount==1 and countdown.Text=='Retry cancelled.')
 card:FindFirstChild('CancelRetry',true).MouseButton1Click:Fire()
 check('repeated cancel clicks are ignored',cancelCount==1 and not card:FindFirstChild('CancelRetry',true).Interactable)
 retry.destroy();local afterDestroy=#scheduled;advance(2)
 check('destroyed retry card leaves no active countdown',#scheduled<=afterDestroy)

 local streaming=module('AI/StreamingManager');streaming.cancelAll();State.reset()
 local originalStream=service.stream;local failure=nil
 service.stream=function() error('Fixture streaming exception') end
 streaming.run({profile=fixture,spec=spec,taskId='exception-turn',onError=function(value) failure=value end})
 check('streaming exceptions release the active task',not streaming.isBusy() and failure and failure.message:find('Fixture streaming exception',1,true)~=nil)
 service.stream=function() end;failure=nil
 streaming.run({profile=fixture,spec=spec,taskId='missing-result-turn',onError=function(value) failure=value end})
 check('missing streaming completion releases the task',not streaming.isBusy() and failure~=nil)
 local late=nil;local delivered=0
 service.stream=function(_,_,_,callbacks) late=callbacks;taskMock.wait(1000) end
 streaming.run({profile=fixture,spec=spec,taskId='reused-task',onDone=function() delivered+=1 end})
 local stale=late;streaming.cancelAll()
 streaming.run({profile=fixture,spec=spec,taskId='reused-task',onDone=function() delivered+=1 end})
 stale.onText('late');stale.onDone({text='late',toolCalls={},durationMs=0,attempts=1})
 check('cancelled stream cannot unlock the next turn',streaming.isBusy() and delivered==0 and stale.shouldCancel())
 late.onDone({text='current',toolCalls={},durationMs=0,attempts=1})
 check('current stream resolves exactly once',not streaming.isBusy() and delivered==1)
 local retryManager=module('AI/SmartAutoRetryManager')
 local retryConfig=module('AI/RetryDelayCalculator').defaultConfig();retryConfig.enabled=false;retryConfig.rateLimitScheduler=false
 local thrown=retryManager.run({providerId=fixture.id,providerName='Fixture',model='fixture-model',endpoint=fixture.baseUrl,config=retryConfig,request=function() error('Fixture request exception') end})
 check('retry controller retains the original exception',thrown.error and thrown.error.message:find('Fixture request exception',1,true)~=nil)
 service.stream=originalStream;streaming.cancelAll();State.reset()

 local received={}
 local inputFrame,input=module('UI/ChatInput').build({onSend=function(value) received[#received+1]=value;return true end,onStop=function() end,onPickFiles=function() end,onOpenSettings=function() end,onModeChange=function() end})
 inputFrame.Parent=content
 local box=inputFrame:FindFirstChild('Input')
 input.setText('firstsecond');input.focus();box.CursorPosition=6
 gui.InputBegan:Fire({KeyCode=EnumMock.KeyCode.RightShift});box.InputBegan:Fire({KeyCode=EnumMock.KeyCode.Return});gui.InputBegan:Fire({KeyCode=EnumMock.KeyCode.Return})
 box.FocusLost:Fire(true);advance(.02)
 check('Shift Enter inserts once at the caret across duplicate events',#received==0 and input.getText()=='first\nsecond' and box.CursorPosition==7 and box:IsFocused())
 gui.InputEnded:Fire({KeyCode=EnumMock.KeyCode.RightShift})
 input.setText('keep replace end');box.CursorPosition=6;box.SelectionStart=13
 gui.InputBegan:Fire({KeyCode=EnumMock.KeyCode.LeftShift});box.InputBegan:Fire({KeyCode=EnumMock.KeyCode.Return});advance(.02)
 check('Shift Enter replaces the selected text',input.getText()=='keep \n end' and box.SelectionStart==-1)
 gui.InputEnded:Fire({KeyCode=EnumMock.KeyCode.LeftShift})
 input.setText('baris satu\nbaris dua');box.InputBegan:Fire({KeyCode=EnumMock.KeyCode.KeypadEnter});box.FocusLost:Fire(true);gui.InputBegan:Fire({KeyCode=EnumMock.KeyCode.KeypadEnter});advance(.02)
 check('Enter sends the whole multiline message once',#received==1 and received[1]=='baris satu\nbaris dua' and input.getText()=='')
 input.setText('busy draft');input.setBusy(true);input.focus();box.InputBegan:Fire({KeyCode=EnumMock.KeyCode.Return});advance(.02)
 check('Enter during an active task preserves the draft',#received==1 and input.getText()=='busy draft')
 input.setBusy(false);input.focus();box.FocusLost:Fire(true);advance(.02)
 check('native focus-lost Enter fallback sends once',#received==2 and received[2]=='busy draft')
 input.setText('destroyed');input.focus();box.InputBegan:Fire({KeyCode=EnumMock.KeyCode.Return});input.destroy();advance(.02)
 check('destroyed composer ignores deferred Enter',#received==2)
 inputFrame:Destroy()

 -- Exercise the actual chat path shown in the screenshot, including Cancel.
 Settings.setActiveProvider(profile.id);State.reset();Sessions.createConversation()
 service.stream=function(_,_,_,callbacks)
  callbacks.onWait(60,{category='RATE_LIMITED',reason='Fixture provider cooldown.'},1)
  while not callbacks.shouldCancel() do taskMock.wait(.05) end
 end
 chatAPI.input.setText('A rate-limited message');views.ChatView:FindFirstChild('Send',true).MouseButton1Click:Fire();advance(.2)
 local realCard=views.ChatView:FindFirstChild('RetryCard',true)
 check('rate-limited chat creates a responsive retry card',realCard~=nil and State.isBusy())
 if realCard then
  for name,view in views do view.Visible=name=='ChatView' end
  module('UI/DockWidget').navigate('chat')
  for _,width in {300,440,638,760} do
   compute(width,680)
   check('retry actions fit width '..width,allInside(realCard:FindFirstChild('Actions')))
   local iconsVisible=true
   for _,section in module('UI/DockWidget').SectionOrder do
    local icon=gui:FindFirstChild('Tab_'..section,true):FindFirstChild('Icon')
    iconsVisible=iconsVisible and icon.Visible and icon:FindFirstChild('Drawing')~=nil
   end
   check('native navigation icons remain visible '..width,iconsVisible)
  end
  compute(638,680);snapshot={name='chat-retry-fixed',width=638,height=680,items={}};export(gui:FindFirstChild('Root'),true,nil);print('CHAT_FIX_SNAPSHOT '..jsonEncode(snapshot))
  EventBus.emit('retry:state',{operationId=State.getTaskId(),state='RETRY_SCHEDULED',attempt=2,delaySeconds=30})
  check('chat retry card tracks the actual task id',realCard:FindFirstChild('Status').Text=='Retry: 2 / 5')
  realCard:FindFirstChild('CancelRetry',true).MouseButton1Click:Fire();advance(.5)
  check('Cancel Retry ends chat and releases the composer',not State.isBusy() and not streaming.isBusy() and views.ChatView:FindFirstChild('RetryCard',true)==nil and views.ChatView:FindFirstChild('Send',true)~=nil)
 end
 service.stream=originalStream;streaming.cancelAll();State.reset()
 local icons=module('Utilities/Icons')
 for key in icons.Glyphs do
  local icon=icons.glyph(key,16)
  local drawing=icon:FindFirstChild('Drawing')
  check('native icon strokes exist '..key,icon.Text=='' and drawing and #drawing:GetChildren()>0)
  icon.TextColor3=Color3Mock.new(.2,.8,.4)
  local matching=true
  if drawing then for _,stroke in drawing:GetChildren() do matching=matching and stroke.BackgroundColor3==icon.TextColor3 end end
  check('native icon follows theme color '..key,matching)
  icon:Destroy()
 end
end
runChatRegressions()

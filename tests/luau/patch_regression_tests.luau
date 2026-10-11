-- Reproduce the Sky failure and exercise production retry/stream controllers.
do
(function()
 local Inspector=module('Roblox/WorkspaceInspector')
 local Retry=module('AI/SmartAutoRetryManager')
 local Calc=module('AI/RetryDelayCalculator')
 local Smart=module('Core/SmartRetrySettings')
 local Scheduler=module('AI/ProviderRateLimitScheduler')
 local Provider=module('AI/ProviderService')
 local HTTP=module('Utilities/UniversalHTTPClient')
 local Registry=module('AI/UniversalProviderRegistry')
 local Detector=module('Utilities/UniversalErrorDetector')
 local Streaming=module('AI/StreamingManager')
 local saved=table.clone(Smart.get())
 local savedHTTP=HTTP.stream
 local lighting=gameMock:GetService('Lighting')
 local sky=newInstance('Sky');sky.Name='ReportedSky';sky.SkyboxBk='rbxassetid://123'
 sky.CelestialBodiesShown=false;sky.StarCount=0;sky.Archivable=false;sky.Parent=lighting
 sky:AddTag('Weather');sky:AddTag('Night')
 local inspected,props=pcall(Inspector.readProperties,sky)
 check('reported Lighting.Sky inspection uses valid Roblox methods',inspected,props)
 if inspected then
  check('Sky inspection reads the actual skybox value',props.SkyboxBk=='rbxassetid://123')
  check('Sky inspection preserves false and zero properties',props.CelestialBodiesShown=='false' and props.StarCount=='0' and props.Archivable=='false')
  check('Sky inspection reads sorted tags through GetTags',props.Tags=='Night, Weather')
  check('Sky does not inherit Lighting parent properties',props.Brightness==nil)
 end
 local part=newInstance('Part');part.Name='InheritedPart';part.Anchored=false;part.CanCollide=false;part.Transparency=0;part.Size=Vector3Mock.new(3,4,5);part.Parent=workspaceMock
 local partOK,partProps=pcall(Inspector.readProperties,part)
 check('Part inspection merges BasePart and Part properties',partOK and partProps.Anchored=='false' and partProps.CanCollide=='false' and partProps.Size=='3,4,5')
 local previousClock=lighting.ClockTime;lighting.ClockTime=17.5
 check('Lighting inspection returns values instead of nil',Inspector.describeLighting().ClockTime=='17.5')
 lighting.ClockTime=previousClock;sky:Destroy();part:Destroy()

 check('retry settings accessor exposes complete configuration',type(Smart.get())=='table' and Smart.get().maxRetries==Smart.get('maxRetries'))
 Smart.set('maxRetries',5);Smart.set('enabled',true);Smart.set('strategy','opencode')
 local config=Calc.fromSettings(Smart.get())
 for index,expected in {2,4,8,16,30} do
  local d=Calc.calculate({attempt=index,config=config,category='SERVER_ERROR',headers={['x-request-id']='unrelated'},now=now,random=function()return 0 end})
  check('OpenCode bounded base retry '..index,d.delaySeconds==expected,tostring(d.delaySeconds))
 end
 local jitter=Calc.calculate({attempt=1,config=config,category='NETWORK_ERROR',now=now,random=function()return 1 end})
 check('OpenCode preset adds positive bounded jitter',jitter.delaySeconds==2.5)
 local mandated=Calc.calculate({attempt=5,config=config,category='RATE_LIMITED',headers={['Retry-After']='45'},now=now,random=function()return 0 end})
 check('OpenCode preset honours Retry-After beyond fallback cap',mandated.delaySeconds==45 and mandated.mandatory)
 local known=Calc.calculate({attempt=1,config=config,category='RATE_LIMITED',headers={['retry-after']='3'},cooldownSeconds=60,cooldownEstimated=true,now=now,random=function()return 0 end})
 check('estimated scheduler cooldown cannot override explicit provider Retry-After',known.delaySeconds==3 and known.source=='retry_after_seconds')
 check('HTTP 401 remains permanent when a stream transport message exists',Detector.classify({statusCode=401,transportError='HTTP 401: Invalid key',streamInterrupted=true}).category=='INVALID_API_KEY')
 check('local invalid-member failure is not retryable',Detector.classify({transportError='GetAncestors is not a valid member of Sky Lighting.Sky'}).category=='INVALID_REQUEST')

 Smart.set('strategy','linear');Smart.set('linearStepSeconds',1);Smart.set('maxDelaySeconds',1);Smart.set('jitterPercent',0);Smart.set('maxRetries',2)
 config=Provider.getRetryConfig()
 Scheduler.clearAll();Retry.resetRuntime()
 local count=0;local result=nil;local categories={}
 taskMock.spawn(function()
  result=Retry.run({operationId='default-sleep-regression',providerId='fixture',providerName='Fixture',model='fixture',endpoint='fixture.example',config=config,
   onWait=function(_,decision)categories[#categories+1]=decision.category end,
   request=function()count+=1;if count==1 then return nil,{statusCode=503,body='temporary server error'}end;return {text='Recovered'},nil end})
 end)
 advance(1.2)
 check('default task.wait does not cancel Auto Retry',result and result.ok and count==2 and result.attemptsMade==2)
 check('retry status carries the real failure category',categories[1]=='SERVER_ERROR')
 check('retry operation records configured retry limit',Retry.getOperation('default-sleep-regression').maxRetries==2)

 Scheduler.clearAll();count=0;result=nil;config.maxDelaySeconds=30;config.linearStepSeconds=30
 taskMock.spawn(function()
  result=Retry.run({operationId='cancel-wait-regression',providerId='fixture',providerName='Fixture',model='fixture',endpoint='fixture.example',config=config,
   onWait=function()taskMock.delay(.05,function()Retry.cancel('cancel-wait-regression')end)end,
   request=function()count+=1;return nil,{statusCode=503,body='temporary server error'}end})
 end)
 advance(.25)
 check('Stop interrupts a long retry countdown immediately',result and result.cancelled and count==1)
 Scheduler.clearAll();count=0;result=nil;config.maxAutoWaitSeconds=5
 result=Retry.run({operationId='long-cooldown-regression',providerId='fixture',providerName='Fixture',model='fixture',endpoint='fixture.example',config=config,
  request=function()count+=1;return nil,{statusCode=429,body='rate limited',headers={['Retry-After']='300'}}end})
 check('long provider cooldown pauses with an explanation instead of freezing',result.paused and count==1 and result.error.message:find('paused',1,true)~=nil)

 local profile=Registry.newProfile('openai');profile.modelId='fixture';profile.streaming=true;profile.timeoutMs=1000
 local spec={model='fixture',messages={{role='user',content='fixture'}},streaming=true}
 local function runFixture(name,transport,callbacks)
  Scheduler.clearAll();Retry.resetRuntime();Streaming.cancelAll();State.reset()
  HTTP.stream=transport
  local outcome=nil
  taskMock.spawn(function()outcome=Agent.sendTurn(profile,spec,name,callbacks or {})end)
  advance(3.5)
  return outcome
 end
 count=0;local resetCount=0
 local recovered=runFixture('partial-recovery-regression',function(_,callbacks)
  count+=1
  callbacks.onOpen(if count==1 then 503 else 200,{['retry-after']='1'})
  if count==1 then
   callbacks.onChunk('data: '..jsonEncode({choices={{delta={content='old partial',reasoning_content='old thinking',tool_calls={{index=0,id='old-call',type='function',['function']={name='create_part',arguments='{}'}}}}}}})..'\n\n')
   callbacks.onError('HTTP 503: temporary overload',{statusCode=503,body='temporary overload',headers={['retry-after']='1'}})
  else
   callbacks.onChunk('data: '..jsonEncode({choices={{delta={content='complete reply',reasoning_content='new thinking'}}}})..'\n\n')
   callbacks.onChunk('data: [DONE]\n\n')
  end
  return {isDone=function()return true end,cancel=function()end}
 end,{onReset=function()resetCount+=1 end})
 check('stream retries recover through the actual sendTurn path',recovered and not recovered.cancelled and recovered.attempts==2 and count==2)
 check('stream retry replaces partial text and reasoning without duplicates',recovered and recovered.text=='complete reply' and recovered.reasoning=='new thinking' and resetCount==1)
 check('failed stream tool calls are discarded before execution',recovered and #recovered.toolCalls==0)

 count=0
 local unauthorized=runFixture('permanent-stream-regression',function(_,callbacks)
  count+=1;callbacks.onOpen(401,{})
  callbacks.onError('HTTP 401: invalid key',{statusCode=401,body='invalid key'})
  return {isDone=function()return true end,cancel=function()end}
 end)
 check('invalid API key stops streaming retry after one attempt',unauthorized and unauthorized.error.category=='INVALID_API_KEY' and unauthorized.attempts==1 and count==1)
 count=0
 local invalidEvent=runFixture('permanent-sse-regression',function(_,callbacks)
  count+=1;callbacks.onOpen(200,{})
  callbacks.onChunk('data: '..jsonEncode({error={code='invalid_api_key',message='Invalid API key'}})..'\n\n')
  return {isDone=function()return true end,cancel=function()end}
 end)
 check('SSE error objects retain permanent provider codes',invalidEvent and invalidEvent.error.category=='INVALID_API_KEY' and count==1)

 count=0
 local timedOut=runFixture('idle-retry-regression',function(_,callbacks)
  count+=1
  if count>1 then callbacks.onChunk('data: '..jsonEncode({choices={{delta={content='recovered after idle'}}}})..'\n\n');callbacks.onChunk('data: [DONE]\n\n')end
  local closed=count>1
  return {isDone=function()return closed end,cancel=function()closed=true end}
 end)
 check('idle timeout can retry and recover without leaving chat busy',timedOut and timedOut.text=='recovered after idle' and timedOut.attempts==2 and not Streaming.isBusy())

 count=0
 local exhausted=runFixture('exhausted-stream-regression',function(_,callbacks)
  count+=1
  if count==1 then callbacks.onChunk('data: '..jsonEncode({choices={{delta={content='preserved partial'}}}})..'\n\n')end
  callbacks.onError('connection reset')
  return {isDone=function()return true end,cancel=function()end}
 end)
 check('stream retry stops at configured additional attempt limit',exhausted and exhausted.cancelled and count==3 and exhausted.attempts==3)
 check('failed retries keep useful earlier partial output',exhausted and exhausted.text=='preserved partial' and #exhausted.toolCalls==0)

 count=0
 local retryOff=Smart.get('enabled');Smart.set('enabled',false)
 local immediate=runFixture('disabled-stream-regression',function(_,callbacks)
  count+=1;callbacks.onError('connection reset')
  return {isDone=function()return true end,cancel=function()end}
 end)
 check('disabled Auto Retry sends exactly one stream request',immediate and immediate.cancelled and count==1)
 Smart.set('enabled',retryOff)
 count=0
 local eofRecovery=runFixture('eof-stream-regression',function(_,callbacks)
  count+=1;callbacks.onChunk('data: '..jsonEncode({choices={{delta={content=if count==1 then 'lost partial' else 'finished'}}}})..'\n\n')
  if count>1 then callbacks.onChunk('data: [DONE]\n\n')end
  return {isDone=function()return true end,cancel=function()end}
 end)
 check('unexpected EOF auto retries instead of silently accepting a partial answer',eofRecovery and eofRecovery.text=='finished' and not eofRecovery.cancelled and count==2)

 local icon=module('Utilities/Icons').brandMark(26);local image=icon:FindFirstChild('PluginIcon')
 check('header uses published ForgePilot icon with offline fallback',image and image.Image:find('82058489576798',1,true)~=nil and image.Visible==false)
 image.IsLoaded=true
 check('header displays image once Roblox loads the thumbnail',image.Visible and icon:GetChildren()[1].Visible==false)
 icon:Destroy()

 HTTP.stream=savedHTTP;Settings.setValue('smartRetry',saved);Scheduler.clearAll();Retry.resetRuntime();Streaming.cancelAll();State.reset()
 local settingPage=views.SettingsView
 local retryInput=nil
 for _,child in settingPage:GetDescendants()do if child:IsA('TextBox') and child:GetAttribute('RetrySetting')=='maxRetries' then retryInput=child;break end end
 check('Retry settings expose numeric controls with real setting keys',retryInput~=nil)
 if retryInput then
  local previous=Smart.get('maxRetries');retryInput.Text='7';retryInput.FocusLost:Fire(false)
  check('Retry number edits persist on blur under the runtime key',Smart.get('maxRetries')==7 and Smart.get('Maximum Retries')==nil)
  Smart.set('maxRetries',previous)
 end
 local retryButton=views.ChatView:FindFirstChild('AutoRetrySettings',true)
 check('chat exposes a visible Auto Retry settings shortcut',retryButton~=nil and retryButton.Text=='Retry: On')
 local oldEnabled=Smart.get('enabled');Smart.set('enabled',false)
 check('chat retry shortcut updates when Auto Retry is disabled',retryButton and retryButton.Text=='Retry: Off')
 Smart.set('enabled',oldEnabled)
end)()
end

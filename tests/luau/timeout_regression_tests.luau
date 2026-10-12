-- Production transports/controllers, with deterministic stalled callbacks.
do
(function()
 local Bridge=module('Core/BridgeClient')
 local Provider=module('AI/ProviderService')
 local HTTP=module('Utilities/UniversalHTTPClient')
 local Streaming=module('AI/StreamingManager')
 local Registry=module('AI/UniversalProviderRegistry')
 local Smart=module('Core/SmartRetrySettings');local retryEnabled=Smart.get('enabled')
 -- These cases test single-attempt transport cleanup; recovery is exercised
 -- separately with Auto Retry enabled in patch_regression_tests.
 Smart.set('enabled',false)
 local previousRequest=methods.RequestAsync
 local previousStream=HTTP.stream
 local mode='callback';local polls=0;local supportsJobs=true
 Settings.setValue('bridgeEnabled',true);Settings.setValue('bridgeUrl','http://127.0.0.1:20129')
 Bridge.setToken('timeout-test-token-0123456789')
 methods.RequestAsync=function(_,req)
  local body={ok=true}
  if req.Url:find('/health',1,true) then body={ok=true,workspace='fixture',fullAccess=true,capabilities={streaming=true,files=true,toolJobs=supportsJobs,streamIdleTimeout=true}}
  elseif req.Url:find('/stream/',1,true) and req.Method=='GET' then
   polls+=1
   if mode=='callback' then body={events={{cursor=1,chunk='data: fixture\n\n'}},done=false}
   elseif mode=='request-stall' then taskMock.wait(1000)
   else body={events={},done=false} end
  elseif req.Url:find('/stream',1,true) and req.Method=='POST' then body={id='timeout-fixture'} end
  return {StatusCode=200,Body=jsonEncode(body),Headers={}}
 end
 supportsJobs=false
 local oldBridge,oldError=Bridge.connect()
 check('old companion cannot advertise unsupported async jobs',oldBridge==nil and not Bridge.isConnected() and oldError:find('older package',1,true)~=nil)
 supportsJobs=true;Bridge.connect()
 local callbackError=nil
 local handle=Bridge.stream({body='{}',headers={},url='https://fixture.example',timeoutMs=1000},{
  onChunk=function() error('callback fixture') end,onError=function(message) callbackError=message end,
 })
 check('callback exception settles bridge stream handle',handle.isDone() and callbackError~=nil)
 mode='quiet';polls=0;local timeoutError=nil;local heartbeat=0
 handle=Bridge.stream({body='{}',headers={},url='https://fixture.example',timeoutMs=1000},{onError=function(message) timeoutError=message end})
 taskMock.spawn(function()for _=1,10 do taskMock.wait(.1);heartbeat+=1 end end)
 advance(1.2)
 check('quiet bridge stream reaches its deadline',handle.isDone() and timeoutError and timeoutError:find('timed out',1,true)~=nil)
 check('empty bridge polling yields to the UI scheduler',heartbeat==10 and polls>0 and polls<100)
 mode='request-stall';timeoutError=nil
 handle=Bridge.stream({body='{}',headers={},url='https://fixture.example',timeoutMs=1000},{onError=function(message)timeoutError=message end})
 advance(1.2)
 check('stalled localhost poll settles after request deadline',handle.isDone() and timeoutError~=nil)
 mode='callback'
 local safe,throwing=pcall(function()return Bridge.stream({body='{}',headers={},url='https://fixture.example',timeoutMs=1000},{onChunk=function()error('fixture')end,onError=function()error('secondary fixture')end})end)
 check('error callback exception cannot strand a bridge handle',safe and throwing.isDone())

 local profile=Registry.newProfile('openai');profile.modelId='fixture-model';profile.timeoutMs=1000;profile.streaming=true
 local spec={model='fixture-model',messages={{role='user',content='fixture'}},streaming=true}
 local closed=false;local failure=nil
 HTTP.stream=function(_,callbacks)
  callbacks.onError('Fixture transport failure without Closed event')
  return {isDone=function()return closed end,cancel=function()closed=true end}
 end
 local instant=now
 Provider.stream(profile,spec,'fixture-key',{onError=function(value)failure=value end})
 check('provider stops on transport error without waiting for Closed',closed and failure~=nil and now==instant)
 closed=false;failure=nil
 HTTP.stream=function()return {isDone=function()return closed end,cancel=function()closed=true end}end
 taskMock.spawn(function()Provider.stream(profile,spec,'fixture-key',{onError=function(value)failure=value end})end)
 advance(1.2)
 check('provider independently closes never-settling stream',closed and failure and failure.message:find('timed out',1,true)~=nil)
 HTTP.stream=previousStream
 local savedProviderStream=Provider.stream
 Provider.stream=function()taskMock.wait(1000)end
 Streaming.cancelAll();State.reset()
 failure=nil
 Streaming.run({profile=profile,spec=spec,taskId='timeout-turn',onError=function(value)failure=value end})
 advance(21.2)
 check('turn watchdog releases active streaming task',not Streaming.isBusy() and failure and failure.message:find('timed out',1,true)~=nil)
 -- The real Agent run owns the UI/task lock and must also release it on timeout.
 local active=Settings.getActiveProvider();local savedTimeout=active.timeoutMs;local savedStreaming=active.streaming
 active.timeoutMs=1000;active.streaming=true
 local result=nil
 State.reset()
 taskMock.spawn(function()result=Agent.runTask({userText='timeout fixture',mode='plan',conversation=Sessions.ensureConversation()})end)
 check('timeout fixture enters actual agent busy state',State.isBusy())
 advance(21.2)
 check('timed out agent run returns and releases UI lock',result and not result.ok and not State.isBusy())
 Provider.stream=function(_,_,_,callbacks)callbacks.onText('Recovered');callbacks.onDone({text='Recovered',toolCalls={},attempts=1})end
 State.reset()
 local recovered=runAgentTask({userText='after timeout',mode='plan',conversation=Sessions.ensureConversation()})
 check('new agent task can complete after timeout',recovered.ok and not State.isBusy())
 active.timeoutMs=savedTimeout;active.streaming=savedStreaming
 Provider.stream=savedProviderStream;methods.RequestAsync=previousRequest
 Bridge.setToken('');Bridge.reset();Streaming.cancelAll();State.reset()
 -- The native transport must also close after callback failures.
 local originalNative=methods.CreateWebStreamClient;local closes=0
 local client={MessageReceived=signal(),Error=signal(),Closed=signal()}
 client.Close=function()closes+=1;client.Closed:Fire()end
 methods.CreateWebStreamClient=function()return client end
 HTTP.resetCapabilityCache()
 local nativeError=nil
 local native=HTTP.stream({url='https://api.example.com/v1/chat/completions',headers={},body='{}',timeoutMs=1000,label='fixture'},{onChunk=function()error('native callback fixture')end,onError=function(message)nativeError=message end})
 client.MessageReceived:Fire('data: fixture\n\n')
 check('native callback exception closes stream exactly once',native.isDone() and closes==1 and nativeError~=nil)
 client.Error:Fire(500,'late error');client.Closed:Fire()
 check('late native events cannot re-close failed stream',closes==1)
 methods.CreateWebStreamClient=originalNative;HTTP.resetCapabilityCache()
 Smart.set('enabled',retryEnabled)
end)()
end

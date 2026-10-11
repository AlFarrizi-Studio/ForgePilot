-- Integration checks using actual plugin modules with deterministic bridge HTTP.
do
(function()
 local Bridge=module('Core/BridgeClient')
 local Registry=module('AI/UniversalProviderRegistry')
 local Tools=module('Roblox/ToolValidator')
 local Executor=module('Roblox/ActionExecutor')
 local Provider=module('AI/ProviderService')
 local HTTP=module('Utilities/UniversalHTTPClient')
 local Prompt=module('AI/SystemPrompts')
 local Http=gameMock:GetService('HttpService')
 local previousRequest=methods.RequestAsync
 local pairing='offline-bridge-test-token-0123456789'
 local nativeCount=#Tools.forMode('build')
 local routed={oauth=0,free=0,apikey=0}
 for _,preset in Registry.presetList() do if preset.viaRouter then routed[preset.category]+=1;check('router logo catalog '..preset.id,type(preset.iconId)=='string' and preset.iconId~='') end end
 check('9router catalog categories are complete',routed.oauth==21 and routed.free==16 and routed.apikey==45)
 local gateway=Registry.newProfile('9r_codex');gateway.modelId='model-fixture'
 local Capability=module('AI/ModelCapabilityDetector')
 check('unlisted router model does not assume native tools',Capability.getOrBuildReport(gateway).capabilities.tool_calling.status=='unknown')
 local resolved=module('AI/BaseURLResolver').normaliseBase('http://127.0.0.1:20128/v1')
 check('loopback HTTP is preserved for local gateways',resolved=='http://127.0.0.1:20128/v1')
 check('remote HTTP stays rejected',module('AI/BaseURLResolver').normaliseBase('http://api.example.com/v1')==nil)
 local prepared,prepareError=Provider.prepare(gateway,{model='model-fixture',messages={{role='user',content='hi'}},streaming=false},nil,false)
 check('gateway request validates local endpoint',prepared~=nil,prepareError)
 check('gateway prefixes selected provider alias',prepared and jsonDecode(prepared.body).model=='cx/model-fixture')
 local prefixed=Provider.prepare(gateway,{model='cx/model-fixture',messages={{role='user',content='hi'}},streaming=false},nil,false)
 check('gateway does not double-prefix routed model',jsonDecode(prefixed.body).model=='cx/model-fixture')
 check('unconnected bridge tools are not advertised',not Bridge.isConnected() and not Tools.validate('read_file',{path='file.txt'},'plan').ok)
 Settings.setValue('bridgeEnabled',true);Settings.setValue('bridgeUrl','http://127.0.0.1:20129');Bridge.setToken(pairing)
 local requests={}
 local toolJobs={}
 methods.RequestAsync=function(self,req)
  requests[#requests+1]=req
  if req.Url:find('127.0.0.1:20129',1,true) then
   check('bridge token only travels to loopback',req.Headers.Authorization=='Bearer '..pairing)
   local body={}
   if req.Url:find('/health',1,true) then body={ok=true,workspace='C:/ForgePilotWorkspace',fullAccess=true,capabilities={streaming=true,web=true,files=true,toolJobs=true,streamIdleTimeout=true}}
   elseif req.Url:find('/tools/start',1,true) then local args=jsonDecode(req.Body);toolJobs[args.operationId]=args.name;body={ok=true,operationId=args.operationId}
   elseif req.Url:find('/tools/',1,true) then local id=req.Url:match('/tools/(.+)$');body={done=true,result={ok=true,verified=true,message='bridge executed '..toolJobs[id]}}
   elseif req.Url:find('/providers/open',1,true) then body={ok=true,message='Complete sign in'}
   elseif req.Url:find('/providers/status',1,true) then body={ok=true,connected=true,message='Account connected'}
   elseif req.Url:find('/router/login',1,true) then body={ok=true,message='Dashboard session connected'}
   elseif req.Url:find('/router/models',1,true) then body={ok=true,models={'cx/model-fixture'},metadata={['cx/model-fixture']={capabilities={tools=false,vision=true,reasoning=true},contextWindow=200000,maxOutputTokens=16000}}}
   elseif req.Url:find('/stream?',1,true) then body={}
   elseif req.Url:find('/stream/',1,true) then
    body={events={{cursor=1,chunk='data: {"choices":[{"delta":{"reasoning_content":"Inspecting reference"}}]}\n\n'},{cursor=2,chunk='data: {"choices":[{"delta":{"content":"Ready"}}]}\n\ndata: [DONE]\n\n'}},cursor=2,done=true}
   elseif req.Url:find('/stream',1,true) then body={id='fixture-stream'} end
   return {StatusCode=200,Success=true,Body=jsonEncode(body),Headers={}}
  end
  return previousRequest(self,req)
 end
 local connected=Bridge.connect()
 check('bridge health activates real tool catalog',connected~=nil and Bridge.isConnected() and #Tools.forMode('build')==nativeCount+10)
 for _,protocol in {'openai_chat','openai_responses','openrouter','gemini_openai','gemini_native','anthropic_messages'} do
  local probeProfile=Registry.newProfile('openai');probeProfile.protocol=protocol
  local spec={model='fixture-model',messages={{role='user',content='Offline schema fixture'}},tools=Tools.toDefinitions('build'),streaming=false}
  local request,err=Provider.prepare(probeProfile,spec,'fixture-key',false)
  check('bridge tools encode in '..protocol,request~=nil,err)
  if request then print('TOOL_REQUEST_JSON '..protocol..' '..request.body) end
 end
 local access,accessApi=module('UI/AgentAccessView').build();access.Parent=content
 local password=access:FindFirstChild('RouterPassword',true)
 password.Text='offline-dashboard-password';access:FindFirstChild('ConnectRouter',true).MouseButton1Click:Fire()
 check('dashboard login clears its password input immediately',password.Text=='')
 advance(.1)
 check('dashboard login widget completes its real bridge path',access:FindFirstChild('RouterSessionStatus',true).Text=='Dashboard session connected')
 Settings.persist()
 check('dashboard password is not written to plugin settings',not tostring(pluginMock:GetSetting('ForgePilot.Settings.v1')):find('offline-dashboard-password',1,true))
 accessApi.destroy();access:Destroy()
 check('Plan cannot write external files',not Tools.validate('write_file',{path='test.txt',content='test'},'plan').ok)
 check('Build accepts validated file edit',Tools.validate('edit_file',{path='test.txt',oldText='old',newText='new'},'build').ok)
 local external=Executor.execute('web_fetch',{url='https://create.roblox.com/docs'},'plan')
 check('external result goes through actual executor',external.ok and external.verified and external.message=='bridge executed web_fetch')
 local inspection=Executor.execute('inspect_place',{},'plan')
 check('Roblox inspection returns its real text',inspection.ok and inspection.verified and inspection.message:find('Place:',1,true)~=nil)
 local prompt=Prompt.build({mode='plan',assistantName='ForgePilot',nativeToolCalling=false})
 check('system prompt explains active web and file access',prompt:find('Local bridge connected',1,true)~=nil and prompt:find('web_search',1,true)~=nil and prompt:find('query:string',1,true)~=nil)
 check('old blanket internet denial is removed',prompt:find('There is no filesystem',1,true)==nil)
 Settings.persist()
 check('bridge token is never written to plugin settings',not tostring(pluginMock:GetSetting('ForgePilot.Settings.v1')):find(pairing,1,true))
 local frame,api=Renderer.render({id='bridge-typing',role='assistant',content='',streaming=true},{})
 frame.Parent=content
 local instant=now
 api.appendDelta('No delay 日本')
 check('received text is visible without scheduler delay',frame:FindFirstChild('Live',true).Text=='No delay 日本' and now==instant)
 api.appendDelta('Thinking from provider','reasoning')
 check('thinking text streams separately from answer',frame:FindFirstChild('ReasoningText',true).Text=='Thinking from provider' and frame:FindFirstChild('Live',true).Text=='No delay 日本')
 frame:Destroy()
 local conversation=Sessions.ensureConversation()
 local message=Sessions.addMessage('assistant','',{streaming=true})
 local channel=''
 local unsubscribe=EventBus.on(EventBus.Events.MessageDelta,function(payload)if payload.messageId==message.id then channel=payload.channel end end)
 Sessions.appendToMessage(message.id,'provider summary','reasoning')
 check('session separates reasoning and emits its channel',message.content=='' and message.reasoning=='provider summary' and channel=='reasoning')
 unsubscribe()
 local started=now
 local answer='';local reasoning='';local finished=false
 Provider.stream(gateway,{model='model-fixture',messages={{role='user',content='hi'}},streaming=true},nil,{
  onText=function(delta)answer..=delta end,onReasoning=function(delta)reasoning..=delta end,
  onDone=function()finished=true end,onError=function(err)error(tostring(err))end,
 })
 check('bridge streaming delivers answer and thinking',finished and answer=='Ready' and reasoning=='Inspecting reference')
 check('provider completion adds no artificial drain wait',now==started)
 -- Exercise the actual OAuth widgets and paginated provider rows.
 providerView:FindFirstChild('BackToProviders',true).MouseButton1Click:Fire()
 search.Text='codex'
 providerView:FindFirstChild('AddPreset_9r_codex',true).MouseButton1Click:Fire()
 check('OAuth profile displays real sign-in controls',providerView:FindFirstChild('RouterAccount',true).Visible and providerView:FindFirstChild('ProviderSignIn',true).Text=='Sign in / Log in')
 providerView:FindFirstChild('ProviderSignIn',true).MouseButton1Click:Fire()
 advance(.1)
 local opened=false
 for _,req in requests do if req.Url:find('/providers/open',1,true) then opened=jsonDecode(req.Body).providerId=='codex' end end
 check('OAuth sign-in sends the selected provider id',opened)
 providerView:FindFirstChild('RefreshOAuthStatus',true).MouseButton1Click:Fire();advance(.1)
 check('OAuth connection refresh resolves without credentials in chat',providerView:FindFirstChild('ProviderSignIn',true).Text=='Manage account in 9Router')
 local ids=Provider.listModels(gateway,nil)
 check('gateway model list uses actual bridge selection',#ids==1 and ids[1]=='cx/model-fixture')
 local report=Capability.getOrBuildReport(gateway)
 check('refresh models invalidates old capability report',report.capabilities.tool_calling.status=='unsupported' and report.capabilities.vision.status=='supported' and report.capabilities.reasoning.source=='router_catalog')
 check('router catalog populates context and output limits',report.contextWindow==200000 and report.maxOutputTokens==16000)
 check('router vision still respects selected wire protocol',Capability.allowedAttachmentKinds(report,gateway.protocol).image==true and not Capability.allowedAttachmentKinds(report,'openai_text_completions').image)
 methods.RequestAsync=previousRequest
 Bridge.setToken('');Bridge.reset();search.Text=''
 check('disconnect removes bridge-only tools',not Bridge.isConnected() and #Tools.forMode('build')==nativeCount)
end)()
end

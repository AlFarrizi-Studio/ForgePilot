-- Run with the production retry subscription enabled, as it is in Studio.
do
(function()
 local Recovery=module('AI/RetryStateManager')
 local Provider=module('AI/ProviderService')
 local HTTP=module('Utilities/UniversalHTTPClient')
 local Retry=module('AI/SmartAutoRetryManager')
 local Scheduler=module('AI/ProviderRateLimitScheduler')
 local Registry=module('AI/UniversalProviderRegistry')
 local savedRetry=table.clone(Settings.getValue('smartRetry'))
 local savedHTTP=HTTP.postJson
 local savedStream=HTTP.stream
 local savedActive=Settings.getValue('activeProviderId')
 local savedConversation=Sessions.getActive()
 local savedWidgetEnabled=gui.Enabled
 local overlay=Theme.overlayHost(content)
 local savedOverlayVisible=overlay.Visible
 overlay.Visible=true
 gui.Enabled=true
 State.reset();Recovery.clear();Recovery.init();Retry.resetRuntime();Scheduler.clearAll()
 Settings.setValue('smartRetry',{enabled=true,strategy='linear',linearStepSeconds=1,maxDelaySeconds=1,jitterPercent=0,maxRetries=2})

 local fixture=Registry.newProfile('custom')
 fixture.displayName='Provider freeze fixture';fixture.baseUrl='https://fixture.invalid/v1'
 fixture.modelId='fixture-model';fixture.authStyle='none';fixture.protocol='openai_chat_completions'
 Settings.addProvider(fixture)
 local panel,panelAPI=module('UI/ProviderView').build(content)
 panelAPI.editProfile(fixture.id)
 local editor=panel:FindFirstChild('ProviderEditor')
 local model=panel:FindFirstChild('Field_ModelID',true):FindFirstChild('Input',true)
 local test=panel:FindFirstChild('Testconnection',true)
 local save=panel:FindFirstChild('Savechanges',true)
 local back=panel:FindFirstChild('BackToProviders',true)
 local status=panel:FindFirstChild('ProviderStatus',true)
 local errorStatus=401
 local requests=0
 HTTP.postJson=function()
  requests+=1
  return {ok=false,statusCode=errorStatus,headers={['retry-after']='1'},body=jsonEncode({error={message=if errorStatus==401 then 'Invalid API key' else 'Temporary provider failure'}}),durationMs=1}
 end

 test.MouseButton1Click:Fire();advance(.1)
 check('failed provider diagnostics do not own the agent state',State.get()=='IDLE' and not State.isBusy(),State.get())
 check('failed connection test unlocks the entire provider editor',model.TextEditable and save.Interactable and back.Interactable and test.Interactable)
 check('diagnostic errors do not become chat thinking text',Recovery.getActive()==nil and Recovery.shortText()==nil)
 State.reset();Recovery.clear();Scheduler.clearAll()
 panel:FindFirstChild('Tab_Model',true).MouseButton1Click:Fire()
 check('Model tab is reachable after a failed connection',panelAPI.getTab()=='Model' and panel:FindFirstChild('ModelPage',true).Visible)

 for _,code in {429,503} do
  State.reset();Recovery.clear();Scheduler.clearAll();requests=0;errorStatus=code
  test.MouseButton1Click:Fire();advance(3.2)
  check('diagnostic HTTP '..code..' uses one attempt despite enabled chat retry',requests==1,tostring(requests))
  check('diagnostic HTTP '..code..' restores provider editing',model.TextEditable and save.Interactable and back.Interactable and not State.isBusy(),State.get())
 end
 local diagnostic=table.clone(fixture);diagnostic.retryOverrides={enabled=false,maxRetries=0}
 local diagnosticConfig=Provider.getRetryConfig(diagnostic)
 check('diagnostic retry overrides reach the production request controller',diagnosticConfig.enabled==false and diagnosticConfig.maxRetries==0)
 check('diagnostics preserve the user chat retry configuration',Provider.getRetryConfig(fixture).enabled and Provider.getRetryConfig(fixture).maxRetries==2)

 State.reset();Recovery.clear();Scheduler.clearAll();requests=0
 HTTP.stream=function(_,callbacks)
  requests+=1;callbacks.onOpen(503,{['retry-after']='1'})
  callbacks.onError('HTTP 503: overloaded',{statusCode=503,body='temporarily overloaded',headers={['retry-after']='1'}})
  return {isDone=function()return true end,cancel=function()end}
 end
 panel:FindFirstChild('Tab_Tests',true).MouseButton1Click:Fire()
 panel:FindFirstChild('Teststreaming',true).MouseButton1Click:Fire();advance(.2)
 check('failed streaming diagnostic makes one request and restores the panel',requests==1 and model.TextEditable and save.Interactable and not State.isBusy())

 -- Run the agent, stream controller, retry state subscription and editor together.
 State.reset();Recovery.clear();Scheduler.clearAll();requests=0
 fixture.streaming=true;fixture.toolCalling=false
 Settings.updateProvider(fixture.id,fixture);Settings.setActiveProvider(fixture.id)
 local chatStates={}
 local unsubChatStates=EventBus.on(EventBus.Events.StateChanged,function(p)chatStates[p.state]=true end)
 HTTP.stream=function(_,callbacks)
  requests+=1
  callbacks.onOpen(if requests<=2 then 503 else 200,{['retry-after']='1'})
  if requests<=2 then
   callbacks.onError('HTTP 503: overloaded',{statusCode=503,body='temporarily overloaded',headers={['retry-after']='1'}})
  else
   callbacks.onChunk('data: '..jsonEncode({choices={{delta={content='Recovered chat reply.'}}}})..'\n\n')
   callbacks.onChunk('data: [DONE]\n\n')
  end
  return {isDone=function()return true end,cancel=function()end}
 end
 local conversation=Sessions.createConversation();Sessions.addMessage('user','Reply with a brief greeting.')
 local chatResult=nil
 taskMock.spawn(function()chatResult=Agent.runTask({userText='Reply with a brief greeting.',mode='plan',conversation=conversation})end)
 advance(.2)
 check('real chat retry retains its configuration lock until completion',State.isBusy() and not model.TextEditable and not save.Interactable)
 advance(3)
 check('actual chat Auto Retry still recovers with the production subscription',chatResult and chatResult.ok and requests==3 and conversation.messages[#conversation.messages].content=='Recovered chat reply.')
 check('actual chat retry emits recovery states for its own task',chatStates.RETRY_SCHEDULED and chatStates.RETRYING and chatStates.PROVIDER_RECOVERED)
 check('actual recovered chat unlocks provider settings without stale thinking',State.get()=='COMPLETED' and not State.isBusy() and model.TextEditable and save.Interactable and Recovery.shortText()==nil)
 unsubChatStates();HTTP.stream=savedStream

 -- No late/unrelated operation may claim an active or finished chat.
 State.reset();Recovery.clear();State.beginRun();State.setTaskId('current-chat')
 State.transition('THINKING',{taskId='current-chat',force=true})
 EventBus.emit('retry:state',{state='RETRIES_EXHAUSTED',operationId='unrelated-probe'})
 check('provider probe cannot replace an active chat state',State.get()=='THINKING' and State.getTaskId()=='current-chat')
 EventBus.emit('retry:state',{state='RETRIES_EXHAUSTED',operationId='old-turn',taskId='previous-chat'})
 check('stale retry events cannot replace the current chat',State.get()=='THINKING' and State.getTaskId()=='current-chat')
 State.setTaskId('current-chat');State.transition('THINKING',{force=true})
 EventBus.emit('retry:state',{state='RATE_LIMIT_DETECTED',operationId='current-turn',taskId='current-chat'})
 check('retry state still follows its own active chat',State.get()=='RATE_LIMIT_DETECTED' and Recovery.isRetrying())
 EventBus.emit('retry:state',{state='RETRYING',operationId='current-turn',taskId='current-chat'})
 EventBus.emit('retry:state',{state='PROVIDER_RECOVERED',operationId='current-turn',taskId='current-chat'})
 EventBus.emit('retry:state',{state='IDLE',operationId='current-turn',taskId='current-chat'})
 check('request completion leaves task completion to the agent',State.get()=='PROVIDER_RECOVERED' and State.isBusy())
 State.transition('COMPLETED',{force=true});State.endRun()
 EventBus.emit('retry:state',{state='RETRIES_EXHAUSTED',operationId='late-turn',taskId='current-chat'})
 check('late retry after completion cannot relock provider settings',State.get()=='COMPLETED' and not State.isBusy() and model.TextEditable and save.Interactable)
 check('finished chat clears retry thinking text',Recovery.getActive()==nil and Recovery.shortText()==nil)

 State.reset();Recovery.clear();State.beginRun();State.setTaskId('cancelled-chat')
 State.transition('THINKING',{force=true});State.cancel()
 EventBus.emit('retry:state',{state='RETRIES_EXHAUSTED',operationId='cancelled-turn',taskId='cancelled-chat'})
 check('late provider error preserves Stop while the worker winds down',State.get()=='CANCELLED' and State.isBusy())
 State.endRun();State.reset()
 State.beginRun();State.setTaskId('visible-lock');State.transition('THINKING',{force=true})
 check('provider footer explains a real chat configuration lock',status.Text:find('Chat in progress',1,true)~=nil and not model.TextEditable and not save.Interactable,status.Text)
 State.transition('COMPLETED',{force=true});State.endRun();State.reset()
 check('finishing a real chat restores provider editing',model.TextEditable and save.Interactable and test.Interactable)

 -- Menus use a shared overlay. Hiding the editor must also remove its blocker.
 panel:FindFirstChild('Tab_Model',true).MouseButton1Click:Fire()
 local actions=panel:FindFirstChild('ProfileActions',true):FindFirstChild('Dropdown',true)
 local function visibleOverlays()
  local count=0
  for _,child in overlay:GetChildren() do
   if (child.Name=='Menu' or child.Name=='MenuDismiss') and child.Visible then count+=1 end
  end
  return count
 end
 actions.MouseButton1Click:Fire()
 check('provider dropdown shows menu and dismissal layer',visibleOverlays()==2)
 editor.Visible=false
 check('hiding provider editor removes its invisible input blocker',visibleOverlays()==0)
 Components.closeMenus();editor.Visible=true
 actions.MouseButton1Click:Fire();actions.Interactable=false
 check('disabling a menu owner removes its input blocker',visibleOverlays()==0)
 Components.closeMenus();actions.Interactable=true
 actions.MouseButton1Click:Fire();panel.Interactable=false
 check('disabling the provider panel removes shared menu overlays',visibleOverlays()==0)
 Components.closeMenus();panel.Interactable=true
 actions.MouseButton1Click:Fire();panel.Parent=nil
 check('detaching a provider view removes shared menu overlays',visibleOverlays()==0)
 Components.closeMenus();panel.Parent=content
	actions.MouseButton1Click:Fire();gui.Enabled=false
	check('closing the plugin widget removes shared menu overlays',visibleOverlays()==0)
	Components.closeMenus();gui.Enabled=true
 actions.MouseButton1Click:Fire();panelAPI.destroy();panel:Destroy()
 check('destroying provider settings leaves no input blocker',visibleOverlays()==0)

 HTTP.postJson=savedHTTP;HTTP.stream=savedStream;Settings.removeProvider(fixture.id);Settings.setActiveProvider(savedActive)
 Settings.setValue('smartRetry',savedRetry);Recovery.shutdown();Recovery.clear()
 State.reset();Scheduler.clearAll();Retry.resetRuntime();overlay.Visible=savedOverlayVisible
 gui.Enabled=savedWidgetEnabled
 if savedConversation then Sessions.setActive(savedConversation.id)end
end)()
end

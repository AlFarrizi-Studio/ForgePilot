-- Exercises the actual provider widgets with deterministic, offline transports.
for name,view in views do view.Visible=name=='SettingsView' end
EventBus.emit(EventBus.Events.Navigate,{section='settings',tab='AI & Provider'})
module('UI/DockWidget').navigate('settings')
local providerView=views.SettingsView:FindFirstChild('ProviderView',true)
local providerOverview=providerView:FindFirstChild('ProviderOverview')
local providerEditor=providerView:FindFirstChild('ProviderEditor')
local credentials=module('Core/CredentialStore')
local providerService=module('AI/ProviderService')
local search=providerView:FindFirstChild('ProviderSearch',true)
local function chooseMenu(row,label)
 row:FindFirstChild('Dropdown',true).MouseButton1Click:Fire()
 local host=module('Utilities/Theme').overlayHost(row)
 for _,menu in host:GetChildren() do
  if menu.Name=='Menu' and menu.Visible then
   for _,option in menu:GetChildren() do
    if option:IsA('TextButton') and option.Text==label then option.MouseButton1Click:Fire();return end
   end
  end
 end
 error('Missing menu option '..label)
end
local function inputFor(label)
 local row=providerView:FindFirstChild('Field_'..label:gsub('%s+',''),true)
 return row and row:FindFirstChild('Input',true)
end
check('provider opens on searchable overview',providerOverview.Visible and not providerEditor.Visible)
search.Text='openrouter'
check('provider search filters profiles and catalog',providerView:FindFirstChild('AddPreset_openrouter',true)~=nil and providerView:FindFirstChild('AddPreset_openai',true)==nil)
providerView:FindFirstChild('AddPreset_openrouter',true).MouseButton1Click:Fire()
local added=Settings.getActiveProvider()
check('preset opens a saved connection editor',added.providerName=='OpenRouter' and providerEditor.Visible and not providerOverview.Visible)
local modelInput=inputFor('Model ID')
modelInput.Text='fixture/model';modelInput.FocusLost:Fire(false)
check('model entry persists on blur',Settings.getProvider(added.id).modelId=='fixture/model')
State.beginRun()
check('active chat locks provider configuration',not modelInput.TextEditable and not providerView:FindFirstChild('Savechanges',true).Interactable)
State.endRun()
check('finishing chat restores provider configuration',modelInput.TextEditable and providerView:FindFirstChild('Savechanges',true).Interactable)
local key=providerView:FindFirstChild('ApiKey',true)
local reveal=providerView:FindFirstChild('Reveal',true)
key.Text='offline-fixture-key'
reveal.MouseButton1Click:Fire();reveal.MouseButton1Click:Fire()
check('show hide preserves a newly typed key',key.Text=='offline-fixture-key' and key.TextTransparency==1)
key.FocusLost:Fire(false)
check('key is session only',credentials.get(added.id)=='offline-fixture-key' and Settings.assertNoSecrets())
providerView:FindFirstChild('Tab_Advanced',true).MouseButton1Click:Fire()
chooseMenu(providerView:FindFirstChild('Field_Authentication',true),'No authentication')
check('authentication choice survives saving',Settings.getProvider(added.id).authStyle=='none' and not providerView:FindFirstChild('Field_APIKey',true).Visible)
local known=registry.newProfile('openai');known.modelId='gpt-4o-mini';known.contextWindowMode='manual';known.maxOutputTokensMode='manual';known.contextWindow=16000;known.maxOutputTokens=2000
local uiReport=module('AI/CapabilityInspector').buildReport(known)
local requestReport=module('AI/ModelCapabilityDetector').buildReport(known)
check('manual token limits override known model metadata',uiReport.contextWindow==16000 and uiReport.maxOutputTokens==2000 and requestReport.contextWindow==16000 and requestReport.maxOutputTokens==2000)
providerView:FindFirstChild('Tab_Model',true).MouseButton1Click:Fire()
local contextRow=providerView:FindFirstChild('Field_ContextWindow',true)
local detectContext=providerView:FindFirstChild('ModelPage',true):FindFirstChild('ToggleRow',true)
detectContext:FindFirstChild('Hit',true).MouseButton1Click:Fire()
check('manual context reveals its input',contextRow.Visible and Settings.getProvider(added.id).contextWindowMode=='manual')
detectContext:FindFirstChild('Hit',true).MouseButton1Click:Fire()
check('automatic context hides the manual input',not contextRow.Visible and Settings.getProvider(added.id).contextWindowMode=='auto')
local connectionButton=providerView:FindFirstChild('Testconnection',true)
local originalTest=providerService.testConnection
providerService.testConnection=function()
 taskMock.wait(.1)
 return {ok=true,latencyMs=123,message='Offline fixture',endpoint='https://fixture.invalid/v1'}
end
connectionButton.MouseButton1Click:Fire()
check('provider test locks editing and navigation',not modelInput.TextEditable and not providerView:FindFirstChild('BackToProviders',true).Interactable)
advance(.2)
local testResult=providerView:FindFirstChild('TestResult',true)
check('test shows actual latency in the persistent footer',testResult.Text:find('123 ms',1,true)~=nil and providerView:FindFirstChild('ProviderStatus',true).Text=='Connected in 123 ms.' and connectionButton.Interactable)
providerService.testConnection=function() error('Offline transport exception') end
connectionButton.MouseButton1Click:Fire()
advance(.02)
check('transport exceptions restore all controls',modelInput.TextEditable and connectionButton.Interactable and connectionButton.Text=='Test connection' and testResult.Text:find('test failed',1,true)~=nil)
providerService.testConnection=originalTest
local originalModels=providerService.listModels
providerService.listModels=function() return {'fixture/a','fixture/b'},nil end
providerView:FindFirstChild('Refreshmodels',true).MouseButton1Click:Fire()
advance(.02)
local modelList=providerView:FindFirstChild('ModelList',true)
local available=nil
for _,child in modelList:GetChildren() do if child.Name:find('Field_Availablemodels',1,true) then available=child end end
check('model refresh retains its control and creates choices',available~=nil and providerView:FindFirstChild('Refreshmodels',true)~=nil)
chooseMenu(available,'fixture/b')
check('choosing a fetched model updates the profile',Settings.getProvider(added.id).modelId=='fixture/b')
providerService.listModels=originalModels
search.Text=''
providerView:FindFirstChild('BackToProviders',true).MouseButton1Click:Fire()
Settings.setActiveProvider(profile.id)
providerView:FindFirstChild('Profile_'..added.id,true).MouseButton1Click:Fire()
check('editing a saved profile leaves the active provider unchanged',Settings.getValue('activeProviderId')==profile.id)
local previousContext=module('AI/ContextManager').getSnapshot().contextWindow
local contextInput=inputFor('Context Window');contextInput.Text='6000';contextInput.FocusLost:Fire(false)
check('editing an inactive profile does not change active chat limits',module('AI/ContextManager').getSnapshot().contextWindow==previousContext)
local staleModels=false
for _,child in modelList:GetChildren() do if child.Name:find('Field_Availablemodels',1,true) then staleModels=true end end
check('opening a profile clears prior model results',not staleModels)
credentials.set(added.id,'another-offline-fixture')
chooseMenu(providerView:FindFirstChild('ProfileActions',true),'Disconnect key')
check('disconnecting an inactive profile preserves active chat',Settings.getValue('activeProviderId')==profile.id and not credentials.has(added.id))
chooseMenu(providerView:FindFirstChild('ProfileActions',true),'Use for chat')
check('use for chat explicitly activates the edited profile',Settings.getValue('activeProviderId')==added.id)
providerView:FindFirstChild('Tab_Tests',true).MouseButton1Click:Fire()
local inspector=module('AI/CapabilityInspector');local originalProbe=inspector.probe;local probeRuns=0
inspector.probe=function(p) probeRuns+=1;return inspector.buildReport(p) end
providerView:FindFirstChild('Probe',true).MouseButton1Click:Fire()
advance(.02)
check('capability row invokes a real callable handler',probeRuns==1 and connectionButton.Interactable)
inspector.probe=originalProbe
-- Capture every page at several sizes. Scroll content may extend vertically,
-- but all controls must remain reachable inside their own scroll viewport.
for _,tab in {'Connection','Model','Advanced','Tests'} do
 providerView:FindFirstChild('Tab_'..tab,true).MouseButton1Click:Fire()
 for _,width in {300,320,440,760} do
  for _,height in {400,560,740} do
   compute(width,height)
   local editorRect=rect(providerEditor)
   local page=providerEditor:FindFirstChild(tab..'Page')
   local pageRect=rect(page)
   local footerRect=rect(providerView:FindFirstChild('ProviderFooter',true))
   check(string.format('provider editor %s %dx%d',tab,width,height),pageRect and pageRect.h>=24 and footerRect and footerRect.y>=pageRect.y+pageRect.h and footerRect.y+footerRect.h<=editorRect.y+editorRect.h+1 and allInside(providerView:FindFirstChild('FooterActions',true)))
  end
 end
end
providerView:FindFirstChild('Tab_Connection',true).MouseButton1Click:Fire()
chooseMenu(providerView:FindFirstChild('Field_Authentication',true),'Authorization: Bearer KEY')
compute(300,740)
local dropdownButton=views.SettingsView:FindFirstChild('SettingsSectionPicker',true):FindFirstChild('Dropdown',true)
local dropdownRect=rect(dropdownButton)
local chevronRect=rect(dropdownButton:FindFirstChild('ChevronDownIcon'))
check('settings picker chevron fits within the button',chevronRect.x>=dropdownRect.x and chevronRect.x+chevronRect.w<=dropdownRect.x+dropdownRect.w)
for _,width in {300,440,760} do
 compute(width,740)
 snapshot={name='provider-connection',width=width,height=740,items={}}
 export(gui:FindFirstChild('Root'),true,nil)
 print('MENU_SNAPSHOT '..jsonEncode(snapshot))
end
Settings.setActiveProvider(profile.id)
credentials.set(added.id,'removed-offline-fixture')
chooseMenu(providerView:FindFirstChild('ProfileActions',true),'Remove profile')
check('remove forgets the key and returns to the list',Settings.getProvider(added.id)==nil and not credentials.has(added.id) and providerOverview.Visible and Settings.getValue('activeProviderId')==profile.id)
for _,width in {300,440,760} do
 compute(width,740)
 snapshot={name='provider-overview',width=width,height=740,items={}}
 export(gui:FindFirstChild('Root'),true,nil)
 print('MENU_SNAPSHOT '..jsonEncode(snapshot))
end
search.Text='['
check('provider search treats punctuation literally',providerView:FindFirstChild('AddPreset_openrouter',true)==nil)
search.Text=''
for _,width in {300,760} do
 compute(width,560)
 local sidebar=views.SettingsView:FindFirstChild('SettingsNavigation')
 local picker=views.SettingsView:FindFirstChild('SettingsSectionPicker')
 check('settings responsive navigation '..width,if width<620 then picker.Visible and not sidebar.Visible else sidebar.Visible and not picker.Visible)
end
compute(300,560)
chooseMenu(views.SettingsView:FindFirstChild('SettingsSectionPicker'),'Agent')
check('compact settings picker navigates to the requested page',apis.SettingsView.getSection()=='Agent' and views.SettingsView:FindFirstChild('SettingsSectionPicker'):FindFirstChild('Dropdown',true).Text=='Agent')
EventBus.emit(EventBus.Events.Navigate,{section='settings',tab='AI & Provider'})
check('returning to provider settings keeps the overview usable',providerOverview.Visible)

-- Custom presets must open before the user supplies a URL or REST mapping.
local manager=module('AI/CustomProviderManager')
local originalActive=Settings.getValue('activeProviderId')
local toastMessages={}
local unsubscribeDraftToasts=EventBus.on(EventBus.Events.Toast,function(p) toastMessages[#toastMessages+1]=p.message or '' end)
providerView:FindFirstChild('ProviderSearch',true).Text='custom'
for _,presetId in {'custom','rest'} do
 local beforeRequests=requestCount
 local beforeToasts=#toastMessages
 providerView:FindFirstChild('AddPreset_'..presetId,true).MouseButton1Click:Fire()
 local saved=Settings.getValue('providers')[#Settings.getValue('providers')]
 check('blank '..presetId..' preset opens its editor',providerEditor.Visible and not providerOverview.Visible and saved.presetId==presetId and saved.baseUrl=='')
 check('opening '..presetId..' does not send requests or replace active chat',requestCount==beforeRequests and Settings.getValue('activeProviderId')==originalActive)
 check('opening '..presetId..' has no premature URL error',#toastMessages==beforeToasts)
 local customModel=inputFor('Model ID')
 customModel.Text='agnes-3.0-flash';customModel.FocusLost:Fire(false)
 check('typing a model before '..presetId..' URL preserves the draft',Settings.getProvider(saved.id).modelId=='agnes-3.0-flash' and #toastMessages==beforeToasts)
 providerView:FindFirstChild('Savechanges',true).MouseButton1Click:Fire()
 check('explicit save still validates empty '..presetId..' URL',not manager.validate(Settings.getProvider(saved.id)).ok and #toastMessages>beforeToasts and requestCount==beforeRequests)
 chooseMenu(providerView:FindFirstChild('ProfileActions',true),'Use for chat')
 check('incomplete '..presetId..' draft cannot replace active chat',Settings.getValue('activeProviderId')==originalActive)
 local customUrl=inputFor('Base URL')
 customUrl.Text='https://fixture.invalid/v1';customUrl.FocusLost:Fire(false)
 check('typed '..presetId..' URL is retained',Settings.getProvider(saved.id).baseUrl=='https://fixture.invalid/v1')
 if presetId=='rest' then
  providerView:FindFirstChild('Tab_Advanced',true).MouseButton1Click:Fire()
  local path=inputFor('Endpoint Path');path.Text='/generate';path.FocusLost:Fire(false)
  providerView:FindFirstChild('RequestSchema',true).Text='{"prompt":"input.text","model":"input.model"}'
  providerView:FindFirstChild('ResponseSchema',true).Text='{"text":"output.answer"}'
  providerView:FindFirstChild('Applyschemamapping',true).MouseButton1Click:Fire()
  check('REST draft becomes valid after URL path and mappings',manager.validate(Settings.getProvider(saved.id)).ok and Settings.getProvider(saved.id).endpointPathCustom==true,jsonEncode({saved=Settings.getProvider(saved.id),validation=manager.validate(Settings.getProvider(saved.id))}))
 else
  check('compatible draft becomes valid after entering URL',manager.validate(Settings.getProvider(saved.id)).ok)
 end
 chooseMenu(providerView:FindFirstChild('ProfileActions',true),'Remove profile')
end
unsubscribeDraftToasts()

-- A provider that never answers must not keep the settings locked.
providerView:FindFirstChild('Profile_'..profile.id,true).MouseButton1Click:Fire()
local lockedModel=inputFor('Model ID')
local readyUrl=inputFor('Base URL');readyUrl.Text='https://fixture.invalid/v1';readyUrl.FocusLost:Fire(false)
local realTest=providerService.testConnection
local attempts=0
local limitsApplied=false
providerService.testConnection=function(p,_,opts)
 attempts+=1
 limitsApplied=p.timeoutMs<=15000 and p.retryOverrides.enabled==false and type(opts.shouldCancel)=='function'
 taskMock.wait(1000)
 return {ok=true,latencyMs=1,message='Late result',endpoint='https://fixture.invalid/v1'}
end
connectionButton.MouseButton1Click:Fire()
check('tests expose Stop before work starts',connectionButton.Text=='Stop test' and connectionButton.Interactable and not lockedModel.TextEditable and attempts==0,jsonEncode({button=connectionButton.Text,enabled=connectionButton.Interactable,editable=lockedModel.TextEditable,attempts=attempts,active=Settings.getProvider(profile.id),lastToast=toastMessages[#toastMessages]}))
advance(.02)
check('diagnostics use bounded requests and one attempt',attempts==1 and limitsApplied)
connectionButton.MouseButton1Click:Fire()
advance(1.1)
check('Stop releases controls even when a test ignores cancellation',lockedModel.TextEditable and connectionButton.Text=='Test connection' and testResult.Text=='Provider test stopped.')
local stoppedResult=testResult.Text
advance(2)
check('late cancelled work cannot overwrite the status',testResult.Text==stoppedResult)
connectionButton.MouseButton1Click:Fire()
advance(61.2)
check('whole test deadline restores controls',connectionButton.Interactable and lockedModel.TextEditable and testResult.Text:find('60 seconds',1,true)~=nil)
providerService.testConnection=realTest

local realStream=providerService.stream
local streamCancelled=false
providerService.stream=function(_,_,_,callbacks)
 while not callbacks.shouldCancel() do taskMock.wait(.1) end
 streamCancelled=true
end
providerView:FindFirstChild('Tab_Tests',true).MouseButton1Click:Fire()
providerView:FindFirstChild('Teststreaming',true).MouseButton1Click:Fire()
advance(.02)
connectionButton.MouseButton1Click:Fire()
advance(.2)
check('Stop reaches streaming cleanup and restores controls',streamCancelled and lockedModel.TextEditable and testResult.Text=='Provider test stopped.')
providerService.stream=realStream

-- Exercise the actual HTTP timeout/cancellation path with a stalled engine call.
local http=module('Utilities/UniversalHTTPClient')
local realRequest=methods.RequestAsync
local capturedRequest=nil
methods.RequestAsync=function(_,request)
 capturedRequest=request
 taskMock.wait(1000)
 return {StatusCode=200,Headers={},Body='{}'}
end
local timeoutResult=nil
local heartbeat=false
local startedAt=now
taskMock.spawn(function() timeoutResult=http.get('https://fixture.invalid/v1',nil,{timeoutMs=1000}) end)
taskMock.delay(.2,function() heartbeat=true end)
advance(.3)
check('a stalled HTTP request yields to other scheduled work',heartbeat and timeoutResult==nil)
advance(1)
check('caller timeout returns without waiting for the engine',timeoutResult and not timeoutResult.ok and timeoutResult.transportError=='Request timed out.' and now-startedAt<2)
check('native HTTP timeout is an integer in seconds',capturedRequest.Timeout==1)
local cancel=false
local cancelledResult=nil
taskMock.spawn(function() cancelledResult=http.get('https://fixture.invalid/v1',nil,{timeoutMs=10000,shouldCancel=function() return cancel end}) end)
advance(.2);cancel=true;advance(.1)
check('HTTP caller cancellation returns promptly',cancelledResult and not cancelledResult.ok and cancelledResult.transportError=='Cancelled.')
methods.RequestAsync=realRequest
providerView:FindFirstChild('BackToProviders',true).MouseButton1Click:Fire()

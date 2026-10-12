-- Actual chat widgets and manager callbacks, not a duplicate implementation.
do
(function()
 local Questions=module('AI/QuestionManager')
 local savedAlways=Settings.getValue('alwaysApproveActions')
 local savedConfirm=Settings.getValue('confirmToolCalls')
 local function openQuestion(kind,options,custom)
  State.reset();State.transition('THINKING',{force=true})
  local answer=nil;local returned=false
  taskMock.spawn(function()
   answer=Questions.ask({taskId='question-ui-regression',kind=kind,prompt='Choose the project option.',options=options,allowCustom=custom,allowAiDecide=false})
   returned=true
  end)
  local pending=Questions.getPending()
  local card=views.ChatView:FindFirstChild('Question_'..pending.id,true)
  assert(card,'Actual QuestionAsked widget missing')
  local toggle=card:FindFirstChild('Toggle',true)
  if toggle then toggle.MouseButton1Click:Fire()end
  return card,function()return answer,returned end
 end
 local card,answer=openQuestion('single',{{id='traffic',label='Allow traffic scripts'},{id='static',label='Static geometry'}},true)
 card:FindFirstChild('Option_traffic',true).MouseButton1Click:Fire()
 card:FindFirstChild('Submitanswer',true).MouseButton1Click:Fire();advance(.25)
 check('selected single question option reaches the waiting agent',answer()=='Allow traffic scripts')
 check('answered question auto collapses and keeps a reopen control',card:FindFirstChild('Toggle',true)~=nil and card:FindFirstChild('Content',true).Visible==false)
 if Questions.getPending() then Questions.cancel('Fixture cleanup');advance(.25)end
 if card.Parent then card:Destroy()end
 card,answer=openQuestion('single',{{id='small',label='Small map'}},true)
 card:FindFirstChild('CustomToggle',true).MouseButton1Click:Fire()
 card:FindFirstChild('CustomInput',true).Text='  A detailed city district  '
 card:FindFirstChild('Submitanswer',true).MouseButton1Click:Fire();advance(.25)
 check('custom single answer is validated once and returns its actual text',answer()=='A detailed city district')
 if Questions.getPending() then Questions.cancel('Fixture cleanup');advance(.25)end
 if card.Parent then card:Destroy()end
 card,answer=openQuestion('multiple',{{id='a',label='Park'},{id='b',label='Road'}},true)
 card:FindFirstChild('CustomToggle',true).MouseButton1Click:Fire();card:FindFirstChild('CustomInput',true).Text='Station and market'
 card:FindFirstChild('Submitanswer',true).MouseButton1Click:Fire();advance(.25)
 local multiple=answer()
 check('custom multiple answer reaches the waiting agent',type(multiple)=='table' and multiple[1]=='Station and market')
 if Questions.getPending() then Questions.cancel('Fixture cleanup');advance(.25)end
 if card.Parent then card:Destroy()end

 card,answer=openQuestion('single',{{id='a',label='First choice'},{id='b',label='Second choice'}},false)
 card:FindFirstChild('Submitanswer',true).MouseButton1Click:Fire()
 check('empty required question stays editable instead of locking',Questions.getPending() and not Questions.getPending().answered and card:FindFirstChild('Submitanswer',true).Interactable)
 card:FindFirstChild('Option_a',true).MouseButton1Click:Fire();card:FindFirstChild('Option_b',true).MouseButton1Click:Fire()
 card:FindFirstChild('Submitanswer',true).MouseButton1Click:Fire();advance(.25)
 check('single selection stores the last chosen option',answer()=='Second choice' and card:FindFirstChild('ValidationHint',true)==nil)
 card:FindFirstChild('Toggle',true).MouseButton1Click:Fire()
 check('answered question can reopen as a bounded read-only result',card:FindFirstChild('Content',true).Visible and card:FindFirstChild('Content',true).Size.Y.Offset<=260 and not card:FindFirstChild('Submitanswer',true).Interactable)
 card:FindFirstChild('Close',true).MouseButton1Click:Fire()
 check('question Close removes the expanded height',not card:FindFirstChild('Content',true).Visible)
 card:Destroy()

 card,answer=openQuestion('multiple',{{id='a',label='Park'},{id='b',label='Road'}},false)
 card:FindFirstChild('Option_b',true).MouseButton1Click:Fire();card:FindFirstChild('Option_a',true).MouseButton1Click:Fire()
 card:FindFirstChild('Submitanswer',true).MouseButton1Click:Fire();advance(.25)
 local chosen=answer()
 check('multiple choices return IDs in visible option order',type(chosen)=='table' and chosen[1]=='a' and chosen[2]=='b')
 card:Destroy()
 for _,entry in {{kind='text',text='User supplied plan',expected='User supplied plan'},{kind='number',text='0',expected=0},{kind='boolean',button='No',expected=false},{kind='confirm',button='Yes',expected=true}}do
  card,answer=openQuestion(entry.kind,nil,false)
  if entry.button then card:FindFirstChild(entry.button,true).MouseButton1Click:Fire()
  else card:FindFirstChild('Input',true).Text=entry.text;card:FindFirstChild('Submitanswer',true).MouseButton1Click:Fire()end
  advance(.25)
  local value,returned=answer()
  check('question '..entry.kind..' returns false zero and text correctly',returned and value==entry.expected)
  card:Destroy()
 end
 card,answer=openQuestion('single',{{id='a',label='Correct question'}},false)
 check('stale card IDs cannot answer a new question',Questions.submit('a','previous-question')==false and not Questions.getPending().answered)
 card:FindFirstChild('Option_a',true).MouseButton1Click:Fire();card:FindFirstChild('Submitanswer',true).MouseButton1Click:Fire();advance(.25)
 check('current question survives a stale submission',answer()=='Correct question')
 card:Destroy()

 State.reset()
 local received={}
 local frame,input=module('UI/ChatInput').build({onSend=function(value)received[#received+1]=value;return true end,onStop=function()end,onPickFiles=function()end,onOpenSettings=function()end,onModeChange=function()end})
 frame.Parent=content;local box=frame:FindFirstChild('Input')
 local shifted=newInstance('InputObject');shifted.KeyCode=EnumMock.KeyCode.Return;shifted._shift=true
 input.setText('firstsecond');input.focus();box.CursorPosition=6
 -- A docked TextBox may deliver only native FocusLost, without Shift key events.
 local selectedShift=newInstance('InputObject');selectedShift.KeyCode=EnumMock.KeyCode.Return;selectedShift._shift=true
 box.FocusLost:Fire(true,selectedShift);advance(.02)
 check('native Shift Enter modifier inserts a paragraph instead of sending',#received==0 and input.getText()=='first\nsecond' and box:IsFocused())
 input.setText('keep selected end');input.focus();box.CursorPosition=6;box.SelectionStart=14
 box.FocusLost:Fire(true,shifted);advance(.02)
 check('native Shift Enter replaces a selection and preserves the caret',#received==0 and input.getText()=='keep \n end' and box.CursorPosition==7 and box.SelectionStart==-1)
 input.setText('line one\nline two');input.focus();local plain=newInstance('InputObject');plain.KeyCode=EnumMock.KeyCode.Return
 box.InputBegan:Fire(plain);gui.InputBegan:Fire(plain);box.FocusLost:Fire(true,plain);advance(.02)
 check('plain native Enter sends a multiline chat exactly once',#received==1 and received[1]=='line one\nline two' and input.getText()=='')
 input.setText('busy paragraph');input.setBusy(true);input.focus();box.CursorPosition=#box.Text+1
 local busyShift=newInstance('InputObject');busyShift.KeyCode=EnumMock.KeyCode.Return;busyShift._shift=true
 box.FocusLost:Fire(true,busyShift);advance(.02)
 check('Shift Enter edits the draft while a task is running',#received==1 and input.getText()=='busy paragraph\n')
 input.setBusy(false);input.setText('keep selected end');input.focus();box.CursorPosition=6;box.SelectionStart=14
 box._focused=false;box.CursorPosition=-1;box.SelectionStart=-1
 local lostShift=newInstance('InputObject');lostShift.KeyCode=EnumMock.KeyCode.Return;lostShift._shift=true
 box.FocusLost:Fire(true,lostShift);advance(.02)
 check('native focus loss preserves the selection before cursor reset',input.getText()=='keep \n end' and box.CursorPosition==7 and #received==1)
 input.setText('one return');input.focus();box.CursorPosition=#box.Text+1
 local duplicateShift=newInstance('InputObject');duplicateShift.KeyCode=EnumMock.KeyCode.Return;duplicateShift._shift=true
 box.InputBegan:Fire(duplicateShift);advance(.02);box.FocusLost:Fire(true,duplicateShift);advance(.02)
 check('late duplicate native Shift Enter inserts only one newline',input.getText()=='one return\n' and #received==1)
 input.destroy();frame:Destroy()

 State.reset();State.transition('THINKING',{force=true});Settings.setValue('confirmToolCalls',true)
 local approved=nil
 taskMock.spawn(function()approved=Agent.awaitApproval('create_model',{name='Approval fixture'},'approval-regression')end)
 local always=views.ChatView:FindFirstChild('AlwaysApprove',true)
 check('approval presents Always Approve as the third choice',always~=nil)
 if always then
  for name,view in views do view.Visible=name=='ChatView'end
  for _,width in {300,440,760}do
   compute(width,740)
   check('all three approval buttons remain reachable at width '..width,allInside(always.Parent))
  end
 end
 if always then always.MouseButton1Click:Fire()else Agent.resolveApproval(false)end
 advance(.2)
 check('Always Approve grants current action and remembers the preference',approved==true and Settings.getValue('alwaysApproveActions')==true)
 check('remembered approval covers later consequential actions',Agent.requestApproval('delete_instance',{path='Workspace.Fixture'},'next-action'))
 local permissions=Settings.getValue('toolPermissions');local previousPermission=permissions.create_model;permissions.create_model=false
 check('Always Approve respects disabled tool permissions',not Agent.requestApproval('create_model',{},'blocked-action'))
 permissions.create_model=previousPermission
 local forbidden=Agent.executeTool('create_model',{name='ForbiddenInPlan',parent='Workspace'},'plan','plan-gate')
 check('Always Approve retains Plan mode write restrictions',not forbidden.ok and workspaceMock:FindFirstChild('ForbiddenInPlan')==nil)
 check('Always Approve cannot grant unknown tools',not Agent.requestApproval('missing-tool',{},'unknown-action'))
 local preference=views.SettingsView:FindFirstChild('AlwaysApproveActions',true)
 check('Settings exposes a reversible Always Approve preference',preference~=nil)
 if preference then preference:FindFirstChild('Hit',true).MouseButton1Click:Fire()end
 check('Settings toggle stays synchronized with the approval button',Settings.getValue('alwaysApproveActions')==false)
 State.reset();State.transition('THINKING',{force=true});approved=nil
 taskMock.spawn(function()approved=Agent.awaitApproval('create_model',{name='Decline fixture'},'decline-regression')end)
 views.ChatView:FindFirstChild('Decline',true).MouseButton1Click:Fire();advance(.2)
 check('Decline still rejects an action without enabling Always Approve',approved==false and not Settings.getValue('alwaysApproveActions'))
 Settings.setValue('alwaysApproveActions',true);Settings.init(pluginMock)
 check('Always Approve persists across a settings reload',Settings.getValue('alwaysApproveActions')==true)
 Settings.setValue('alwaysApproveActions',false)

 State.reset()
 local retry,retryAPI=module('UI/RetryStatusUI').build({operationId='collapse-provider-fixture',providerName='Fixture',model='fixture',category='RATE_LIMITED',reason='Temporary limit',maxRetries=5,attempt=1,delaySeconds=4,paused=false})
 retry.Parent=content
 local toggle=retry:FindFirstChild('Toggle',true)
 check('provider limit includes a whole-card disclosure control',toggle~=nil and retry:FindFirstChild('Close',true)~=nil)
 check('provider limit starts compact while its countdown remains visible',not retryAPI.isExpanded() and retry:FindFirstChild('Preview',true).Visible and retry:FindFirstChild('Preview',true).Text:find('Next Attempt',1,true)~=nil)
 if toggle then toggle.MouseButton1Click:Fire()end
 check('provider limit expands within a bounded viewport',retryAPI.isExpanded() and retry:FindFirstChild('Content',true).Size.Y.Offset<=260)
 retry:FindFirstChild('Close',true).MouseButton1Click:Fire();local before=retry:FindFirstChild('Preview',true).Text;advance(.5)
 check('collapsed provider limit continues its real countdown',not retryAPI.isExpanded() and retry:FindFirstChild('Preview',true).Text~=before)
 retryAPI.setExpanded(true);EventBus.emit('retry:state',{operationId='collapse-provider-fixture',state='PROVIDER_RECOVERED'})
 check('provider recovery collapses automatically and disables retry actions',not retryAPI.isExpanded() and not retry:FindFirstChild('CancelRetry',true).Interactable)
 retryAPI.destroy()

 local questionLayout,questionLayoutAPI=module('UI/QuestionCard').build({id='question-layout-fixture',kind='single',prompt='Choose a size for the city.',options={{id='a',label='Small district'},{id='b',label='Large city'}},required=true,allowCustom=true,allowAiDecide=true})
 questionLayout.Parent=views.ChatView:FindFirstChild('QuestionCards',true);questionLayoutAPI.setExpanded(true)
 for _,width in {300,440,760}do
  compute(width,740)
  check('question action buttons remain reachable at width '..width,allInside(questionLayout:FindFirstChild('Actions',true)))
 end
 questionLayout:Destroy()

 -- Counts and round budgets must not stop either execution protocol.
 local Registry=module('AI/UniversalProviderRegistry');local Detector=module('AI/ModelCapabilityDetector')
 local fixture=Registry.newProfile('custom');fixture.modelId='uncapped-fixture';fixture.baseUrl='https://fixture.invalid/v1';fixture.authStyle='none';fixture.toolCalling=true
 local savedActive=Settings.getValue('activeProviderId');local savedConversation=Sessions.getActive()
 local savedSend=Agent.sendTurn;local savedExecute=Agent.executeTool
 Settings.addProvider(fixture);Settings.setActiveProvider(fixture.id);Detector.setOverride(fixture.id,fixture.modelId,'tool_calling','supported')
 local executed=0;local turns=0
 Agent.executeTool=function(name,arguments)
  executed+=1
  return {toolName=name,arguments=arguments,ok=true,verified=true,message='Fixture action completed',durationMs=1}
 end
 Agent.sendTurn=function()
  turns+=1
  return {text=if turns>64 then 'All rounds completed.' else '',toolCalls=if turns>64 then {} else {{id='uncapped-'..turns,name='inspect_place',arguments={}}},cancelled=false,durationMs=1}
 end
 local conversation=Sessions.createConversation({mode='build'});Sessions.addMessage('user','Complete the long tool fixture.')
 State.reset();local result=runAgentTask({mode='build',conversation=conversation})
 check('native agent continues beyond the old tool and derived round limits',result.ok and turns==65 and executed==64 and not State.isBusy())
 executed=0;turns=0
 Agent.sendTurn=function()
  turns+=1;local calls={}
  if turns==1 then for i=1,210 do calls[#calls+1]={id='build-'..i,name='create_model',arguments={name='Fixture '..i}}end end
  return {text=if turns>1 then 'All build actions completed.' else '',toolCalls=calls,cancelled=false,durationMs=1}
 end
 conversation=Sessions.createConversation({mode='build'});Sessions.addMessage('user','Complete the large build fixture.')
 State.reset();result=runAgentTask({mode='build',conversation=conversation})
 check('native build executes more than the old 200 action default',result.ok and executed==210 and turns==2 and not State.isBusy())
 fixture.toolCalling=false;Settings.updateProvider(fixture.id,{toolCalling=false});executed=0;turns=0
 Agent.sendTurn=function()
  turns+=1
  return {text=if turns<=55 then '```json\n'..jsonEncode({action='create_model',arguments={name='Structured '..turns,parent='Workspace'}})..'\n```' else 'Structured task completed.',toolCalls={},cancelled=false,durationMs=1}
 end
 conversation=Sessions.createConversation({mode='build'});Sessions.addMessage('user','Complete the structured build fixture.')
 State.reset();result=runAgentTask({mode='build',conversation=conversation})
 check('structured agent is uncapped across more than forty actions',result.ok and turns==56 and executed==55)
 Settings.updateProvider(fixture.id,{toolCalling=true});executed=0;turns=0
 Agent.sendTurn=function()
  turns+=1
  return {text='',toolCalls={{id='stop-'..turns,name='create_model',arguments={name='Cancellable '..turns}}},cancelled=false,durationMs=1}
 end
 conversation=Sessions.createConversation({mode='build'});State.reset();apis.ChatView.input.setText('Run the cancellable tool fixture.')
 views.ChatView:FindFirstChild('Send',true).MouseButton1Click:Fire();advance(.2)
 local stoppedAt=executed
 views.ChatView:FindFirstChild('Stop',true).MouseButton1Click:Fire();advance(.3)
 check('Stop remains responsive during an uncapped tool task',stoppedAt>0 and executed==stoppedAt and State.get()=='CANCELLED' and not State.isBusy() and views.ChatView:FindFirstChild('Send',true)~=nil)
 check('removed count limits are absent from defaults and settings controls',Settings.getValue('maxToolCalls')==nil and Settings.getValue('maxBuildActions')==nil and views.SettingsView:FindFirstChild('Field_Maximumtoolcallspertask',true)==nil and views.SettingsView:FindFirstChild('Field_Maximumbuildactionspertask',true)==nil)
 Agent.sendTurn=savedSend;Agent.executeTool=savedExecute;Detector.clearOverrides(fixture.id,fixture.modelId)
 Settings.removeProvider(fixture.id);Settings.setActiveProvider(savedActive)
 if savedConversation then Sessions.setActive(savedConversation.id)end
 Settings.setValue('alwaysApproveActions',savedAlways);Settings.setValue('confirmToolCalls',savedConfirm);State.reset()
end)()
end

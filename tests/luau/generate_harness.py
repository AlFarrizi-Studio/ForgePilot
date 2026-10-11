import json,pathlib
base=pathlib.Path(__file__).resolve().parents[2]
root=base/'plugin'/'src';api=json.loads((base/'tests'/'luau'/'API-Signatures.json').read_text())
def literal(v):
 if v is None:return 'nil'
 if isinstance(v,bool):return str(v).lower()
 if isinstance(v,(int,float)):return str(v)
 if isinstance(v,str):
  eq='='*3
  while ']'+eq+']' in v:eq+='='
  return '['+eq+'['+v+']'+eq+']'
 if isinstance(v,list):return '{'+','.join(literal(x) for x in v)+'}'
 return '{'+','.join('[ '+literal(k)+' ]='+literal(x) for k,x in v.items())+'}'
classes={}
for c in api['Classes']:
 classes[c['Name']]={'super':c['Superclass'],'members':{m['Name']:m['MemberType'] for m in c['Members']}}
enums={e['Name']:{v['Name']:v['Value'] for v in e['Items']} for e in api['Enums']}
sources={str(p.relative_to(root)).removesuffix('.luau'):p.read_text() for p in root.rglob('*.luau')}
out=base/'tests'/'luau'/'runtime-harness.luau'
tests=(base/'tests'/'luau'/'runtime_tests.luau').read_text()
tests=tests.replace("local controller=module('Core/ApplicationController')",(base/'tests'/'luau'/'provider_menu_tests.luau').read_text()+"\nlocal controller=module('Core/ApplicationController')")
tests=tests.replace("local controller=module('Core/ApplicationController')",(base/'tests'/'luau'/'chat_regression_tests.luau').read_text()+"\nlocal controller=module('Core/ApplicationController')")
tests=tests.replace("local controller=module('Core/ApplicationController')",(base/'tests'/'luau'/'agent_access_tests.luau').read_text()+"\nlocal controller=module('Core/ApplicationController')")
tests=tests.replace("local controller=module('Core/ApplicationController')",(base/'tests'/'luau'/'timeout_regression_tests.luau').read_text()+"\nlocal controller=module('Core/ApplicationController')")
tests=tests.replace("local controller=module('Core/ApplicationController')",(base/'tests'/'luau'/'release_regression_tests.luau').read_text()+"\nlocal controller=module('Core/ApplicationController')")
out.write_text('local classes='+literal(classes)+'\nlocal enums='+literal(enums)+'\nlocal sources='+literal(sources)+'\n'+(base/'tests'/'luau'/'mock_engine.luau').read_text()+'\n'+tests)
print(out)

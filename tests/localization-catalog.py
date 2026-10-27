from pathlib import Path
from html.parser import HTMLParser
import re,json
root=Path(__file__).resolve().parents[1];catalog=json.loads((root/'resources/locales.json').read_text());keys=sorted(catalog,key=len,reverse=True);languages={'en','zh','ja','ko','es','de','ru'}
for key,values in catalog.items():
 assert set(values)==languages and all(isinstance(v,str) and v for v in values.values()),key
 source=re.findall(r'%(?:0?\d+)?(?:ll|l)?[udx@]',key)
 for language,value in values.items():assert re.findall(r'%(?:0?\d+)?(?:ll|l)?[udx@]',value)==source,(key,language)
assert (root/'resources/locales.js').read_text()=='window.flowLocales='+json.dumps(catalog,ensure_ascii=False,separators=(',',':'))+';\n'
texts=[]
class UI(HTMLParser):
 def handle_data(self,value):texts.append(value)
 def handle_starttag(self,tag,attrs):texts.extend(value for key,value in attrs if value and key in ['title','aria-label','placeholder'])
UI().feed((root/'resources/index.html').read_text())
for source in texts:
 if source.strip()=='Русский':continue # Autonym in the language picker stays unchanged.
 remaining=source
 for key in keys:remaining=remaining.replace(key,'')
 assert not re.search('[А-Яа-яЁё]',remaining),(source,remaining)
for filename in ['mac/Studio.m','mac/FlowFirmware.m','mac/FlowTransport.m','mac/FlowBLESerial.m','mac/FlowBLEBattery.m','mac/FlowMacroRecorder.m','resources/app.js','resources/macro-recorder.js','resources/session-keys.js']:
 source=(root/filename).read_text();pattern=r'@"((?:[^"\\]|\\.)*)"' if filename.endswith('.m') else r"'((?:[^'\\\n]|\\.)*)'"
 for match in re.finditer(pattern,source):
  text=match[1].replace(r'\n','\n')
  if '<' in text and '</' in text:continue
  remaining=text
  for key in keys:remaining=remaining.replace(key,'')
  assert not re.search('[А-Яа-яЁё]',remaining),(filename,text,remaining)
# Protocol connection values must remain canonical, independent of displayed language.
assert 'isEqual:@"2.4 ГГц"' in (root/'mac/Studio.m').read_text()
print(json.dumps({'status':'passed','languages':sorted(languages),'entries':len(catalog),'tests':['Static text and accessibility attributes covered','App and native error messages covered','All seven dictionaries complete','Format placeholders match in type/order/count','JS and native JSON catalogs identical','Canonical RF transport value preserved'],'native_macos_build_tested':False},indent=2))

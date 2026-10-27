from pathlib import Path
import json
root=Path(__file__).resolve().parents[1];languages=['en','zh','ja','ko','es','de'];rows={}
for path in sorted(Path(__file__).parent.glob('*.tsv')):
 for i,line in enumerate(path.read_text().splitlines(),1):
  if not line.strip() or line.startswith('#'):continue
  parts=line.split('|');assert len(parts) in [7,8],(path.name,i,len(parts));parts=[part.replace(r'\n','\n') for part in parts];source=parts[0];assert source and all(parts[1:]),(path,i)
  values=dict(zip(languages,parts[1:7]));values['ru']=parts[7] if len(parts)==8 else source
  assert source not in rows or rows[source]==values,source;rows[source]=values
for n in [5,10,15,20,25,30,40,50,75,100]:
 rows[f'{n}% и ниже']=dict(en=f'{n}% or below',zh=f'{n}% 及以下',ja=f'{n}% 以下',ko=f'{n}% 이하',es=f'{n}% o menos',de=f'{n}% oder weniger',ru=f'{n}% и ниже')
# Format placeholders must preserve type, order and count in every translation.
import re
for key,translations in rows.items():
 expected=re.findall(r'%(?:0?\d+)?(?:ll|l)?[udx@]',key)
 for language,value in translations.items():assert re.findall(r'%(?:0?\d+)?(?:ll|l)?[udx@]',value)==expected,(key,language)
raw=json.dumps(rows,ensure_ascii=False,separators=(',',':'))
(root/'resources/locales.json').write_text(raw+'\n');(root/'resources/locales.js').write_text('window.flowLocales='+raw+';\n')
print(len(rows),'translation entries; seven languages')

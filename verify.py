"""Small end-to-end PD checks, recording P/D metrics and raw responses."""
import argparse,json,time,urllib.request,urllib.error,pathlib,re,hashlib
p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--long',action='store_true');a=p.parse_args()
r=pathlib.Path(a.root);r.mkdir(parents=True,exist_ok=False)
urls={'prefill':'http://10.9.243.230:8100','decode':'http://10.8.174.126:8200','router':'http://10.9.243.230:8300'}
def get(url,body=None,timeout=30):
 q=urllib.request.Request(url,data=None if body is None else json.dumps(body,ensure_ascii=False).encode(),headers={'Content-Type':'application/json'})
 with urllib.request.urlopen(q,timeout=timeout) as f:return f.read()
def snap(label):
 for role in ['prefill','decode']:(r/f'{role}.{label}.prom').write_bytes(get(urls[role]+'/metrics'))
def numeric(s):
 vals={}
 for line in s.splitlines():
  if line.startswith('#') or not line.strip():continue
  key,value=line.rsplit(' ',1)
  try:vals[key]=float(value)
  except ValueError:pass
 return vals
cases=[('arithmetic','计算17+25，只输出数字结果。','42','low',False,256),('stream','计算3乘以7，只输出数字结果。','21','low',True,256),('thinking','计算12乘以13，给出答案。','156','max',False,512)]
if a.long:
 from transformers import AutoTokenizer
 tokenizer=AutoTokenizer.from_pretrained('/workspace/volume/data/GLM-5.3-BF16-W4A8',trust_remote_code=True)
 def message(n):return ('这是一段用于验证长上下文传输的占位资料。\n'*n)+'\n本次校验口令：青松7319。请只输出校验口令。'
 def count_tokens(prompt):
  text=tokenizer.apply_chat_template([{'role':'user','content':prompt}],tokenize=False,add_generation_prompt=True,reasoning_effort='low',clear_thinking=True)
  return len(tokenizer.encode(text,add_special_tokens=False))
 lo,hi=1,50000
 while lo<hi:
  mid=(lo+hi+1)//2
  count=count_tokens(message(mid))
  if count<=258000:lo=mid
  else:hi=mid-1
 prompt=message(lo)
 tokens=count_tokens(prompt)
 assert 256000<tokens<=258000, f'Unexpected long prompt size: {tokens}'
 (r/'long_input.json').write_text(json.dumps({'tokens':tokens,'sha256':hashlib.sha256(prompt.encode()).hexdigest()}))
 cases=[('long258k',prompt,'青松7319','low',False,128)]
results=[]
try:
 for name,prompt,expected,effort,stream,limit in cases:
  snap(name+'.before')
  body={'model':'glm-5.3','messages':[{'role':'user','content':prompt}],'temperature':0,'max_tokens':limit,'stream':stream,'chat_template_kwargs':{'reasoning_effort':effort,'clear_thinking':True}}
  # Router v0.1.15 only accepts low/medium/high at the top level.
  # GLM-specific max is passed through the template kwargs alone.
  if effort!='max':body['reasoning_effort']=effort
  if stream:body['stream_options']={'include_usage':True}
  (r/(name+'.request.json')).write_text(json.dumps(body,ensure_ascii=False))
  t=time.monotonic()
  try:raw=get(urls['router']+'/v1/chat/completions',body,1800)
  except urllib.error.HTTPError as exc:
   (r/(name+'.error.body')).write_bytes(exc.read())
   raise
  seconds=time.monotonic()-t
  (r/(name+'.response.txt')).write_bytes(raw)
  if stream:
   events=[json.loads(x[6:]) for x in raw.decode().splitlines() if x.startswith('data: ') and x[6:]!='[DONE]']
   choices=[c for e in events for c in e.get('choices',[])];content=''.join(c.get('delta',{}).get('content') or '' for c in choices);reasoning=''.join(c.get('delta',{}).get('reasoning') or '' for c in choices)
   finish=next((c['finish_reason'] for c in reversed(choices) if c.get('finish_reason')),None);usage=next((e['usage'] for e in reversed(events) if e.get('usage')),None)
   assert b'data: [DONE]' in raw
  else:
   answer=json.loads(raw);c=answer['choices'][0];content=c['message'].get('content') or '';reasoning=c['message'].get('reasoning') or '';finish=c['finish_reason'];usage=answer.get('usage')
  time.sleep(12);snap(name+'.after')
  deltas={}
  for role in ['prefill','decode']:
   before=numeric((r/f'{role}.{name}.before.prom').read_text());after=numeric((r/f'{role}.{name}.after.prom').read_text())
   deltas[role]={k:v-before.get(k,0) for k,v in after.items() if any(term in k for term in ('nixl','kv_load','prompt_tokens','kv_transfer','external_prefix')) and '_bucket' not in k and '_created' not in k}
  transferred=sum(v for k,v in deltas['decode'].items() if k.startswith('vllm:nixl_bytes_transferred_sum'))
  external_tokens=sum(v for k,v in deltas['decode'].items() if k.startswith('vllm:prompt_tokens_by_source_total') and 'source="external_kv_transfer"' in k)
  transfer_errors={role:{k:v for k,v in ds.items() if any(term in k for term in ('failed','failure','expired')) and v>0} for role,ds in deltas.items()}
  pd_ok=transferred>0 and external_tokens>0 and not any(transfer_errors.values())
  ok=(content.strip()==expected if name!='thinking' else expected in content and bool(reasoning)) and finish=='stop' and bool(usage and usage.get('completion_tokens',0)>0)
  if a.long:ok=ok and usage['prompt_tokens']==tokens
  row={'name':name,'passed':ok and pd_ok,'response_passed':ok,'pd_passed':pd_ok,'nixl_bytes':transferred,'external_tokens':external_tokens,'transfer_errors':transfer_errors,'seconds':seconds,'content':content,'reasoning_chars':len(reasoning),'finish_reason':finish,'usage':usage,'metric_deltas':deltas};results.append(row)
  print(json.dumps(row,ensure_ascii=False),flush=True)
except Exception as exc:
 (r/'error.json').write_text(json.dumps({'type':type(exc).__name__,'message':str(exc)},ensure_ascii=False,indent=2))
 raise
finally:
 (r/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
assert all(x['passed'] for x in results) and len(results)==len(cases)

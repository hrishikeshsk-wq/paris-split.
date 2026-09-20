const url = Deno.env.get('SUPABASE_URL')!;
const secret = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const headers = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'content-type, apikey, authorization','Access-Control-Allow-Methods':'GET, POST, OPTIONS','Content-Type':'application/json','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'};
const json=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers});
Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method==='GET')return json({version:'2.0.0',url,anonKey:Deno.env.get('SUPABASE_ANON_KEY')});
 if(req.method!=='POST')return json({error:'Method not allowed'},405);
 if(!req.headers.get('content-type')?.includes('application/json'))return json({error:'JSON required'},415);
 try{
  const reader=req.body?.getReader();if(!reader)return json({error:'Request body required'},400);
  const chunks:Uint8Array[]=[];let size=0;
  while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>32768){await reader.cancel();return json({error:'Request too large'},413);}chunks.push(value);}
  const bytes=new Uint8Array(size);let offset=0;for(const c of chunks){bytes.set(c,offset);offset+=c.length;}
  const payload=JSON.parse(new TextDecoder().decode(bytes));
  const result=await fetch(`${url}/rest/v1/rpc/paris_split_v2`,{method:'POST',headers:{'apikey':secret,'Authorization':`Bearer ${secret}`,'Content-Type':'application/json'},body:JSON.stringify({payload})});
  const data=await result.json();
  if(!result.ok){
   const safe=data.code==='P0001'?data.message:'Could not save this request. Check the values and try again.';
   return json({error:safe},400);
  }
  return json(data);
 }catch{return json({error:'Could not complete request. Retry with the same values.'},400);}
});

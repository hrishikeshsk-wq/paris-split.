export function cents(value){const n=Number(value);if(!Number.isFinite(n))throw Error('Invalid amount');return Math.round((n+Number.EPSILON)*100);}
// Largest remainder allocation conserves every cent; IDs break ties consistently.
export function allocate(total,rows){
 if(!Number.isSafeInteger(total)||total<0||!rows.length)throw Error('Invalid allocation');
 const ordered=[...rows].sort((a,b)=>a.id.localeCompare(b.id));
 const sum=ordered.reduce((n,r)=>n+Number(r.weight),0);
 if(!Number.isFinite(sum)||sum<=0||ordered.some(r=>!Number.isFinite(Number(r.weight))||Number(r.weight)<0))throw Error('Invalid shares');
 const values=ordered.map(r=>{const raw=total*Number(r.weight)/sum;return {...r,value:Math.floor(raw),fraction:raw-Math.floor(raw)};});
 let left=total-values.reduce((n,r)=>n+r.value,0);
 const priority=[...values].sort((a,b)=>b.fraction-a.fraction||a.id.localeCompare(b.id));
 for(let i=0;i<left;i++)priority[i%priority.length].value++;
 return Object.fromEntries(values.map(r=>[r.id,r.value]));
}
export function ledger(s){
 const balances=Object.fromEntries(s.members.map(m=>[m.id,0]));let total=0;
 for(const e of s.expenses){
  const amount=cents(Number(e.amount)*Number(e.exchange_rate_to_eur));total+=amount;
  const ps=s.payers.filter(p=>p.expense_id===e.id);
  const xs=s.splits.filter(p=>p.expense_id===e.id);
  const paid=allocate(amount,ps.map(p=>({id:p.member_id,weight:Number(p.amount)})));
  const owed=allocate(amount,xs.map(p=>({id:p.member_id,weight:e.split_method==='equal'?1:Number(p.value)})));
  for(const [id,v] of Object.entries(paid))balances[id]+=v;
  for(const [id,v] of Object.entries(owed))balances[id]-=v;
 }
 for(const p of s.settlements){balances[p.from_member_id]+=cents(p.amount_eur);balances[p.to_member_id]-=cents(p.amount_eur);}
 return {balances,total};
}
export function simplify(balances){
 const creditors=Object.entries(balances).filter(([,v])=>v>0).map(([id,amount])=>({id,amount})).sort((a,b)=>b.amount-a.amount||a.id.localeCompare(b.id));
 const debtors=Object.entries(balances).filter(([,v])=>v<0).map(([id,v])=>({id,amount:-v})).sort((a,b)=>b.amount-a.amount||a.id.localeCompare(b.id));
 const out=[];let i=0,j=0;
 while(i<debtors.length&&j<creditors.length){const amount=Math.min(debtors[i].amount,creditors[j].amount);out.push({from:debtors[i].id,to:creditors[j].id,amount});debtors[i].amount-=amount;creditors[j].amount-=amount;if(!debtors[i].amount)i++;if(!creditors[j].amount)j++;}
 return out;
}

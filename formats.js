import {ledger,cents} from './money.js';
export function csvCell(v){if(v==null)return '""';if(typeof v==='number'){if(!Number.isFinite(v))return '""';return String(v);}let text=String(v);if(/^[\s]*[=+\-@\t\r]/.test(text))text="'"+text;return '"'+text.replaceAll('"','""')+'"';}
export function activitySummary(a,s){
 const d=a.details||{},name=id=>s.members.find(m=>m.id===id)?.name||'Member';
 switch(a.action){
 case 'created_trip':return `Created ${d.name||'the trip'}`;
 case 'added_member':return `Added ${d.name||'a friend'}`;
 case 'removed_member':return `Removed ${d.name||'a member'}; previous expenses and balances retained`;
 case 'restored_member':return `Restored ${d.name||'a member'}`;
 case 'recorded_settlement':return `${name(d.from_member_id)} paid ${name(d.to_member_id)} EUR ${Number(d.amount_eur).toFixed(2)}`;
 default:return `${({added_expense:'Added',edited_expense:'Edited',deleted_expense:'Deleted',restored_expense:'Restored'})[a.action]||a.action.replaceAll('_',' ')} ${d.description||'expense'}${d.amount!=null?' · '+d.currency+' '+Number(d.amount).toFixed(2):''}`;
 }
}
export function tripCsv(s){
 const name=id=>s.members.find(m=>m.id===id)?.name||'Member';
 const rows=[['Record type','Trip','Date','Description','Currency','Amount','Rate to EUR','EUR amount','Paid by','Split method','Participants','From','To','Member','Notes']];
 for(const e of [...s.expenses,...(s.deleted_expenses||[])]){
  const paid=s.payers.filter(p=>p.expense_id===e.id).map(p=>`${name(p.member_id)}: ${Number(p.amount).toFixed(2)} ${e.currency}`).join('; ');
  const split=s.splits.filter(p=>p.expense_id===e.id).map(p=>`${name(p.member_id)}${e.split_method==='equal'?'':': '+p.value+(e.split_method==='percentage'?'%':e.split_method==='exact'?' '+e.currency:' shares')}`).join('; ');
  rows.push([e.deleted_at?'Deleted expense':'Expense',s.trip.name,e.created_at,e.description,e.currency,Number(e.amount),Number(e.exchange_rate_to_eur),cents(Number(e.amount)*Number(e.exchange_rate_to_eur))/100,paid,e.split_method,split,'','','',e.deleted_at?'Excluded from balances':'']);
 }
 for(const p of s.settlements)rows.push(['Settlement',s.trip.name,p.created_at,'Payment recorded','EUR',Number(p.amount_eur),1,Number(p.amount_eur),'','','',name(p.from_member_id),name(p.to_member_id),'','']);
 for(const [id,value] of Object.entries(ledger(s).balances))rows.push(['Balance',s.trip.name,'','Current balance','EUR',value/100,1,value/100,'','','','','',name(id),value>0?'Gets back':value<0?'Owes':'Settled']);
 for(const a of s.activity)rows.push(['Activity',s.trip.name,a.created_at,activitySummary(a,s),'','','','','','','','','',a.member_name||'A friend','']);
 return '\uFEFF'+rows.map(r=>r.map(csvCell).join(',')).join('\r\n')+'\r\n';
}

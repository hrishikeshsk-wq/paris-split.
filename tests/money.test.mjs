import {test} from 'node:test';import assert from 'node:assert/strict';import {allocate,ledger,simplify} from '../money.js';
test('uneven cents conserved and stable across input order',()=>{assert.deepEqual(allocate(100,[{id:'b',weight:1},{id:'a',weight:1},{id:'c',weight:1}]),{a:34,b:33,c:33});});
test('zero shares and weighted rounding',()=>assert.deepEqual(allocate(101,[{id:'a',weight:2},{id:'b',weight:1},{id:'c',weight:0}]),{a:67,b:34,c:0}));
test('reject invalid shares',()=>{assert.throws(()=>allocate(100,[{id:'a',weight:-1}]));assert.throws(()=>allocate(100,[{id:'a',weight:0}]));});
test('multiple payers, FX, unequal shares, and settlement',()=>{
const s={members:[{id:'a'},{id:'b'},{id:'c'}],expenses:[{id:'e',amount:100,exchange_rate_to_eur:1.2,split_method:'shares'}],payers:[{expense_id:'e',member_id:'a',amount:60},{expense_id:'e',member_id:'b',amount:40}],splits:[{expense_id:'e',member_id:'a',value:2},{expense_id:'e',member_id:'b',value:1},{expense_id:'e',member_id:'c',value:1}],settlements:[{from_member_id:'c',to_member_id:'a',amount_eur:12}]};
assert.deepEqual(ledger(s),{total:12000,balances:{a:0,b:1800,c:-1800}});assert.deepEqual(simplify(ledger(s).balances),[{from:'c',to:'b',amount:1800}]);
});
test('random allocations and simplified transfers conserve cents',()=>{for(let n=1;n<200;n++){const rows=Array.from({length:7},(_,i)=>({id:String(i),weight:(n*(i+3))%19+1}));const a=allocate(n*131,rows);assert.equal(Object.values(a).reduce((x,y)=>x+y,0),n*131);const balances={...a};balances['0']-=n*131;for(const p of simplify(balances)){balances[p.from]+=p.amount;balances[p.to]-=p.amount;}assert.ok(Object.values(balances).every(v=>v===0));}});

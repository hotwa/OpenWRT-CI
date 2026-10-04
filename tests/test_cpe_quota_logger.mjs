import {test} from 'node:test';import assert from 'node:assert/strict';
import {ensureLogger,loggerCommand} from '../Scripts/cpe5g-ipv6/quota-logger.mjs';
test('clock mismatch prevents any database repair',async()=>{
 const calls=[];await assert.rejects(ensureLogger({now:1000000,transport:async(h,p,c)=>{calls.push(c);return '2085949800';}}),/clock/);assert.deepEqual(calls,['date +%s']);
});
test('normal clock permits idempotent logger check; no quota or usage reset',async()=>{
 const calls=[];await ensureLogger({now:1000000,transport:async(h,p,c)=>{calls.push(c);return c==='date +%s'?'1000':'CPE6_LOGGER_READY';}});
 assert.equal(calls[1],loggerCommand);assert.match(loggerCommand,/SET updated=/);assert.doesNotMatch(loggerCommand,/SET\s+(rxtotal|txtotal|rxcounter|txcounter)|DELETE\s+FROM|--initdb|traffic_much|traffic_switch/i);
 assert.match(loggerCommand,/cpe-maint-backup/);assert.match(loggerCommand,/comm.*vnstatd/);
});
test('missing acknowledgement fails closed',async()=>{await assert.rejects(ensureLogger({now:1000000,transport:async(h,p,c)=>c==='date +%s'?'1000':''}),/unavailable/);});

import {shell} from './adb.mjs';
import {snapshot} from './model.mjs';
import {counters} from './quota-ledger.mjs';
export const readCommand=`printf 'CPE6_ADDR\\n'; cat /proc/net/if_inet6; printf 'CPE6_ROUTE\\n'; ip -6 route show table all; printf 'CPE6_QUOTA\\n'; sqlite3 'file:/home/root/6677/6677.db?mode=ro' "SELECT key,value FROM config WHERE key IN ('traffic_switch','traffic_much');"; printf 'CPE6_USAGE\\n'; /home/root/6677/vnstat -i sipa_eth0 --json s; printf 'CPE6_END\\n'`;
export const accountingCommand=readCommand.slice(0,readCommand.lastIndexOf("printf 'CPE6_END"))+`printf 'CPE6_COUNTERS\\n'; printf 'boot|'; cat /proc/sys/kernel/random/boot_id; printf 'rx|'; cat /sys/class/net/sipa_eth0/statistics/rx_bytes; printf 'tx|'; cat /sys/class/net/sipa_eth0/statistics/tx_bytes; printf 'CPE6_END\\n'`;
export async function read(host,port,options){
 const raw=(await shell(host,port,accountingCommand,options)).replaceAll('\r','');
 const result=snapshot(raw),start=raw.indexOf('CPE6_COUNTERS\n'),end=raw.indexOf('CPE6_END',start);
 if(start<0||end<0)throw Error('Cellular accounting snapshot missing');
 result.counters=counters(raw.slice(start+'CPE6_COUNTERS\n'.length,end));
 return result;
}
if(import.meta.url===`file://${process.argv[1]}`){
 const s=await read(process.argv[2]||'192.168.66.1',Number(process.argv[3]||5555));
 console.log(JSON.stringify({prefixAvailable:!!s.prefix,cellularDefault:s.hasDefault,quota:s.quota},null,2));
}

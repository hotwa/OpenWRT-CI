import {shell} from './adb.mjs';
import {snapshot} from './model.mjs';
export const readCommand=`printf 'CPE6_ADDR\\n'; cat /proc/net/if_inet6; printf 'CPE6_ROUTE\\n'; ip -6 route show table all; printf 'CPE6_QUOTA\\n'; sqlite3 'file:/home/root/6677/6677.db?mode=ro' "SELECT key,value FROM config WHERE key IN ('traffic_switch','traffic_much');"; printf 'CPE6_USAGE\\n'; /home/root/6677/vnstat -i sipa_eth0 --json s; printf 'CPE6_END\\n'`;
export async function read(host,port,options){return snapshot(await shell(host,port,readCommand,options));}
if(import.meta.url===`file://${process.argv[1]}`){
 const s=await read(process.argv[2]||'192.168.66.1',Number(process.argv[3]||5555));
 console.log(JSON.stringify({prefixAvailable:!!s.prefix,cellularDefault:s.hasDefault,quota:s.quota},null,2));
}

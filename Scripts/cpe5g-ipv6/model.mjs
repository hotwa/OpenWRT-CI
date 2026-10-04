import net from 'node:net';
export function ipv6(hex) {
 if(!/^[0-9a-f]{32}$/i.test(hex))throw Error('Malformed IPv6 address');
 return hex.toLowerCase().match(/.{4}/g).map(x=>parseInt(x,16).toString(16)).join(':');
}
export function fromAddress(address){
 if(net.isIP(address)!==6||address.includes('.'))throw Error('Invalid native IPv6');
 const halves=address.split('::');if(halves.length>2)throw Error('Invalid IPv6');
 const left=halves[0]?halves[0].split(':'):[],right=halves.length===2&&halves[1]?halves[1].split(':'):[];
 const parts=halves.length===2?[...left,...Array(8-left.length-right.length).fill('0'),...right]:left;
 if(parts.length!==8)throw Error('Invalid IPv6');return parts.map(x=>x.padStart(4,'0')).join('').toLowerCase();
}
export function nativeAddress(prefixHex){
 if(!/^[0-9a-f]{16}$/i.test(prefixHex))throw Error('Invalid native IPv6 prefix');
 return ipv6(prefixHex+'0000c0de00130001');
}
function section(text,key){const start=`CPE6_${key}\n`,end='CPE6_';const at=text.indexOf(start);if(at<0)throw Error(`Missing ${key} snapshot`);const tail=text.slice(at+start.length);return tail.slice(0,tail.indexOf(end)<0?undefined:tail.indexOf(end)).trim();}
export function snapshot(raw){
 const text=raw.replaceAll('\r',''),addresses=section(text,'ADDR').split('\n').map(l=>l.trim().split(/\s+/)).filter(p=>p.length===6&&/^[0-9a-f]{32}$/i.test(p[0]));
 const rows=Object.fromEntries(section(text,'QUOTA').split('\n').map(l=>l.split('|')).filter(p=>p.length===2));
 if(!['0','1'].includes(rows.traffic_switch)||!/^\d+$/.test(rows.traffic_much||''))throw Error('Quota settings unavailable');
 const usage=JSON.parse(section(text,'USAGE'));if(usage.jsonversion!=='2')throw Error('Unsupported traffic counter units');
 const iface=usage.interfaces?.find(i=>i.name==='sipa_eth0');
 const updated=iface?.updated?.timestamp;
 if(!Number.isSafeInteger(updated)||updated<Date.now()/1000-600||updated>Date.now()/1000+300)throw Error('Quota counter timestamp is stale or invalid');
 const counters=iface?.traffic?.total;
 if(!counters||!Number.isSafeInteger(counters.rx)||!Number.isSafeInteger(counters.tx)||counters.rx<0||counters.tx<0)throw Error('Quota counters unavailable');
 const used=BigInt(counters.rx)+BigInt(counters.tx),limit=BigInt(rows.traffic_much),enabled=rows.traffic_switch==='1';
 const routes=section(text,'ROUTE');
 // Quota is independent of native IPv6 availability: a healthy IPv4 backup
 // remains usable while the carrier is renewing its IPv6 prefix.
 const cell=addresses.filter(p=>p[5]==='sipa_eth0'&&p[3]==='00'&&p[2]==='40'&&/^[23]/.test(p[0])&&!(parseInt(p[4],16)&0x68));
 const prefixes=[...new Set(cell.map(p=>p[0].slice(0,16)))];
 const prefixHex=prefixes.length===1?prefixes[0]:null;
 const prefix=prefixHex?ipv6(prefixHex+'0000000000000000')+'/64':null;
 const link=addresses.find(p=>p[5]==='usb0'&&p[3]==='20'&&p[0].startsWith('fe80')&&!(parseInt(p[4],16)&0x48));
 return {prefix,prefixHex,cellAddress:prefixHex?ipv6(cell.find(p=>p[0].startsWith(prefixHex))[0]):null,
 usbLinkLocal:link?ipv6(link[0]):null,
 cpeAddresses:prefixHex?[...new Set(addresses.filter(p=>p[3]==='00'&&p[0].startsWith(prefixHex)&&!(parseInt(p[4],16)&0x48)).map(p=>ipv6(p[0])))]:[],
 routes,quota:{enabled,limit:limit.toString(),used:used.toString(),blocked:enabled&&(limit===0n||used>=limit)},
 hasDefault:routes.split('\n').some(l=>/^default .*dev sipa_eth0(?: |$)/.test(l))};
}
export function update(interfaceName,device,s,{lan=true,lifetime=180,metric=665}={}){
 const address=nativeAddress(s.prefixHex);
 return {action:0,interface:interfaceName,ifname:device,'link-up':true,keep:false,
 ip6addr:[{ipaddr:address,mask:'128',preferred:lifetime,valid:lifetime}],
 ip6prefix:lan?[`${s.prefix},${lifetime},${lifetime}`]:[],
 routes6:[{target:'::',netmask:'0',gateway:s.usbLinkLocal,metric},...s.cpeAddresses.map(a=>({target:a,netmask:'128',gateway:s.usbLinkLocal,metric}))],
 data:{cpe6:true}};
}
export function withdraw(interfaceName,device){return {action:0,interface:interfaceName,ifname:device,'link-up':false,keep:false};}
export function stockUsbRoute(line,prefix,table){
 const parts=line.trim().split(/\s+/);if(fromAddress(parts[0].split('/')[0])!==fromAddress(prefix.split('/')[0])||parts[0].split('/')[1]!=='64')return false;
 return !parts.includes('via')&&parts[parts.indexOf('dev')+1]==='usb0'&&parts[parts.indexOf('table')+1]===String(table);
}

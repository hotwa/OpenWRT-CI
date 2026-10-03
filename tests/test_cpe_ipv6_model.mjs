import assert from 'node:assert/strict';
import {snapshot,update,withdraw,fromAddress} from '../Scripts/cpe5g-ipv6/model.mjs';
const prefix='20010db812345678';
const cell=prefix+'0000000000000011';
const link='fe800000000000000000000000000012';
function raw({addresses=[`${cell} 04 40 00 80 sipa_eth0`,`${link} 05 40 20 80 usb0`],switchValue='1',limit='1000',rx=200,tx=100,version='2',routes='default via fe80::1 dev sipa_eth0 table 181'}={}){
 return `CPE6_ADDR\n${addresses.join('\n')}\nCPE6_ROUTE\n${routes}\nCPE6_QUOTA\ntraffic_switch|${switchValue}\ntraffic_much|${limit}\nCPE6_USAGE\n${JSON.stringify({jsonversion:version,interfaces:[{name:'sipa_eth0',traffic:{total:{rx,tx}}}]})}\nCPE6_END\n`;
}
let s=snapshot(raw());assert.equal(s.prefix,'2001:db8:1234:5678:0:0:0:0/64');assert.equal(s.quota.used,'300');assert.equal(s.quota.blocked,false);
const up=update('cpe6','usb0',s);assert.equal(up.ip6addr[0].mask,'128');assert.equal(up.ip6prefix[0],s.prefix+',180,180');assert.equal(up.routes6[0].gateway,s.usbLinkLocal);assert.equal(update('cpe6','usb0',s,{lan:false}).ip6prefix.length,0);assert.equal(withdraw('cpe6','usb0')['link-up'],false);
assert.equal(snapshot(raw({addresses:[`${link} 05 40 20 80 usb0`]})).prefix,null,'No IPv6 must preserve a trustworthy IPv4 quota');
assert.equal(snapshot(raw({addresses:[`${cell} 04 40 00 a0 sipa_eth0`,`${link} 05 40 20 80 usb0`]})).prefix,null,'Deprecated carrier address must not be selected');
assert.equal(snapshot(raw({addresses:[`${cell} 04 40 00 a0 sipa_eth0`,`${prefix}0000000000000022 04 40 00 80 sipa_eth0`,`${link} 05 40 20 80 usb0`]})).prefix,s.prefix);
assert.equal(snapshot(raw({addresses:[`${cell} 04 40 00 80 sipa_eth0`,`${prefix}0000000000000022 04 40 00 80 sipa_eth0`,`${link} 05 40 20 80 usb0`]})).prefix,s.prefix,'Multiple addresses in one /64 are valid');
assert.equal(snapshot(raw({addresses:[`${cell} 04 40 00 80 sipa_eth0`,`20010db8000099990000000000000022 04 40 00 80 sipa_eth0`,`${link} 05 40 20 80 usb0`]})).prefix,null,'Ambiguous distinct active prefixes must not be guessed');
assert.equal(snapshot(raw({rx:900,tx:100})).quota.blocked,true);assert.equal(snapshot(raw({limit:'0'})).quota.blocked,true);assert.equal(snapshot(raw({limit:'0',switchValue:'0'})).quota.blocked,false);
for(const changes of [{switchValue:'x'},{limit:'-1'},{rx:-1},{tx:9007199254740992},{version:'1'}])assert.throws(()=>snapshot(raw(changes)),/Quota|counter/);
assert.equal(fromAddress('fe80::12'),link);assert.throws(()=>fromAddress('::ffff:192.168.1.1'));
console.log('CPE native IPv6 model passed');

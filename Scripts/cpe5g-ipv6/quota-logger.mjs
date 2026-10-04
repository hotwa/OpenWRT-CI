// Repair only future update metadata; never reset usage, quota or billing rows.
import {shell} from './adb.mjs';
export const loggerCommand=`
future=$(sqlite3 /var/lib/vnstat/vnstat.db "SELECT count(*) FROM interface WHERE updated>datetime('now','localtime','+1 day');")
case "$future" in ''|*[!0-9]*) exit 1;; esac
pids=''
for p in /proc/[0-9]*; do
 [ "$(cat "$p/comm" 2>/dev/null)" = vnstatd ] && pids="$pids \${p##*/}"
done
if [ "$future" -gt 0 ]; then
 [ -f /var/lib/vnstat/vnstat.db.cpe-maint-backup ] || cp -p /var/lib/vnstat/vnstat.db /var/lib/vnstat/vnstat.db.cpe-maint-backup || exit 1
 for p in $pids; do kill -TERM "$p" || exit 1; done
 [ -z "$pids" ] || sleep 2
 sqlite3 /var/lib/vnstat/vnstat.db "UPDATE interface SET updated=datetime('now','localtime') WHERE updated>datetime('now','localtime','+1 day');" || exit 1
 pids=''
fi
if [ -z "$pids" ]; then
 /home/root/6677/vnstatd --sync --config /home/root/6677/vnstatd.conf --daemon --pidfile /tmp/cpe6-vnstatd.pid || exit 1
fi
printf CPE6_LOGGER_READY
`;
export async function ensureLogger({transport=shell,signal,now=Date.now()}={}){
 const call=c=>transport('192.168.66.1',5555,c,{timeout:12000,signal});
 const remote=Number((await call('date +%s')).trim());
 if(!Number.isSafeInteger(remote)||Math.abs(remote-now/1000)>300)throw Error('modem clock is not synchronized; quota metadata repair held');
 if(!(await call(loggerCommand)).includes('CPE6_LOGGER_READY'))throw Error('modem traffic logger unavailable');
}

#include <sys/socket.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
int main(void){int fd=socket(AF_NETLINK,SOCK_RAW,NETLINK_ROUTE);if(fd<0)return 1;struct sockaddr_nl sa={.nl_family=AF_NETLINK};if(bind(fd,(void*)&sa,sizeof sa))return 2;struct{struct nlmsghdr n;struct rtmsg r;} q={.n={.nlmsg_len=NLMSG_LENGTH(sizeof(struct rtmsg)),.nlmsg_type=RTM_GETROUTE,.nlmsg_flags=NLM_F_REQUEST|NLM_F_DUMP,.nlmsg_seq=1},.r={.rtm_family=AF_INET6}};if(send(fd,&q,q.n.nlmsg_len,0)<0)return 3;char buf[32768];int len;while((len=recv(fd,buf,sizeof buf,0))>0){for(struct nlmsghdr*h=(void*)buf;NLMSG_OK(h,len);h=NLMSG_NEXT(h,len)){if(h->nlmsg_type==NLMSG_DONE){close(fd);return 0;}if(h->nlmsg_type==NLMSG_ERROR)return 4;if(h->nlmsg_type!=RTM_NEWROUTE)continue;struct rtmsg*r=NLMSG_DATA(h);if(r->rtm_family!=AF_INET6)continue;uint32_t table=r->rtm_table,metric=0,oif=0;struct in6_addr dst={0},gw={0};int left=RTM_PAYLOAD(h);for(struct rtattr*a=RTM_RTA(r);RTA_OK(a,left);a=RTA_NEXT(a,left)){if(RTA_PAYLOAD(a)<4)continue;switch(a->rta_type){case RTA_TABLE:memcpy(&table,RTA_DATA(a),4);break;case RTA_PRIORITY:memcpy(&metric,RTA_DATA(a),4);break;case RTA_OIF:memcpy(&oif,RTA_DATA(a),4);break;case RTA_DST:if(RTA_PAYLOAD(a)==16)memcpy(&dst,RTA_DATA(a),16);break;case RTA_GATEWAY:if(RTA_PAYLOAD(a)==16)memcpy(&gw,RTA_DATA(a),16);break;}}if(r->rtm_protocol!=196||(table!=181&&table!=200)||metric!=665||r->rtm_dst_len!=64||r->rtm_type!=RTN_UNICAST||!IN6_IS_ADDR_LINKLOCAL(&gw))continue;char d[INET6_ADDRSTRLEN],g[INET6_ADDRSTRLEN],dev[IF_NAMESIZE];if(!if_indextoname(oif,dev)||strcmp(dev,"usb0"))continue;inet_ntop(AF_INET6,&dst,d,sizeof d);inet_ntop(AF_INET6,&gw,g,sizeof g);printf("%s/64 via %s dev %s table %u proto 196 metric %u\n",d,g,dev,table,metric);}}return 5;}

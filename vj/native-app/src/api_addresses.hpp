#pragma once
#include <nlohmann/json.hpp>
#include <ifaddrs.h>
#include <net/if.h>
#include <arpa/inet.h>
#include <set>
#include <string>
namespace vj {
inline nlohmann::json apiAddresses(const std::string& bind,unsigned short port){
 std::set<std::string> hosts;bool wildcard=bind=="0.0.0.0"||bind=="::";
 if(!wildcard)hosts.insert(bind);
 else {hosts.insert(bind=="::"?"::1":"127.0.0.1");ifaddrs* addresses=nullptr;if(getifaddrs(&addresses)==0){for(auto* item=addresses;item;item=item->ifa_next){if(!item->ifa_addr||!(item->ifa_flags&IFF_UP)||!(item->ifa_flags&IFF_RUNNING)||(item->ifa_flags&IFF_POINTOPOINT))continue;int family=item->ifa_addr->sa_family;if(family!=(bind=="::"?AF_INET6:AF_INET))continue;char buffer[INET6_ADDRSTRLEN];const void* bytes=family==AF_INET?(const void*)&((sockaddr_in*)item->ifa_addr)->sin_addr:(const void*)&((sockaddr_in6*)item->ifa_addr)->sin6_addr;if(inet_ntop(family,bytes,buffer,sizeof(buffer))){std::string host=buffer;if(!host.starts_with("fe80:"))hosts.insert(host);}}freeifaddrs(addresses);}}
 nlohmann::json urls=nlohmann::json::array();for(const auto& host:hosts)urls.push_back("http://"+(host.find(':')!=std::string::npos?"["+host+"]":host)+":"+std::to_string(port));return {{"bind",bind},{"port",port},{"urls",urls},{"lan",wildcard||(!bind.starts_with("127.")&&bind!="::1")}};
}
}

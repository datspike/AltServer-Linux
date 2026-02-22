#include "dns_sd.h"
#include <iostream>
#include <string>
#include <vector>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/prctl.h> // prctl(), PR_SET_PDEATHSIG
#include <signal.h> // signals


DNSServiceErrorType DNSSD_API DNSServiceRegister
    (
    DNSServiceRef                       *sdRef,
    DNSServiceFlags                     flags,
    uint32_t                            interfaceIndex,
    const char                          *name,         /* may be NULL */
    const char                          *regtype,
    const char                          *domain,       /* may be NULL */
    const char                          *host,         /* may be NULL */
    uint16_t                            port,
    uint16_t                            txtLen,
    const void                          *txtRecord,    /* may be NULL */
    DNSServiceRegisterReply             callBack,      /* may be NULL */
    void                                *context       /* may be NULL */
    ) {
        std::string serviceName = name ? name : "AltServer";
        std::string serviceType = regtype ? regtype : "_altserver._tcp";
        std::string portString = std::to_string(ntohs(port));

        std::vector<std::string> txtEntries;
        if (txtRecord && txtLen > 0) {
            const unsigned char* p = (const unsigned char*)txtRecord;
            int i = 0;
            while (i < txtLen) {
                unsigned int entryLen = p[i++];
                if (i + (int)entryLen > txtLen) {
                    break;
                }
                txtEntries.emplace_back((const char*)(p + i), entryLen);
                i += entryLen;
            }
        }

        printf("Publishing mDNS service via avahi-publish-service: name=%s type=%s port=%s\n",
               serviceName.c_str(), serviceType.c_str(), portString.c_str());

        pid_t ppid_before_fork = getpid();
        int child,status;
        if ((child = fork()) < 0) {
            perror("fork");
            return kDNSServiceErr_Unknown;
        }
        if(child == 0){
            int r = prctl(PR_SET_PDEATHSIG, SIGTERM);
            if (r == -1) { perror(0); exit(1); }
            // test in case the original parent exited just
            // before the prctl() call
            if (getppid() != ppid_before_fork)
                exit(1);

            std::vector<std::string> args;
            args.emplace_back("avahi-publish-service");
            args.emplace_back(serviceName);
            args.emplace_back(serviceType);
            args.emplace_back(portString);
            for (const auto& txt : txtEntries) {
                args.emplace_back(txt);
            }

            std::vector<char*> argv;
            for (auto& arg : args) {
                argv.push_back((char*)arg.c_str());
            }
            argv.push_back(NULL);

            execvp("avahi-publish-service", argv.data());
            exit(1);
        } else {
            ;
        }
        return kDNSServiceErr_NoError;
    }

int DNSSD_API DNSServiceRefSockFD(DNSServiceRef sdRef) {
    return 0xDEADBEEF;
}

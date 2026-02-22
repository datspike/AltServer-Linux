#!/usr/bin/python3

import re
import sys

F = sys.argv[1]

with open(F, 'rb') as f:
    content = f.read()

content = re.sub(br'L("([^"\\]|\\.)*")', br'U(\1)', content)
content = content.replace(b'std::wstring', b'std::string')
content = content.replace(b'boost/filesystem.hpp', b'filesystem')
content = content.replace(b'boost::filesystem', b'std::filesystem')

content = content.replace(b'"%FT%T%z"', b'"%Y-%m-%dT%H:%M:%SZ"')
content = content.replace(b'localtime(', b'gmtime(')

content = content.replace(b'winsock2.h', b'WinSock2.h')

content = content.replace(
    b'plist_from_memory((const char *)plistData.data(), (int)plistData.size(), &plist);',
    b'plist_from_memory((const char *)plistData.data(), (int)plistData.size(), &plist, nullptr);'
)
content = content.replace(
    b'plist_from_memory((const char*)rawEntitlements.data(), (int)rawEntitlements.size(), &plist);',
    b'plist_from_memory((const char*)rawEntitlements.data(), (int)rawEntitlements.size(), &plist, nullptr);'
)
content = content.replace(
    b'plist_from_memory((const char *)pointer, (unsigned int)length, &parsedPlist);',
    b'plist_from_memory((const char *)pointer, (unsigned int)length, &parsedPlist, nullptr);'
)

# Reduce high-volume/sensitive debug noise in CLI logs.
content = content.replace(
    b'odslog("Signing Progress: " << signingProgress);',
    b''
)
content = content.replace(
    b'odslog("Data: " << decryptedData->data());',
    b''
)
content = content.replace(
    b'odslog("Got token for " << app << "!\\nValue : " << token);',
    b'odslog("Got token for " << app << "!");'
)
content = re.sub(
    br'odslog\("HMAC_OUT:"\);\s*for\s*\(int i = 0; i < digest_len; i\+\+\)\s*\{.*?\}\s*odslog\("NP:"\);\s*for\s*\(int i = 0; i < digest_len; i\+\+\)\s*\{.*?\}',
    b'',
    content,
    flags=re.S
)

sys.stdout.buffer.write(content)

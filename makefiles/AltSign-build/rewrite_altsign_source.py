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

sys.stdout.buffer.write(content)

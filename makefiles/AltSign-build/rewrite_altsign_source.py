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

if F.endswith('AppleAPI+Authentication.cpp'):
    content = content.replace(
        b'"akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0"',
        b'"AuthKit/1 (Macintosh; OS X 26.5.2) (com.apple.dt.Xcode/26.0)"',
    )
    content, replacements = re.subn(
        br'(uri_builder builder\(U\("/grandslam/GsService2"\)\);\s*http_request request\(methods::POST\);.*?for \(auto& pair : headers\)\s*\{.*?\}\s*)auto task = this->gsaClient\(\)\.request\(request\)',
        lambda match: match.group(1) + b'http_client_config config;\n\tconfig.set_validate_certificates(false);\n\tauto gsaClient = std::make_shared<http_client>(U("https://gsa.apple.com"), config);\n\tauto task = gsaClient->request(request)',
        content,
        count=1,
        flags=re.S,
    )
    if replacements != 1:
        print('Не удалось отключить переиспользование GrandSlam-соединения в SendAuthenticationRequest', file=sys.stderr)
        sys.exit(1)
    # Сохраняем этап до освобождения plist запроса; не выводим учётные данные.
    phase_marker = b'\tauto header = plist_new_dict();'
    phase_diagnostic = br'''
    const char* authPhase = "other";
    const auto operation = requestParameters.find("o");
    if (operation != requestParameters.end())
    {
        char* rawOperation = nullptr;
        plist_get_string_val(operation->second, &rawOperation);
        if (rawOperation != nullptr)
        {
            const std::string name(rawOperation);
            if (name == "init") authPhase = "init";
            else if (name == "complete") authPhase = "complete";
            else if (name == "apptokens") authPhase = "apptokens";
            free(rawOperation);
        }
    }
'''
    if content.count(phase_marker) != 1:
        print('Не удалось добавить диагностику этапа GrandSlam', file=sys.stderr)
        sys.exit(1)
    content = content.replace(phase_marker, phase_diagnostic + phase_marker, 1)
    content, replacements = re.subn(
        br'(switch \(resultCode\)\s*\{\s*case 0: return dictionary;)',
        br'odslog("GSA " << authPhase << " response code: " << resultCode);\n\t\t\t\t\1',
        content,
        count=1,
    )
    if replacements != 1:
        print('Не удалось добавить диагностику кода GrandSlam', file=sys.stderr)
        sys.exit(1)

# Под iOS 26.4+ старую подпись ldid отклоняет TXM, поэтому используем rcodesign.
# Остальная подготовка bundle остаётся в AltSign: профиль, entitlements и сертификат уже готовы.
if F.endswith('Signer.cpp'):
    content = content.replace(
        b'#include "Signer.hpp"',
        b'#include "Signer.hpp"\n#include <cstdlib>\n#include <regex>\n#include <stdexcept>',
        1,
    )
    rcodesign_block = br'''
        {
            auto shellEscape = [](const std::string &value) -> std::string {
                std::string escaped = "'";
                for (char ch : value)
                {
                    if (ch == '\'')
                    {
                        escaped += "'\\''";
                    }
                    else
                    {
                        escaped += ch;
                    }
                }
                escaped += "'";
                return escaped;
            };

            fs::path rcTmp = fs::temp_directory_path() / make_uuid();
            fs::create_directories(rcTmp);
            fs::path p12Path = rcTmp / "key.p12";
            fs::path pemPath = rcTmp / "key.pem";
            { std::ofstream kf(p12Path.string(), std::ios::out | std::ios::binary); kf.write(key.data(), (std::streamsize)key.size()); }
            auto scrubEntitlements = [](std::string entitlements) -> std::string {
                return std::regex_replace(entitlements, std::regex("\\s*<key>get-task-allow</key>\\s*<(true|false)\\s*/>"), "");
            };

            std::string entitlementArgs;
            int entitlementIndex = 0;
            for (const auto &pair : entitlementsByFilepath)
            {
                fs::path entPath = rcTmp / ("ents-" + std::to_string(entitlementIndex++) + ".xml");
                std::string entitlements = scrubEntitlements(pair.second);
                { std::ofstream ef(entPath.string(), std::ios::out | std::ios::binary); ef.write(entitlements.data(), (std::streamsize)entitlements.size()); }

                std::string entScope = entPath.string();
                std::error_code relativeError;
                fs::path relativePath = fs::relative(pair.first, app.path(), relativeError);
                if (!relativeError && !relativePath.empty() && relativePath.string() != ".")
                {
                    entScope = relativePath.generic_string() + ":" + entScope;
                }

                entitlementArgs += " --entitlements-xml-file " + shellEscape(entScope);
            }

            std::string toPem = "openssl pkcs12 -legacy -nomacver -nodes -passin pass: -in " + shellEscape(p12Path.string()) + " -out " + shellEscape(pemPath.string());
            if (system(toPem.c_str()) != 0) { fs::remove_all(rcTmp); throw std::runtime_error("rcodesign: failed to convert signing key to PEM"); }

            const char* rcEnv = getenv("ALTSERVER_RCODESIGN");
            std::string rcodesign = (rcEnv && *rcEnv) ? std::string(rcEnv) : std::string("rcodesign");
            std::string cmd = shellEscape(rcodesign) + " sign --timestamp-url none --pem-file " + shellEscape(pemPath.string()) + entitlementArgs + " " + shellEscape(app.path());
            odslog("rcodesign signing: " << cmd);
            int rc = system(cmd.c_str());
            if (rc != 0) { fs::remove_all(rcTmp); throw std::runtime_error("rcodesign signing failed (set ALTSERVER_RCODESIGN to its path)"); }
            fs::remove_all(rcTmp);
        }'''
    content, replacements = re.subn(
        br'ldid::Sign\("", appBundle, key, "",.*?signingProgress\);\s*\n\s*\}\)\);',
        lambda _match: rcodesign_block,
        content,
        count=1,
        flags=re.S,
    )
    if replacements != 1:
        print('Не удалось заменить ldid::Sign на rcodesign в Signer.cpp', file=sys.stderr)
        sys.exit(1)

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

# Убираем шумные и чувствительные отладочные записи из CLI-логов.
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

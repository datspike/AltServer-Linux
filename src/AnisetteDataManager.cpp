#include "AnisetteDataManager.h"
#include <sstream>
#include <filesystem>
#include "Error.hpp"
#include "ServerError.hpp"

#include <set>
#include <ctime>
#include <cstdlib>
#include <algorithm>
#include <stdexcept>
#include <vector>

#include "AnisetteData.h"
#include "AltServerApp.h"

#define odslog(msg) { std::stringstream ss; ss << msg << std::endl; OutputDebugStringA(ss.str().c_str()); }

AnisetteDataManager* AnisetteDataManager::_instance = nullptr;

AnisetteDataManager* AnisetteDataManager::instance()
{
	if (_instance == 0)
	{
		_instance = new AnisetteDataManager();
	}

	return _instance;
}

AnisetteDataManager::AnisetteDataManager() : loadedDependencies(false)
{
}

AnisetteDataManager::~AnisetteDataManager()
{
}

bool AnisetteDataManager::LoadiCloudDependencies()
{
	return true;
}

bool AnisetteDataManager::LoadDependencies()
{
	return true;
}

#include <cpprest/json.h>

using namespace web;                        // Common features like URIs.
using namespace web::http;                  // Common HTTP functionality
using namespace web::http::client;          // HTTP client features

std::string GetAnisetteURL() {
	const char *server = getenv("ALTSERVER_ANISETTE_SERVER");
	if (server) {
		return server;
	}
	return U("https://armconverter.com/anisette/irGb3Quww8zrhgqnzmrx");
}

static std::string Trim(std::string value)
{
	const std::string whitespace = " \t\r\n";
	const auto begin = value.find_first_not_of(whitespace);
	if (begin == std::string::npos)
	{
		return "";
	}
	const auto end = value.find_last_not_of(whitespace);
	return value.substr(begin, end - begin + 1);
}

static void PushUnique(std::vector<std::string>& values, const std::string& value)
{
	if (value.empty())
	{
		return;
	}
	if (std::find(values.begin(), values.end(), value) == values.end())
	{
		values.push_back(value);
	}
}

static std::vector<std::string> ParseEndpointList(const char* raw)
{
	std::vector<std::string> values;
	if (raw == nullptr)
	{
		return values;
	}

	std::string input(raw);
	for (char& c : input)
	{
		if (c == ';' || c == ' ')
		{
			c = ',';
		}
	}

	std::stringstream ss(input);
	std::string token;
	while (std::getline(ss, token, ','))
	{
		PushUnique(values, Trim(token));
	}

	return values;
}

static std::vector<std::string> GetAnisetteURLs()
{
	std::vector<std::string> urls;

	const char* explicitList = getenv("ALTSERVER_ANISETTE_SERVERS");
	auto parsedList = ParseEndpointList(explicitList);
	if (!parsedList.empty())
	{
		return parsedList;
	}

	PushUnique(urls, Trim(GetAnisetteURL()));
	PushUnique(urls, "http://127.0.0.1:6969");
	PushUnique(urls, "http://localhost:6969");

	return urls;
}

static std::string CompactHttpBody(std::string body, size_t maxLen = 240)
{
	std::replace(body.begin(), body.end(), '\r', ' ');
	std::replace(body.begin(), body.end(), '\n', ' ');
	std::replace(body.begin(), body.end(), '\t', ' ');
	if (body.size() > maxLen)
	{
		body.resize(maxLen);
		body += "...";
	}
	return body;
}

std::shared_ptr<AnisetteData> AnisetteDataManager::FetchAnisetteData()
{
	// auto client = web::http::client::http_client(U("https://armconverter.com"));
	// std::string wideURI = ("/anisette/irGb3Quww8zrhgqnzmrx");
	
	// auto encodedURI = web::uri::encode_uri(wideURI);
	// uri_builder builder(encodedURI);

	// http_request request(methods::GET);
	// request.set_request_uri(builder.to_string());

	auto anisetteURLs = GetAnisetteURLs();
	std::vector<std::string> errors;

	for (const auto& anisetteURL : anisetteURLs)
	{
		try
		{
			odslog("Trying anisette endpoint: " << anisetteURL);
			auto client = web::http::client::http_client(anisetteURL);
			http_request request(methods::GET);
			
			std::map<utility::string_t, utility::string_t> headers = {
				{U("User-Agent"), U("Xcode")},
				{U("Accept"), U("application/json")},
			};

			for (auto& pair : headers)
			{
				if (request.headers().has(pair.first))
				{
					request.headers().remove(pair.first);
				}

				request.headers().add(pair.first, pair.second);
			}

			std::shared_ptr<AnisetteData> anisetteData = NULL;

			auto task = client.request(request)
				.then([=](http_response response)
					{
						return response.content_ready();
					})
				.then([=](http_response response)
					{
						odslog("Received response status code: " << response.status_code());
						auto statusCode = response.status_code();
						auto contentType = response.headers().content_type();
						return response.extract_vector()
							.then([statusCode, contentType](std::vector<unsigned char> body)
								{
									if (statusCode < status_codes::OK || statusCode >= status_codes::MultipleChoices)
									{
										std::string bodyText(body.begin(), body.end());
										std::string snippet = CompactHttpBody(bodyText);
										std::stringstream ss;
										ss << "Anisette server HTTP " << statusCode;
										if (!contentType.empty())
										{
											ss << " (" << contentType << ")";
										}
										if (!snippet.empty())
										{
											ss << ": " << snippet;
										}
										throw std::runtime_error(ss.str());
									}

									utility::stringstream_t stream;
									std::string bodyText(body.begin(), body.end());
									stream << bodyText;
									try
									{
										return json::value::parse(stream);
									}
									catch (const std::exception& exception)
									{
										std::stringstream ss;
										ss << "Failed to parse anisette response as JSON";
										if (!contentType.empty())
										{
											ss << " (" << contentType << ")";
										}
										auto snippet = CompactHttpBody(bodyText);
										if (!snippet.empty())
										{
											ss << ": " << snippet;
										}
										ss << " [" << exception.what() << "]";
										throw std::runtime_error(ss.str());
									}
								});
					})
				.then([&anisetteData](pplx::task<json::value> previousTask)
					{
						odslog("parse anisette data ret");
						json::value jsonVal = previousTask.get();
						odslog("Got anisetteData json: " << jsonVal);
						std::vector<std::string> keys = {
							"X-Apple-I-MD-M",
							"X-Apple-I-MD",
							"X-Apple-I-MD-LU",
							"X-Apple-I-MD-RINFO",
							"X-Mme-Device-Id",
							"X-Apple-I-SRL-NO",
							"X-MMe-Client-Info",
							"X-Apple-I-Client-Time",
							"X-Apple-Locale",
							"X-Apple-I-TimeZone"
						};
						for (auto &key : keys) {
							odslog(key << ": " << jsonVal.at(key).as_string().c_str());
						}

						struct tm tm = { 0 };
						strptime(jsonVal.at("X-Apple-I-Client-Time").as_string().c_str(), "%Y-%m-%dT%H:%M:%SZ", &tm);
						unsigned long ts = mktime(&tm);
						struct timeval tv = { 0 };
						tv.tv_sec = ts;
						tv.tv_usec = 0;

						odslog("Building anisetteData obj...");
						anisetteData = std::make_shared<AnisetteData>(
							jsonVal.at("X-Apple-I-MD-M").as_string(),
							jsonVal.at("X-Apple-I-MD").as_string(),
							jsonVal.at("X-Apple-I-MD-LU").as_string(),
							std::atoi(jsonVal.at("X-Apple-I-MD-RINFO").as_string().c_str()),
							jsonVal.at("X-Mme-Device-Id").as_string(),
							jsonVal.at("X-Apple-I-SRL-NO").as_string(),
							jsonVal.at("X-MMe-Client-Info").as_string(),
							tv,
							jsonVal.at("X-Apple-Locale").as_string(),
							jsonVal.at("X-Apple-I-TimeZone").as_string());
						
						//IterateJSONValue();
					});
			
			task.wait();
			odslog(*anisetteData);
			return anisetteData;
		}
		catch (const std::exception& exception)
		{
			std::stringstream ss;
			ss << "Anisette endpoint failed [" << anisetteURL << "]: " << exception.what();
			odslog(ss.str());
			errors.push_back(ss.str());
		}
	}

	if (errors.empty())
	{
		throw std::runtime_error("No anisette endpoints configured");
	}

	std::stringstream message;
	message << "All anisette endpoints failed";
	for (const auto& error : errors)
	{
		message << "\n- " << error;
	}
	throw std::runtime_error(message.str());
}

bool AnisetteDataManager::ReprovisionDevice(std::function<void(void)> provisionCallback)
{
#if !SPOOF_MAC
	provisionCallback();
	return true;
#else
	std::string adiDirectoryPath = "C:\\ProgramData\\Apple Computer\\iTunes\\adi";

	/* Start Provisioning */

	// Move iCloud's ADI files (so we don't mess with them).
	for (const auto& entry : fs::directory_iterator(adiDirectoryPath))
	{
		if (entry.path().extension() == ".pb")
		{
			fs::path backupPath = entry.path();
			backupPath += ".icloud";

			fs::rename(entry.path(), backupPath);
		}
	}

	// Copy existing AltServer .pb files into original location to reuse the MID.
	for (const auto& entry : fs::directory_iterator(adiDirectoryPath))
	{
		if (entry.path().extension() == ".altserver")
		{
			fs::path path = entry.path();
			path.replace_extension();

			fs::rename(entry.path(), path);
		}
	}

	auto cleanUp = [adiDirectoryPath]() {
		/* Finish Provisioning */

		// Backup AltServer ADI files.
		for (const auto& entry : fs::directory_iterator(adiDirectoryPath))
		{
			// Backup AltStore file
			if (entry.path().extension() == ".pb")
			{
				fs::path backupPath = entry.path();
				backupPath += ".altserver";

				fs::rename(entry.path(), backupPath);
			}
		}

		// Copy iCloud ADI files back to original location.
		for (const auto& entry : fs::directory_iterator(adiDirectoryPath))
		{
			if (entry.path().extension() == ".icloud")
			{
				// Move backup file to original location
				fs::path path = entry.path();
				path.replace_extension();

				fs::rename(entry.path(), path);

				odslog("Copying iCloud file from: " << entry.path().string() << " to: " << path.string());
			}
		}
	};

	// Calling CopyAnisetteData implicitly generates new anisette data,
	// using the new client info string we injected.
	ObjcObject* error = NULL;
	ObjcObject* anisetteDictionary = (ObjcObject*)CopyAnisetteData(NULL, 0x1, &error);

	try
	{
		if (anisetteDictionary == NULL)
		{
			odslog("Reprovision Error:" << ((ObjcObject*)error)->description());

			ObjcObject* localizedDescription = (ObjcObject*)((id(*)(id, SEL))objc_msgSend)(error, sel_registerName("localizedDescription"));
			if (localizedDescription)
			{
				int errorCode = ((int(*)(id, SEL))objc_msgSend)(error, sel_registerName("code"));
				throw LocalizedError(errorCode, localizedDescription->description());
			}
			else
			{
				throw ServerError(ServerErrorCode::InvalidAnisetteData);
			}
		}

		odslog("Reprovisioned Anisette:" << anisetteDictionary->description());

		AltServerApp::instance()->setReprovisionedDevice(true);

		// Call callback while machine is provisioned for AltServer.
		provisionCallback();
	}
	catch (std::exception &exception)
	{
		cleanUp();

		throw;
	}

	cleanUp();

	return true;
#endif
}

bool AnisetteDataManager::ResetProvisioning()
{
	std::string adiDirectoryPath = "C:\\ProgramData\\Apple Computer\\iTunes\\adi";

	// Remove existing AltServer .pb files so we can create new ones next time we provision this device.
	for (const auto& entry : fs::directory_iterator(adiDirectoryPath))
	{
		if (entry.path().extension() == ".altserver")
		{
			fs::remove(entry.path());
		}
	}

	return true;
}

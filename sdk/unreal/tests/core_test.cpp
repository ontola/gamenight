// Tests for the engine-free GameNight core of the Unreal plugin. No Unreal
// needed: scripts/test-unreal-sdk.py builds this with -fno-exceptions
// -fno-rtti, like an Unreal module, and runs it.
#include "GameNightCore.h"
#include "GameNightProtocol.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using gamenight::Client;
using gamenight::Config;
using gamenight::Event;
using gamenight::Json;
using gamenight::Pad;
using gamenight::Phase;

static int failures = 0;

#define EXPECT(cond)                                                          \
	do {                                                                      \
		if (!(cond)) {                                                        \
			std::fprintf(stderr, "%s:%d: expected %s\n", __FILE__, __LINE__, #cond); \
			++failures;                                                       \
		}                                                                     \
	} while (0)

static std::vector<Json> Sent(Client& client) {
	std::vector<Json> out;
	for (const std::string& text : client.TakeOutgoing()) {
		bool ok = false;
		out.push_back(Json::parse(text, &ok));
		EXPECT(ok);
	}
	return out;
}

static const Json* SentOfType(const std::vector<Json>& sent, const char* type) {
	for (const Json& msg : sent)
		if (msg["type"].str() == type) return &msg;
	return nullptr;
}

static std::vector<Event> Events(Client& client) {
	std::vector<Event> out;
	Event event;
	while (client.PollEvent(event)) out.push_back(event);
	return out;
}

static bool HasEvent(const std::vector<Event>& events, Event::Kind kind) {
	for (const Event& event : events)
		if (event.kind == kind) return true;
	return false;
}

static void Line(Client& client, const std::string& json) {
	const std::string line = json + "\n";
	client.Receive(line.data(), line.size());
}

static Client Launched() {
	Config config;
	config.game_id = "orb-rush";
	config.token = "launch-token";
	config.launched = true;
	return Client(config);
}

static const char* kPrepare =
	R"({"type":"prepare","game":"orb-rush","session":"s1",)"
	R"("seats":[{"index":0,"controller":"pad0","occupant":{"kind":"local","player_id":"ann"}},)"
	R"({"index":1,"controller":"pad1","occupant":{"kind":"local","player_id":"bo"}},)"
	R"({"index":2,"occupant":{"kind":"ai"}}],)"
	R"("players":[{"id":"ann","name":"Ann","color":"#e36c76","couch":1},{"id":"bo","name":"Bo","couch":0}]})";

static void TestJson() {
	bool ok = false;
	const Json value = Json::parse(R"( {"a":[1,2.5,-3e2,true,false,null],"s":"t\u00e9\ud83d\ude00\n\"x\"","o":{}} )", &ok);
	EXPECT(ok);
	EXPECT(value["a"].size() == 6);
	EXPECT(value["a"][1].number() == 2.5);
	EXPECT(value["a"][2].integer() == -300);
	EXPECT(value["a"][3].boolean());
	EXPECT(value["a"][5].is_null());
	EXPECT(value["s"].str() == "t\xc3\xa9\xf0\x9f\x98\x80\n\"x\"");
	EXPECT(value["o"].is_object() && value["o"].size() == 0);
	EXPECT(value["missing"]["deeper"][3].is_null());
	// Round trip keeps order and values.
	const Json again = Json::parse(value.dump(), &ok);
	EXPECT(ok && again == value);
	EXPECT(Json(3).dump() == "3");
	EXPECT(Json(0.1).dump() == "0.1");
	EXPECT(Json("a\x01").dump() == "\"a\\u0001\"");
	for (const char* bad : {"", "{", "[1,]", "{\"a\" 1}", "tru", "01x", "\"\\q\"", "[1] 2", "nan"}) {
		Json::parse(bad, &ok);
		EXPECT(!ok);
	}
	// Deep nesting fails instead of overflowing the stack.
	Json::parse(std::string(10000, '['), &ok);
	EXPECT(!ok);
}

static void TestHelloAndWelcome() {
	Client client = Launched();
	client.OnConnected();
	const std::vector<Json> hello = Sent(client);
	EXPECT(hello.size() == 1);
	EXPECT(hello[0]["type"].str() == "hello");
	EXPECT(hello[0]["role"].str() == "game");
	EXPECT(hello[0]["game"].str() == "orb-rush");
	EXPECT(hello[0]["token"].str() == "launch-token");

	Json settings = Json::MakeArray();
	settings.push(Json::MakeObject().set("key", "orbs").set("label", "Orbs").set("kind", "number").set("default", 6));
	client.DeclareSettings(settings);
	client.DeclareActions(Json::MakeArray().push(Json::MakeObject().set("key", "new_round").set("label", "New round")));
	client.DeclareCompanion("/tmp/phone", "index.html");
	EXPECT(Sent(client).size() == 3);

	// Fragmented across reads, with a blank keepalive line in between.
	const std::string welcome = "\n{\"type\":\"welcome\",\"protocol_version\":1,\"party\":{\"players\":[]}}\n";
	client.Receive(welcome.data(), 10);
	EXPECT(Events(client).empty());
	client.Receive(welcome.data() + 10, welcome.size() - 10);
	const std::vector<Event> events = Events(client);
	EXPECT(HasEvent(events, Event::Kind::Connected));
	EXPECT(client.connected());
	// A (re)connect declares everything again so the host replays values.
	const std::vector<Json> again = Sent(client);
	EXPECT(SentOfType(again, "declare_settings") != nullptr);
	EXPECT(SentOfType(again, "declare_actions") != nullptr);
	EXPECT(SentOfType(again, "declare_companion") != nullptr);
	EXPECT((*SentOfType(again, "declare_companion"))["root"].str() == "/tmp/phone");

	client.OnDisconnected();
	EXPECT(HasEvent(Events(client), Event::Kind::Disconnected));
	EXPECT(!client.connected());
}

static void TestLifecycle() {
	Client client = Launched();
	client.OnConnected();
	Line(client, R"({"type":"welcome","protocol_version":1,"party":{}})");
	Sent(client);
	Events(client);

	// Lifecycle messages without a prepared session are ignored.
	Line(client, R"({"type":"start","session":"s1"})");
	EXPECT(client.phase() == Phase::Idle);
	// A prepare for another game is not ours.
	Line(client, R"({"type":"prepare","game":"other","session":"x","seats":[],"players":[]})");
	EXPECT(client.session().empty());

	Line(client, kPrepare);
	std::vector<Event> events = Events(client);
	EXPECT(HasEvent(events, Event::Kind::Prepared));
	EXPECT(client.phase() == Phase::Preparing);
	EXPECT(client.session() == "s1");
	EXPECT(client.LocalSeatCount() == 2);
	EXPECT(client.AiSeatCount() == 1);
	EXPECT(client.player_for_seat(1)["name"].str() == "Bo");
	EXPECT(client.player_for_seat(2).is_null());
	const std::vector<Json> couch = client.CouchOrder();
	EXPECT(couch.size() == 3 && couch[0]["index"].integer() == 1 && couch[1]["index"].integer() == 0 && couch[2]["index"].integer() == 2);

	// Start before Ready is not allowed.
	Line(client, R"({"type":"start","session":"s1"})");
	EXPECT(client.phase() == Phase::Preparing);
	client.Participation(true);
	client.Progress(150, "arena");
	client.Ready();
	std::vector<Json> sent = Sent(client);
	EXPECT(SentOfType(sent, "participation") && (*SentOfType(sent, "participation"))["instant_join"].boolean());
	EXPECT(SentOfType(sent, "progress") && (*SentOfType(sent, "progress"))["percent"].integer() == 100);
	EXPECT(SentOfType(sent, "ready") && (*SentOfType(sent, "ready"))["session"].str() == "s1");
	EXPECT(client.phase() == Phase::Ready);
	client.Ready();
	EXPECT(Sent(client).empty());  // once

	// Messages for another session are ignored.
	Line(client, R"({"type":"start","session":"old"})");
	EXPECT(client.phase() == Phase::Ready);
	Line(client, R"({"type":"start","session":"s1"})");
	EXPECT(client.phase() == Phase::Running);
	EXPECT(HasEvent(Events(client), Event::Kind::Started));
	Line(client, R"({"type":"pause","session":"s1"})");
	EXPECT(client.phase() == Phase::Paused);
	EXPECT(HasEvent(Events(client), Event::Kind::Paused));
	Line(client, R"({"type":"resume","session":"s1"})");
	EXPECT(client.phase() == Phase::Running);
	EXPECT(HasEvent(Events(client), Event::Kind::Resumed));

	client.Finished();
	client.RoomLog("Ann won round 1");
	sent = Sent(client);
	EXPECT(SentOfType(sent, "finished") != nullptr);
	EXPECT(SentOfType(sent, "room_log") && (*SentOfType(sent, "room_log"))["text"].str() == "Ann won round 1");
	EXPECT(client.phase() == Phase::Running);  // a round ends, the session goes on

	// A new prepare while one runs disposes the old session first.
	std::string second = kPrepare;
	second.replace(second.find("\"s1\""), 4, "\"s2\"");
	Line(client, second);
	events = Events(client);
	EXPECT(events.size() >= 2 && events[0].kind == Event::Kind::Disposed && events[0].session == "s1");
	EXPECT(HasEvent(events, Event::Kind::Prepared));
	EXPECT(client.session() == "s2");
	Line(client, R"({"type":"dispose","session":"s2"})");
	events = Events(client);
	EXPECT(HasEvent(events, Event::Kind::Disposed));
	EXPECT(client.session().empty() && client.phase() == Phase::Idle);
}

static Client Running() {
	Client client = Launched();
	client.OnConnected();
	Line(client, R"({"type":"welcome","protocol_version":1,"party":{}})");
	Line(client, kPrepare);
	client.Ready();
	Line(client, R"({"type":"start","session":"s1"})");
	Sent(client);
	Events(client);
	return client;
}

static void Frame(Client& client, uint32_t pad0_buttons, int left_x = 0, int trigger = 0) {
	Line(client, R"({"type":"controller_frame","controllers":[{"controller":"pad0","axes":[)" + std::to_string(left_x) +
	                 ",0,0,0,0," + std::to_string(trigger) + R"(],"buttons":)" + std::to_string(pad0_buttons) +
	                 R"(},{"controller":"pad1","axes":[0,0,0,0,0,0],"buttons":0}]})");
}

static void TestInput() {
	Client client = Running();
	double now = 1.0;
	// The first tick sees no input yet; then the pad still holds A from the lobby.
	client.Tick(now);
	Frame(client, 1u << gamenight::BUTTON_A, 32767, 16000);
	Pad pad = client.PadForSeat(0);
	EXPECT(pad.present && pad.button(gamenight::BUTTON_A) && !pad.button(gamenight::BUTTON_B));
	EXPECT(pad.axis(gamenight::AXIS_LEFT_X) == 1.0f);
	EXPECT(gamenight::Stick(pad).x == 1.0f);
	EXPECT(gamenight::Trigger(pad, 1) > 0.4f && gamenight::Trigger(pad, 1) < 0.5f);
	EXPECT(!client.PadForSeat(2).present);  // a bot seat has no pad
	EXPECT(!client.PadForSeat(9).present);

	// A held button from the lobby does not count as a press after Start.
	client.Tick(now += 0.016);
	EXPECT(!client.JustPressed(0, gamenight::BUTTON_A));
	Frame(client, 1u << gamenight::BUTTON_A);
	client.Tick(now += 0.016);
	EXPECT(!client.JustPressed(0, gamenight::BUTTON_A));
	Frame(client, 0);
	client.Tick(now += 0.016);
	Frame(client, 1u << gamenight::BUTTON_A);
	client.Tick(now += 0.016);
	EXPECT(client.JustPressed(0, gamenight::BUTTON_A));
	client.Tick(now += 0.016);
	EXPECT(!client.JustPressed(0, gamenight::BUTTON_A));  // one tick only

	// Stale input reads neutral.
	client.Tick(now += 0.3);
	EXPECT(!client.PadForSeat(0).present);
	Frame(client, 1u << gamenight::BUTTON_START);
	EXPECT(client.PadForSeat(0).button(gamenight::BUTTON_START));

	// Paused: neutral unless asked for any phase (an in-game menu).
	Line(client, R"({"type":"pause","session":"s1"})");
	EXPECT(!client.PadForSeat(0).present);
	EXPECT(client.PadForSeat(0, true).present);
	Line(client, R"({"type":"resume","session":"s1"})");

	// Activity: at most once a second per controller.
	client.ReportActivity(0);
	client.ReportActivity(0);
	std::vector<Json> sent = Sent(client);
	EXPECT(sent.size() == 1 && sent[0]["type"].str() == "controller_input" && sent[0]["controller"].str() == "pad0");
	client.Tick(now += 1.1);
	client.ReportActivity(0);
	EXPECT(Sent(client).size() == 1);

	// Rumble: scaled to XInput motors, one stop only.
	client.Rumble(1, 0.5f, 1.0f, 9.0f);
	client.Rumble(1, 0.0f, 0.0f, 0.0f);
	client.Rumble(1, 0.0f, 0.0f, 0.0f);
	sent = Sent(client);
	EXPECT(sent.size() == 2);
	EXPECT(sent[0]["seat"].integer() == 1 && sent[0]["weak"].integer() == 32767 && sent[0]["strong"].integer() == 65535 &&
	       sent[0]["ms"].integer() == 5000);
	EXPECT(sent[1]["weak"].integer() == 0);
}

static void TestSettingsSavesPhones() {
	Client client = Running();
	Line(client, R"({"type":"setting_changed","game":"orb-rush","key":"orbs","value":9})");
	std::vector<Event> events = Events(client);
	EXPECT(events.size() == 1 && events[0].kind == Event::Kind::SettingChanged && events[0].key == "orbs" &&
	       events[0].value.integer() == 9);
	EXPECT(client.setting("orbs").integer() == 9);
	client.SetSetting("orbs", 10);
	std::vector<Json> sent = Sent(client);
	EXPECT(sent.size() == 1 && sent[0]["type"].str() == "set_setting" && sent[0]["value"].integer() == 10);

	Line(client, R"({"type":"player_settings","game":"orb-rush","player_id":"ann","values":{"hat":"crown"}})");
	events = Events(client);
	EXPECT(events.size() == 1 && events[0].player_id == "ann");
	EXPECT(client.player_setting("ann", "hat").str() == "crown");
	EXPECT(client.player_setting("bo", "hat").is_null());

	Line(client, R"({"type":"player_data","game":"orb-rush","player_id":"ann","data":{"best":4,"unlocks":["gold"]},"revision":3})");
	EXPECT(Events(client).size() == 1);
	EXPECT(client.player_data("ann")["best"].integer() == 4);
	client.SavePlayerData("ann", Json::MakeObject().set("best", 7));
	sent = Sent(client);
	EXPECT(sent.size() == 1 && sent[0]["expected_revision"].integer() == 3 && sent[0]["data"]["best"].integer() == 7);
	client.SavePlayerData("bo", Json::MakeObject().set("best", 1));
	sent = Sent(client);
	EXPECT(sent.size() == 1 && sent[0]["expected_revision"].integer() == 0);

	Line(client, R"({"type":"player_data","game":"orb-rush","player_id":"ann","data":{"unlocks":["gold"]},"revision":4})");
	Events(client);
	EXPECT(client.PartyUnion().size() == 1);
	client.UnlockForPresent("silver");
	sent = Sent(client);
	EXPECT(sent.size() == 2);  // Ann and Bo
	client.UnlockForPresent("silver");
	EXPECT(Sent(client).empty());
	EXPECT(client.PartyUnion().size() == 2);

	Line(client, R"({"type":"action_triggered","key":"new_round","player_id":"bo"})");
	events = Events(client);
	EXPECT(events.size() == 1 && events[0].kind == Event::Kind::ActionTriggered && events[0].key == "new_round" &&
	       events[0].player_id == "bo");

	Line(client, R"({"type":"companion_presence","player_id":"ann","connected":true})");
	Line(client, R"({"type":"companion_message","player_id":"ann","data":{"tap":"boost"}})");
	events = Events(client);
	EXPECT(events.size() == 2 && events[0].connected && events[1].value["tap"].str() == "boost");
	client.SendCompanionMessage(Json::MakeObject().set("score", 3), "ann");
	client.SendCompanionMessage(Json::MakeObject().set("all", true));
	sent = Sent(client);
	EXPECT(sent.size() == 2 && sent[0]["player_id"].str() == "ann" && !sent[1].has("player_id"));
}

static void TestRoster() {
	Client client = Running();
	Line(client, R"({"type":"players_updated","session":"s1","players":[{"id":"ann","name":"Annie","color":"#4daf7c"}]})");
	std::vector<Event> events = Events(client);
	EXPECT(HasEvent(events, Event::Kind::PlayersUpdated));
	EXPECT(client.player("ann")["name"].str() == "Annie");
	EXPECT(client.player("bo")["name"].str() == "Bo");
	EXPECT(client.phase() == Phase::Running);  // never restart over a profile change

	Line(client, R"({"type":"party_updated","session":"s1","seats":[{"index":0,"controller":"pad0","occupant":{"kind":"local","player_id":"ann"}},{"index":3,"controller":"pad3","occupant":{"kind":"local","player_id":"cy"}}],"players":[{"id":"ann","name":"Annie"},{"id":"cy","name":"Cy"}],"presence":[]})");
	events = Events(client);
	EXPECT(HasEvent(events, Event::Kind::RosterChanged));
	EXPECT(client.LocalSeatCount() == 2 && client.player_for_seat(3)["name"].str() == "Cy");
	Line(client, R"({"type":"party_updated","session":"other","seats":[],"players":[],"presence":[]})");
	EXPECT(client.LocalSeatCount() == 2);
}

static void TestPerformance() {
	Client client = Running();
	gamenight::DeviceInfo device;
	device.cpu = "Test CPU";
	device.gpu = "Test GPU";
	device.os = "Linux";
	device.memory_mib = 16384;
	client.SetDeviceInfo(device);
	client.SetWindowSize(1920, 1080);
	double now = 10.0;
	for (int i = 0; i < 500; ++i) client.Tick(now += 1.0 / 60.0);
	client.Tick(now += 0.05);  // one slow frame
	EXPECT(Sent(client).empty());
	for (int i = 0; i < 1000; ++i) client.Tick(now += 1.0 / 60.0);
	const std::vector<Json> sent = Sent(client);
	const Json* msg = SentOfType(sent, "performance");
	EXPECT(msg != nullptr);
	if (msg) {
		const Json& sample = (*msg)["sample"];
		EXPECT(sample["frames"].integer() >= 590);
		EXPECT(sample["slow_frames"].integer() == 1);
		EXPECT(sample["max_frame_us"].integer() >= 49000);
		EXPECT(sample["width"].integer() == 1920 && sample["gpu"].str() == "Test GPU");
	}
	// Paused time is not measured.
	Line(client, R"({"type":"pause","session":"s1"})");
	for (int i = 0; i < 1000; ++i) client.Tick(now += 1.0 / 60.0);
	EXPECT(Sent(client).empty());
}

static void TestFaces() {
	std::string px;
	for (int i = 0; i < 48 * 48; ++i) px += std::string(i ? "," : "") + (i == 0 ? "\"#ff0000\"" : "null");
	const gamenight::FaceImage face = gamenight::DecodeAvatar("{\"v\":1,\"w\":48,\"h\":48,\"px\":[" + px + "]}");
	EXPECT(face.valid() && face.width == 48 && face.rgba.size() == 48u * 48u * 4u);
	EXPECT(face.rgba[0] == 255 && face.rgba[1] == 0 && face.rgba[3] == 255);
	EXPECT(face.rgba[7] == 0);  // null is transparent
	EXPECT(face.center_x == 24.0f && face.center_y == 28.0f);
	EXPECT(!gamenight::DecodeAvatar("").valid());
	EXPECT(!gamenight::DecodeAvatar("{\"v\":1,\"w\":2,\"h\":2,\"px\":[null]}").valid());
	EXPECT(!gamenight::DecodeAvatar("{\"v\":1,\"w\":1.5,\"h\":1,\"px\":[null]}").valid());
	// Legacy square arrays, with their old transparent colour.
	std::string legacy = "[";
	for (int i = 0; i < 16 * 16; ++i) legacy += std::string(i ? "," : "") + (i == 1 ? "\"#0F172A\"" : "\"#00ff00\"");
	const gamenight::FaceImage old = gamenight::DecodeAvatar(legacy + "]");
	EXPECT(old.valid() && old.width == 16 && old.rgba[3] == 255 && old.rgba[7] == 0);
	EXPECT(old.center_x == 24.0f - 22.0f && old.center_y == 28.0f - 23.0f);
	uint8_t rgb[3] = {1, 2, 3};
	EXPECT(gamenight::ParseHexColor("#E36C76", rgb) && rgb[0] == 0xe3 && rgb[2] == 0x76);
	EXPECT(!gamenight::ParseHexColor("e36c76", rgb));
}

static void TestStandalone() {
	Config config;
	config.game_id = "orb-rush";
	Client client(config);
	// Nothing goes out before the socket says hello.
	client.DeclareSettings(Json::MakeArray());
	EXPECT(Sent(client).empty());
	client.OnConnected();
	const std::vector<Json> sent = Sent(client);
	EXPECT(sent.size() == 1 && !sent[0].has("token"));
}

int main() {
	TestJson();
	TestHelloAndWelcome();
	TestLifecycle();
	TestInput();
	TestSettingsSavesPhones();
	TestRoster();
	TestPerformance();
	TestFaces();
	TestStandalone();
	if (failures) {
		std::fprintf(stderr, "%d check(s) failed\n", failures);
		return 1;
	}
	std::printf("unreal core: all checks passed\n");
	return 0;
}

// GameNight protocol core: the whole game side of the GameNight protocol in
// plain C++17, with no engine headers. The Unreal subsystem
// (UGameNightSubsystem) is a thin wrapper around it: it owns the socket, feeds
// received bytes in, sends what the core queues, and turns events into
// Blueprint delegates. Any other C++ engine can wrap it the same way.
//
// The core never blocks, allocates no threads and owns no socket. It only
// needs to hear about time (tick) and bytes (receive), so the tests in
// sdk/unreal/tests drive it without Unreal.
//
// No exceptions and no RTTI: Unreal builds without either.
#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <map>
#include <string>
#include <vector>

namespace gamenight {

// ---------------------------------------------------------------------------
// A small JSON value. Objects keep insertion order, numbers are doubles.
// ---------------------------------------------------------------------------
class Json {
public:
	enum class Type : uint8_t { Null, Bool, Number, String, Array, Object };

	Json() = default;
	Json(std::nullptr_t) {}
	Json(bool value) : type_(Type::Bool), bool_(value) {}
	Json(int value) : type_(Type::Number), number_(static_cast<double>(value)) {}
	Json(unsigned value) : type_(Type::Number), number_(static_cast<double>(value)) {}
	Json(long value) : type_(Type::Number), number_(static_cast<double>(value)) {}
	Json(unsigned long value) : type_(Type::Number), number_(static_cast<double>(value)) {}
	Json(long long value) : type_(Type::Number), number_(static_cast<double>(value)) {}
	Json(unsigned long long value) : type_(Type::Number), number_(static_cast<double>(value)) {}
	Json(float value) : type_(Type::Number), number_(static_cast<double>(value)) {}
	Json(double value) : type_(Type::Number), number_(value) {}
	Json(const char* value) : type_(Type::String), string_(value ? value : "") {}
	Json(std::string value) : type_(Type::String), string_(std::move(value)) {}

	static Json MakeArray();
	static Json MakeObject();

	Type type() const { return type_; }
	bool is_null() const { return type_ == Type::Null; }
	bool is_bool() const { return type_ == Type::Bool; }
	bool is_number() const { return type_ == Type::Number; }
	bool is_string() const { return type_ == Type::String; }
	bool is_array() const { return type_ == Type::Array; }
	bool is_object() const { return type_ == Type::Object; }

	bool boolean(bool fallback = false) const { return type_ == Type::Bool ? bool_ : fallback; }
	double number(double fallback = 0.0) const { return type_ == Type::Number ? number_ : fallback; }
	int64_t integer(int64_t fallback = 0) const;
	// The string value, or `fallback` for anything that is not a string.
	std::string str(const std::string& fallback = std::string()) const { return type_ == Type::String ? string_ : fallback; }

	// Arrays and objects. Reading a missing index or key gives null.
	size_t size() const { return items_.size(); }
	const Json& operator[](size_t index) const;
	const Json& operator[](const std::string& key) const;
	const Json& operator[](const char* key) const { return (*this)[std::string(key)]; }
	bool has(const std::string& key) const;
	Json* find(const std::string& key);
	// Sets a key (turning null into an object). Returns *this for chaining.
	Json& set(const std::string& key, Json value);
	void erase(const std::string& key);
	// Appends (turning null into an array). Returns *this for chaining.
	Json& push(Json value);
	const std::vector<Json>& items() const { return items_; }
	std::vector<Json>& items() { return items_; }
	const std::vector<std::string>& keys() const { return keys_; }

	std::string dump() const;
	// Parses one JSON text. On failure returns null and sets *ok to false.
	static Json parse(const std::string& text, bool* ok = nullptr);

	bool operator==(const Json& other) const;
	bool operator!=(const Json& other) const { return !(*this == other); }

private:
	void dump_to(std::string& out) const;
	Type type_ = Type::Null;
	bool bool_ = false;
	double number_ = 0.0;
	std::string string_;
	std::vector<std::string> keys_;  // objects only, parallel to items_
	std::vector<Json> items_;        // array items, or object values
};

// ---------------------------------------------------------------------------
// Controllers
// ---------------------------------------------------------------------------

// Button bits and axis indices of a controller frame (docs/protocol.md).
enum Button : int {
	BUTTON_A = 0,
	BUTTON_B = 1,
	BUTTON_X = 2,
	BUTTON_Y = 3,
	BUTTON_LB = 4,
	BUTTON_RB = 5,
	BUTTON_BACK = 6,  // Owned by GameNight: never bind it in a game.
	BUTTON_START = 7,
	BUTTON_LS = 8,
	BUTTON_RS = 9,
	BUTTON_UP = 10,
	BUTTON_DOWN = 11,
	BUTTON_LEFT = 12,
	BUTTON_RIGHT = 13,
	BUTTON_COUNT = 14,
};

enum Axis : int {
	AXIS_LEFT_X = 0,
	AXIS_LEFT_Y = 1,  // Up is negative.
	AXIS_RIGHT_X = 2,
	AXIS_RIGHT_Y = 3,
	AXIS_LEFT_TRIGGER = 4,
	AXIS_RIGHT_TRIGGER = 5,
	AXIS_COUNT = 6,
};

// Deadzones the GameNight games settled on.
inline constexpr float STICK_DEADZONE = 0.15f;
inline constexpr float TRIGGER_DEADZONE = 0.06f;
// Input older than this counts as released.
inline constexpr double FRAME_STALE_SECONDS = 0.25;

// One seat's controller, as the host last sent it. Missing, disconnected and
// stale input is neutral: present is false and everything reads zero.
struct Pad {
	bool present = false;
	std::string controller;
	uint32_t buttons = 0;
	float axes[AXIS_COUNT] = {0, 0, 0, 0, 0, 0};  // -1 to 1

	bool button(int index) const { return index >= 0 && index < BUTTON_COUNT && (buttons & (1u << index)) != 0; }
	float axis(int index) const { return index >= 0 && index < AXIS_COUNT ? axes[index] : 0.0f; }
};

struct Vec2 {
	float x = 0.0f;
	float y = 0.0f;
};

// A stick with a radial deadzone, rescaled so it starts at 0. `side` 0 is the
// left stick, 1 the right one. Up is negative y.
Vec2 Stick(const Pad& pad, int side = 0, float deadzone = STICK_DEADZONE);
// A trigger from 0 to 1 with a deadzone. `side` 0 is the left trigger.
float Trigger(const Pad& pad, int side = 0, float deadzone = TRIGGER_DEADZONE);

// ---------------------------------------------------------------------------
// Faces (docs/faces.md)
// ---------------------------------------------------------------------------

// A player's drawn face as RGBA pixels, with the head centre in source pixels.
// Draw the skin circle yourself at (x, y) with radius R, then the image scaled
// by R / AVATAR_HEAD_RADIUS with `center` placed on (x, y). Nearest filtering.
struct FaceImage {
	int width = 0;
	int height = 0;
	float center_x = 0.0f;
	float center_y = 0.0f;
	std::vector<uint8_t> rgba;  // width * height * 4, row by row from the top
	bool valid() const { return width > 0 && height > 0; }
};

// Decodes players[].avatar. Invalid or empty payloads give an invalid image:
// draw the default face then.
FaceImage DecodeAvatar(const std::string& payload);
// "#rrggbb" to bytes. False (and `rgb` untouched) for anything else.
bool ParseHexColor(const std::string& text, uint8_t rgb[3]);

// ---------------------------------------------------------------------------
// The client
// ---------------------------------------------------------------------------

enum class Phase : uint8_t { Idle, Preparing, Ready, Running, Paused };

struct Event {
	enum class Kind : uint8_t {
		Connected,              // welcome arrived
		Disconnected,           // the host went away (a launched game should quit)
		PartyUpdated,           // party() changed
		Prepared,               // session: load hidden for seats()/players(), then Ready()
		Started,                // session: show play now
		Paused,                 // session: freeze simulation, timers and audio
		Resumed,                // session
		Disposed,               // session: tear down; the id is never used again
		RosterChanged,          // seats()/players() changed mid-session (participation)
		PlayersUpdated,         // value: the players whose name, colour or face changed
		SettingChanged,         // key, value
		PlayerSettingsChanged,  // player_id, value: that player's own settings
		PlayerDataChanged,      // player_id, value: saved progress
		ActionTriggered,        // key, player_id: a phone button
		CompanionMessage,       // player_id, value: untrusted JSON from a phone page
		CompanionPresence,      // player_id, connected
		Warning,                // text: something the developer should read
	};
	Kind kind = Kind::Warning;
	std::string session;
	std::string key;
	std::string player_id;
	std::string text;
	bool connected = false;
	Json value;
};

struct Config {
	std::string game_id;
	// GAMENIGHT_TOKEN. Required when GameNight launched the game.
	std::string token;
	// GAMENIGHT=1: GameNight launched this process.
	bool launched = false;
};

// What the core reports about the machine in its performance samples. Never
// put serial numbers, paths or machine names in here.
struct DeviceInfo {
	std::string cpu;
	std::string gpu;
	std::string os;
	uint64_t memory_mib = 0;
};

class Client {
public:
	explicit Client(Config config);

	// -- transport -----------------------------------------------------------
	// The socket connected: queues hello. Call before anything else.
	void OnConnected();
	// The socket closed. Queues Disconnected when the host had answered.
	void OnDisconnected();
	// Bytes from the plain (newline-delimited) transport, in any chunking.
	void Receive(const char* data, size_t size);
	// One whole message, for transports that frame messages themselves.
	void Handle(const std::string& message);
	void Handle(const Json& message);
	// Messages waiting to be sent, one JSON text each (no newline).
	std::vector<std::string> TakeOutgoing();
	bool HasOutgoing() const { return !outgoing_.empty(); }

	// Call once per frame with a monotonic clock, also while paused, before
	// Receive(). Drives stale input, button edges and performance samples.
	void Tick(double now_seconds);
	bool PollEvent(Event& out);

	// -- state ---------------------------------------------------------------
	const Config& config() const { return config_; }
	bool connected() const { return welcomed_; }
	Phase phase() const { return phase_; }
	const std::string& session() const { return session_; }
	const Json& party() const { return party_; }
	const Json& seats() const { return party_["seats"]; }
	const Json& players() const { return party_["players"]; }
	// A player of this party by id, or null.
	const Json& player(const std::string& id) const;
	// The player sitting in this seat, or null for bots and empty seats.
	const Json& player_for_seat(int seat_index) const;
	int LocalSeatCount() const;
	int AiSeatCount() const;
	// Seats left to right as the players sit on the couch (players[].couch);
	// bots and seats without a couch place keep seat order after the people.
	std::vector<Json> CouchOrder() const;

	// -- lifecycle -----------------------------------------------------------
	// Assets loaded and inputs bound: the session can start instantly.
	void Ready();
	// A round ended. The session keeps going: show results, then play on.
	void Finished();
	// One short line for the room log in the app (rare: a round, a run).
	void RoomLog(const std::string& text);
	// Opt into live roster updates for this session. Call before Ready().
	void Participation(bool instant_join);
	// How far loading is, 0 to 100.
	void Progress(int percent, const std::string& label = std::string());
	// Back to the party: the host pauses this session and shows the lobby.
	void RequestOverlay();
	// The player reached for this window directly (a click, Alt+Tab).
	void RequestStart();

	// -- input ---------------------------------------------------------------
	// Host input for a seat. Neutral unless the session is running; pass
	// any_phase = true to read it anyway (your own Start menu).
	Pad PadForSeat(int seat_index, bool any_phase = false) const;
	// True on the tick a seat's button went down. After Start and Resume a
	// button still held from the lobby must be released first.
	bool JustPressed(int seat_index, int button) const;
	// A person is really playing on this seat (at most once a second).
	void ReportActivity(int seat_index);
	// Vibrate this seat's pad: weak and strong 0 to 1, for seconds (max 5).
	void Rumble(int seat_index, float weak, float strong, float seconds);

	// -- settings, actions, saves ----------------------------------------------
	// An array of setting specs (docs/protocol.md). Re-sent after reconnects.
	void DeclareSettings(const Json& settings);
	// An array of phone buttons {key, label, description?, confirm?}.
	void DeclareActions(const Json& actions);
	void SetSetting(const std::string& key, const Json& value);
	// The latest value the host sent for a party setting, or null.
	const Json& setting(const std::string& key) const;
	void SetPlayerSetting(const std::string& player_id, const std::string& key, const Json& value);
	const Json& player_setting(const std::string& player_id, const std::string& key) const;
	// A player's saved progress, or null when nothing is saved yet.
	const Json& player_data(const std::string& player_id) const;
	void SavePlayerData(const std::string& player_id, const Json& data);
	// Everything in list `key` of the saved progress of the players here now.
	Json PartyUnion(const std::string& key = "unlocks") const;
	// Adds `item` to list `key` in the saved progress of every player here.
	void UnlockForPresent(const Json& item, const std::string& key = "unlocks");

	// -- phone screens -----------------------------------------------------------
	// `root` is an absolute directory the host may serve, `entry` a page in it.
	// `app` is optional: {name, android, download}.
	void DeclareCompanion(const std::string& root, const std::string& entry, const Json& app = Json());
	// To one player's phone, or to every phone when player_id is empty.
	void SendCompanionMessage(const Json& data, const std::string& player_id = std::string());

	// -- performance ----------------------------------------------------------
	void SetDeviceInfo(DeviceInfo info) { device_ = std::move(info); }
	void SetWindowSize(int width, int height) { width_ = width; height_ = height; }

private:
	void Send(Json message);
	void Emit(Event event) { events_.push_back(std::move(event)); }
	void EmitSession(Event::Kind kind);
	void UpdateButtons();
	void HoldButtons();
	void SamplePerformance(double now);
	void ResetPerformance();
	std::string ControllerForSeat(int seat_index) const;

	Config config_;
	std::deque<Event> events_;
	std::vector<std::string> outgoing_;
	std::string inbox_;
	bool said_hello_ = false;
	bool welcomed_ = false;

	Json party_ = Json::MakeObject();
	std::string session_;
	Phase phase_ = Phase::Idle;

	double now_ = 0.0;
	double frame_at_ = -1000.0;
	std::map<std::string, Pad> frames_;
	std::map<int, uint32_t> buttons_now_;
	std::map<int, uint32_t> buttons_before_;
	std::map<int, uint32_t> buttons_blocked_;
	std::map<std::string, double> activity_at_;
	std::map<int, bool> rumble_quiet_;

	Json declared_settings_;
	Json declared_actions_;
	Json declared_companion_;
	std::map<std::string, Json> settings_;
	std::map<std::string, Json> player_settings_;
	std::map<std::string, Json> player_data_;
	std::map<std::string, int64_t> player_data_revision_;

	DeviceInfo device_;
	int width_ = 0;
	int height_ = 0;
	bool perf_running_ = false;
	double perf_last_ = -1.0;
	uint64_t perf_frames_ = 0;
	uint64_t perf_elapsed_us_ = 0;
	uint64_t perf_slow_frames_ = 0;
	uint64_t perf_max_frame_us_ = 0;
	uint64_t perf_sent_us_ = 0;
};

const char* PhaseName(Phase phase);

}  // namespace gamenight

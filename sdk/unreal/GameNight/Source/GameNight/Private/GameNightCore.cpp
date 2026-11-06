// See GameNightCore.h. Mirrors sdk/godot/addons/gamenight/gamenight.gd, the
// reference integration: when one changes, check the other.
#include "GameNightCore.h"

#include "GameNightProtocol.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace gamenight {

namespace {

const Json& NullJson() {
	static const Json value;
	return value;
}

// ---- JSON parsing ----------------------------------------------------------

constexpr int kMaxDepth = 128;

struct JsonParser {
	const char* at;
	const char* end;
	bool failed = false;

	void SkipSpace() {
		while (at < end && (*at == ' ' || *at == '\t' || *at == '\n' || *at == '\r')) ++at;
	}

	bool Literal(const char* word) {
		const size_t length = std::strlen(word);
		if (static_cast<size_t>(end - at) < length || std::memcmp(at, word, length) != 0) return false;
		at += length;
		return true;
	}

	static void AppendUtf8(std::string& out, uint32_t code) {
		if (code < 0x80) {
			out += static_cast<char>(code);
		} else if (code < 0x800) {
			out += static_cast<char>(0xC0 | (code >> 6));
			out += static_cast<char>(0x80 | (code & 0x3F));
		} else if (code < 0x10000) {
			out += static_cast<char>(0xE0 | (code >> 12));
			out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
			out += static_cast<char>(0x80 | (code & 0x3F));
		} else {
			out += static_cast<char>(0xF0 | (code >> 18));
			out += static_cast<char>(0x80 | ((code >> 12) & 0x3F));
			out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
			out += static_cast<char>(0x80 | (code & 0x3F));
		}
	}

	bool Hex4(uint32_t& out) {
		if (end - at < 4) return false;
		out = 0;
		for (int i = 0; i < 4; ++i) {
			const char c = *at++;
			out <<= 4;
			if (c >= '0' && c <= '9') out |= static_cast<uint32_t>(c - '0');
			else if (c >= 'a' && c <= 'f') out |= static_cast<uint32_t>(c - 'a' + 10);
			else if (c >= 'A' && c <= 'F') out |= static_cast<uint32_t>(c - 'A' + 10);
			else return false;
		}
		return true;
	}

	bool String(std::string& out) {
		if (at >= end || *at != '"') return false;
		++at;
		while (at < end) {
			const char c = *at++;
			if (c == '"') return true;
			if (static_cast<unsigned char>(c) < 0x20) return false;
			if (c != '\\') {
				out += c;
				continue;
			}
			if (at >= end) return false;
			const char escape = *at++;
			switch (escape) {
			case '"': out += '"'; break;
			case '\\': out += '\\'; break;
			case '/': out += '/'; break;
			case 'b': out += '\b'; break;
			case 'f': out += '\f'; break;
			case 'n': out += '\n'; break;
			case 'r': out += '\r'; break;
			case 't': out += '\t'; break;
			case 'u': {
				uint32_t code = 0;
				if (!Hex4(code)) return false;
				if (code >= 0xD800 && code <= 0xDBFF) {
					uint32_t low = 0;
					if (end - at >= 6 && at[0] == '\\' && at[1] == 'u') {
						at += 2;
						if (!Hex4(low)) return false;
					}
					if (low >= 0xDC00 && low <= 0xDFFF) code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
					else code = 0xFFFD;
				} else if (code >= 0xDC00 && code <= 0xDFFF) {
					code = 0xFFFD;
				}
				AppendUtf8(out, code);
				break;
			}
			default: return false;
			}
		}
		return false;
	}

	bool Number(double& out) {
		const char* start = at;
		if (at < end && *at == '-') ++at;
		if (at >= end || !(*at >= '0' && *at <= '9')) return false;
		while (at < end && *at >= '0' && *at <= '9') ++at;
		if (at < end && *at == '.') {
			++at;
			if (at >= end || !(*at >= '0' && *at <= '9')) return false;
			while (at < end && *at >= '0' && *at <= '9') ++at;
		}
		if (at < end && (*at == 'e' || *at == 'E')) {
			++at;
			if (at < end && (*at == '+' || *at == '-')) ++at;
			if (at >= end || !(*at >= '0' && *at <= '9')) return false;
			while (at < end && *at >= '0' && *at <= '9') ++at;
		}
		const std::string text(start, at);
		out = std::strtod(text.c_str(), nullptr);
		return std::isfinite(out);
	}

	Json Value(int depth) {
		if (depth > kMaxDepth) {
			failed = true;
			return Json();
		}
		SkipSpace();
		if (at >= end) {
			failed = true;
			return Json();
		}
		const char c = *at;
		if (c == '{') {
			++at;
			Json object = Json::MakeObject();
			SkipSpace();
			if (at < end && *at == '}') {
				++at;
				return object;
			}
			for (;;) {
				SkipSpace();
				std::string key;
				if (!String(key)) break;
				SkipSpace();
				if (at >= end || *at != ':') break;
				++at;
				Json member = Value(depth + 1);
				if (failed) return Json();
				object.set(key, std::move(member));
				SkipSpace();
				if (at < end && *at == ',') {
					++at;
					continue;
				}
				if (at < end && *at == '}') {
					++at;
					return object;
				}
				break;
			}
			failed = true;
			return Json();
		}
		if (c == '[') {
			++at;
			Json array = Json::MakeArray();
			SkipSpace();
			if (at < end && *at == ']') {
				++at;
				return array;
			}
			for (;;) {
				Json item = Value(depth + 1);
				if (failed) return Json();
				array.push(std::move(item));
				SkipSpace();
				if (at < end && *at == ',') {
					++at;
					continue;
				}
				if (at < end && *at == ']') {
					++at;
					return array;
				}
				break;
			}
			failed = true;
			return Json();
		}
		if (c == '"') {
			std::string text;
			if (!String(text)) {
				failed = true;
				return Json();
			}
			return Json(std::move(text));
		}
		if (Literal("true")) return Json(true);
		if (Literal("false")) return Json(false);
		if (Literal("null")) return Json();
		double number = 0.0;
		if (Number(number)) return Json(number);
		failed = true;
		return Json();
	}
};

void DumpString(std::string& out, const std::string& text) {
	out += '"';
	for (const char c : text) {
		switch (c) {
		case '"': out += "\\\""; break;
		case '\\': out += "\\\\"; break;
		case '\n': out += "\\n"; break;
		case '\r': out += "\\r"; break;
		case '\t': out += "\\t"; break;
		default:
			if (static_cast<unsigned char>(c) < 0x20) {
				char escaped[8];
				std::snprintf(escaped, sizeof escaped, "\\u%04x", static_cast<unsigned>(static_cast<unsigned char>(c)));
				out += escaped;
			} else {
				out += c;
			}
		}
	}
	out += '"';
}

void DumpNumber(std::string& out, double value) {
	if (!std::isfinite(value)) {
		out += "null";
		return;
	}
	char text[40];
	if (std::floor(value) == value && std::fabs(value) < 9.007199254740992e15) {
		std::snprintf(text, sizeof text, "%lld", static_cast<long long>(value));
	} else {
		std::snprintf(text, sizeof text, "%.15g", value);
		if (std::strtod(text, nullptr) != value) std::snprintf(text, sizeof text, "%.17g", value);
		// A locale with a decimal comma must not leak into the wire format.
		for (char* c = text; *c; ++c)
			if (*c == ',') *c = '.';
	}
	out += text;
}

float AxisValue(const Json& value) {
	const double raw = value.number() / 32767.0;
	return static_cast<float>(raw < -1.0 ? -1.0 : (raw > 1.0 ? 1.0 : raw));
}

int ClampInt(int value, int low, int high) { return value < low ? low : (value > high ? high : value); }

float ClampFloat(float value, float low, float high) { return value < low ? low : (value > high ? high : value); }

}  // namespace

// ---- Json ------------------------------------------------------------------

Json Json::MakeArray() {
	Json value;
	value.type_ = Type::Array;
	return value;
}

Json Json::MakeObject() {
	Json value;
	value.type_ = Type::Object;
	return value;
}

int64_t Json::integer(int64_t fallback) const {
	if (type_ != Type::Number) return fallback;
	if (!(number_ >= -9.2e18 && number_ <= 9.2e18)) return fallback;
	return static_cast<int64_t>(std::llround(number_));
}

const Json& Json::operator[](size_t index) const {
	if (type_ != Type::Array || index >= items_.size()) return NullJson();
	return items_[index];
}

const Json& Json::operator[](const std::string& key) const {
	if (type_ != Type::Object) return NullJson();
	for (size_t i = 0; i < keys_.size(); ++i)
		if (keys_[i] == key) return items_[i];
	return NullJson();
}

bool Json::has(const std::string& key) const {
	if (type_ != Type::Object) return false;
	for (const std::string& name : keys_)
		if (name == key) return true;
	return false;
}

Json* Json::find(const std::string& key) {
	if (type_ != Type::Object) return nullptr;
	for (size_t i = 0; i < keys_.size(); ++i)
		if (keys_[i] == key) return &items_[i];
	return nullptr;
}

Json& Json::set(const std::string& key, Json value) {
	if (type_ == Type::Null) type_ = Type::Object;
	if (type_ != Type::Object) return *this;
	if (Json* existing = find(key)) {
		*existing = std::move(value);
		return *this;
	}
	keys_.push_back(key);
	items_.push_back(std::move(value));
	return *this;
}

void Json::erase(const std::string& key) {
	if (type_ != Type::Object) return;
	for (size_t i = 0; i < keys_.size(); ++i) {
		if (keys_[i] == key) {
			keys_.erase(keys_.begin() + static_cast<std::ptrdiff_t>(i));
			items_.erase(items_.begin() + static_cast<std::ptrdiff_t>(i));
			return;
		}
	}
}

Json& Json::push(Json value) {
	if (type_ == Type::Null) type_ = Type::Array;
	if (type_ == Type::Array) items_.push_back(std::move(value));
	return *this;
}

std::string Json::dump() const {
	std::string out;
	dump_to(out);
	return out;
}

void Json::dump_to(std::string& out) const {
	switch (type_) {
	case Type::Null: out += "null"; break;
	case Type::Bool: out += bool_ ? "true" : "false"; break;
	case Type::Number: DumpNumber(out, number_); break;
	case Type::String: DumpString(out, string_); break;
	case Type::Array:
		out += '[';
		for (size_t i = 0; i < items_.size(); ++i) {
			if (i) out += ',';
			items_[i].dump_to(out);
		}
		out += ']';
		break;
	case Type::Object:
		out += '{';
		for (size_t i = 0; i < items_.size(); ++i) {
			if (i) out += ',';
			DumpString(out, keys_[i]);
			out += ':';
			items_[i].dump_to(out);
		}
		out += '}';
		break;
	}
}

Json Json::parse(const std::string& text, bool* ok) {
	JsonParser parser{text.data(), text.data() + text.size()};
	Json value = parser.Value(0);
	parser.SkipSpace();
	const bool good = !parser.failed && parser.at == parser.end;
	if (ok) *ok = good;
	return good ? value : Json();
}

bool Json::operator==(const Json& other) const {
	if (type_ != other.type_) return false;
	switch (type_) {
	case Type::Null: return true;
	case Type::Bool: return bool_ == other.bool_;
	case Type::Number: return number_ == other.number_;
	case Type::String: return string_ == other.string_;
	case Type::Array: return items_ == other.items_;
	case Type::Object:
		if (items_.size() != other.items_.size()) return false;
		for (size_t i = 0; i < keys_.size(); ++i)
			if (!other.has(keys_[i]) || other[keys_[i]] != items_[i]) return false;
		return true;
	}
	return false;
}

// ---- Input helpers ---------------------------------------------------------

Vec2 Stick(const Pad& pad, int side, float deadzone) {
	Vec2 v{pad.axis(side * 2), pad.axis(side * 2 + 1)};
	const float length = std::sqrt(v.x * v.x + v.y * v.y);
	if (length <= deadzone || length <= 0.0f) return Vec2{};
	const float scaled = ClampFloat((length - deadzone) / (1.0f - deadzone), 0.0f, 1.0f);
	return Vec2{v.x / length * scaled, v.y / length * scaled};
}

float Trigger(const Pad& pad, int side, float deadzone) {
	const float t = pad.axis(AXIS_LEFT_TRIGGER + side);
	if (t <= deadzone) return 0.0f;
	return ClampFloat((t - deadzone) / (1.0f - deadzone), 0.0f, 1.0f);
}

const char* PhaseName(Phase phase) {
	switch (phase) {
	case Phase::Idle: return "idle";
	case Phase::Preparing: return "preparing";
	case Phase::Ready: return "ready";
	case Phase::Running: return "running";
	case Phase::Paused: return "paused";
	}
	return "idle";
}

// ---- Faces -----------------------------------------------------------------

bool ParseHexColor(const std::string& text, uint8_t rgb[3]) {
	if (text.size() != 7 || text[0] != '#') return false;
	uint8_t out[3];
	for (int i = 0; i < 3; ++i) {
		int value = 0;
		for (int j = 0; j < 2; ++j) {
			const char c = text[static_cast<size_t>(1 + i * 2 + j)];
			value <<= 4;
			if (c >= '0' && c <= '9') value |= c - '0';
			else if (c >= 'a' && c <= 'f') value |= c - 'a' + 10;
			else if (c >= 'A' && c <= 'F') value |= c - 'A' + 10;
			else return false;
		}
		out[i] = static_cast<uint8_t>(value);
	}
	rgb[0] = out[0];
	rgb[1] = out[1];
	rgb[2] = out[2];
	return true;
}

namespace {

// The historic origins of old 16 and 32 pixel drawings (face.gd).
float FaceOffset(int side, float small) {
	if (side == 32) return small;
	if (side == 16) return small + 8.0f;
	return (static_cast<float>(protocol::AVATAR_SIZE) - static_cast<float>(side)) / 2.0f;
}

}  // namespace

FaceImage DecodeAvatar(const std::string& payload) {
	FaceImage image;
	if (payload.empty() || payload.size() > 800000) return image;
	bool ok = false;
	const Json data = Json::parse(payload, &ok);
	if (!ok) return image;
	const bool legacy = data.is_array();
	const Json* pixels = nullptr;
	int width = 0;
	int height = 0;
	if (legacy) {
		pixels = &data;
		width = height = static_cast<int>(std::sqrt(static_cast<double>(data.size())));
	} else if (data.is_object() && data["v"].integer() == protocol::AVATAR_FORMAT_VERSION) {
		const double w = data["w"].number(-1.0);
		const double h = data["h"].number(-1.0);
		if (std::floor(w) != w || std::floor(h) != h) return image;
		width = static_cast<int>(w);
		height = static_cast<int>(h);
		if (data["px"].is_array()) pixels = &data["px"];
	}
	if (!pixels || width <= 0 || height <= 0 || width > protocol::AVATAR_MAX_SIDE ||
	    height > protocol::AVATAR_MAX_SIDE || pixels->size() != static_cast<size_t>(width) * static_cast<size_t>(height))
		return image;
	image.width = width;
	image.height = height;
	image.rgba.assign(static_cast<size_t>(width) * static_cast<size_t>(height) * 4u, 0);
	for (size_t i = 0; i < pixels->size(); ++i) {
		const std::string pixel = (*pixels)[i].str();
		uint8_t rgb[3];
		if (!ParseHexColor(pixel, rgb)) continue;
		if (legacy) {
			std::string lower = pixel;
			for (char& ch : lower)
				if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch - 'A' + 'a');
			if (lower == protocol::AVATAR_LEGACY_TRANSPARENT) continue;
		}
		uint8_t* out = &image.rgba[i * 4u];
		out[0] = rgb[0];
		out[1] = rgb[1];
		out[2] = rgb[2];
		out[3] = 255;
	}
	image.center_x = static_cast<float>(protocol::AVATAR_HEAD_X) - FaceOffset(width, 14.0f);
	image.center_y = static_cast<float>(protocol::AVATAR_HEAD_Y) - FaceOffset(height, 15.0f);
	return image;
}

// ---- Client ----------------------------------------------------------------

Client::Client(Config config) : config_(std::move(config)) {}

void Client::OnConnected() {
	said_hello_ = true;
	welcomed_ = false;
	inbox_.clear();
	Json hello = Json::MakeObject();
	hello.set("type", protocol::MSG_HELLO).set("role", protocol::ROLE_GAME).set("game", config_.game_id);
	if (!config_.token.empty()) hello.set("token", config_.token);
	outgoing_.clear();
	outgoing_.push_back(hello.dump());
}

void Client::OnDisconnected() {
	frames_.clear();
	perf_running_ = false;
	inbox_.clear();
	outgoing_.clear();
	if (said_hello_) {
		Event event;
		event.kind = Event::Kind::Disconnected;
		Emit(std::move(event));
	}
	said_hello_ = false;
	welcomed_ = false;
}

void Client::Receive(const char* data, size_t size) {
	inbox_.append(data, size);
	size_t start = 0;
	for (;;) {
		const size_t newline = inbox_.find('\n', start);
		if (newline == std::string::npos) break;
		std::string line = inbox_.substr(start, newline - start);
		start = newline + 1;
		if (!line.empty() && line.back() == '\r') line.pop_back();
		if (line.find_first_not_of(" \t") == std::string::npos) continue;  // keepalive
		Handle(line);
	}
	inbox_.erase(0, start);
	// Faces make big messages, but nothing legitimate is this big.
	if (inbox_.size() > 16u * 1024u * 1024u) inbox_.clear();
}

void Client::Handle(const std::string& message) {
	bool ok = false;
	Json parsed = Json::parse(message, &ok);
	if (ok) Handle(parsed);
}

std::vector<std::string> Client::TakeOutgoing() {
	std::vector<std::string> out;
	out.swap(outgoing_);
	return out;
}

bool Client::PollEvent(Event& out) {
	if (events_.empty()) return false;
	out = std::move(events_.front());
	events_.pop_front();
	return true;
}

void Client::Send(Json message) {
	if (!said_hello_) return;
	outgoing_.push_back(message.dump());
}

void Client::EmitSession(Event::Kind kind) {
	Event event;
	event.kind = kind;
	event.session = session_;
	Emit(std::move(event));
}

void Client::Tick(double now_seconds) {
	now_ = now_seconds;
	UpdateButtons();
	SamplePerformance(now_seconds);
}

// ---- state -----------------------------------------------------------------

const Json& Client::player(const std::string& id) const {
	for (const Json& entry : players().items())
		if (entry["id"].str() == id) return entry;
	return NullJson();
}

const Json& Client::player_for_seat(int seat_index) const {
	for (const Json& seat : seats().items()) {
		if (seat["index"].integer(-1) != seat_index) continue;
		const Json& occupant = seat["occupant"];
		const std::string kind = occupant["kind"].str();
		if (kind != protocol::SEAT_OCCUPANT_LOCAL && kind != protocol::SEAT_OCCUPANT_REMOTE) return NullJson();
		return player(occupant["player_id"].str());
	}
	return NullJson();
}

int Client::LocalSeatCount() const {
	int count = 0;
	for (const Json& seat : seats().items())
		if (seat["occupant"]["kind"].str() == protocol::SEAT_OCCUPANT_LOCAL) ++count;
	return count;
}

int Client::AiSeatCount() const {
	int count = 0;
	for (const Json& seat : seats().items())
		if (seat["occupant"]["kind"].str() == protocol::SEAT_OCCUPANT_AI) ++count;
	return count;
}

std::vector<Json> Client::CouchOrder() const {
	struct Keyed {
		int64_t place;
		int64_t index;
		const Json* seat;
	};
	std::vector<Keyed> keyed;
	for (const Json& seat : seats().items()) {
		if (!seat.is_object()) continue;
		const Json& who = player(seat["occupant"]["player_id"].str());
		const int64_t place = who["couch"].is_number() && !seat["occupant"]["player_id"].str().empty() ? who["couch"].integer() : 1000;
		keyed.push_back(Keyed{place, seat["index"].integer(), &seat});
	}
	// Stable insertion sort: rosters hold a handful of seats.
	for (size_t i = 1; i < keyed.size(); ++i) {
		Keyed moving = keyed[i];
		size_t j = i;
		while (j > 0 && (keyed[j - 1].place > moving.place ||
		                 (keyed[j - 1].place == moving.place && keyed[j - 1].index > moving.index))) {
			keyed[j] = keyed[j - 1];
			--j;
		}
		keyed[j] = moving;
	}
	std::vector<Json> out;
	for (const Keyed& entry : keyed) out.push_back(*entry.seat);
	return out;
}

// ---- lifecycle -------------------------------------------------------------

void Client::Ready() {
	if (session_.empty() || phase_ != Phase::Preparing) return;
	phase_ = Phase::Ready;
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_READY).set("session", session_);
	Send(std::move(msg));
}

void Client::Finished() {
	if (session_.empty()) return;
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_FINISHED).set("session", session_);
	Send(std::move(msg));
}

void Client::RoomLog(const std::string& text) {
	if (session_.empty() || phase_ != Phase::Running || text.empty()) return;
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_ROOM_LOG).set("session", session_).set("text", text);
	Send(std::move(msg));
}

void Client::Participation(bool instant_join) {
	if (session_.empty()) return;
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_PARTICIPATION).set("session", session_).set("instant_join", instant_join);
	Send(std::move(msg));
}

void Client::Progress(int percent, const std::string& label) {
	if (session_.empty()) return;
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_PROGRESS).set("session", session_).set("percent", ClampInt(percent, 0, 100));
	if (!label.empty()) msg.set("label", label);
	Send(std::move(msg));
}

void Client::RequestOverlay() {
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_REQUEST_OVERLAY);
	Send(std::move(msg));
}

void Client::RequestStart() {
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_REQUEST_START);
	Send(std::move(msg));
}

// ---- input -----------------------------------------------------------------

std::string Client::ControllerForSeat(int seat_index) const {
	for (const Json& seat : seats().items())
		if (seat["index"].integer(-1) == seat_index) return seat["controller"].str();
	return std::string();
}

Pad Client::PadForSeat(int seat_index, bool any_phase) const {
	if ((phase_ != Phase::Running && !any_phase) || now_ - frame_at_ >= FRAME_STALE_SECONDS) return Pad{};
	const std::string token = ControllerForSeat(seat_index);
	if (token.empty()) return Pad{};
	const auto found = frames_.find(token);
	return found == frames_.end() ? Pad{} : found->second;
}

bool Client::JustPressed(int seat_index, int button) const {
	if (button < 0 || button >= BUTTON_COUNT) return false;
	const uint32_t bit = 1u << button;
	const auto now = buttons_now_.find(seat_index);
	const auto before = buttons_before_.find(seat_index);
	const auto blocked = buttons_blocked_.find(seat_index);
	const uint32_t held = now == buttons_now_.end() ? 0u : now->second;
	const uint32_t was = before == buttons_before_.end() ? 0u : before->second;
	const uint32_t stuck = blocked == buttons_blocked_.end() ? 0u : blocked->second;
	return (held & bit) != 0 && (was & bit) == 0 && (stuck & bit) == 0;
}

void Client::UpdateButtons() {
	buttons_before_ = buttons_now_;
	buttons_now_.clear();
	for (const Json& seat : seats().items()) {
		const int index = static_cast<int>(seat["index"].integer(-1));
		const Pad pad = PadForSeat(index, true);
		buttons_now_[index] = pad.buttons;
		// A button held through Start or Resume counts once it is let go.
		// Only fresh input can say it was let go.
		if (pad.present) buttons_blocked_[index] &= pad.buttons;
	}
}

void Client::HoldButtons() {
	// Whatever is down when play starts was pressed for the lobby.
	for (const Json& seat : seats().items())
		buttons_blocked_[static_cast<int>(seat["index"].integer(-1))] = (1u << BUTTON_COUNT) - 1u;
}

void Client::ReportActivity(int seat_index) {
	if (session_.empty()) return;
	const std::string token = ControllerForSeat(seat_index);
	if (token.empty()) return;
	const auto last = activity_at_.find(token);
	if (last != activity_at_.end() && now_ - last->second < 1.0) return;
	activity_at_[token] = now_;
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_CONTROLLER_INPUT).set("session", session_).set("controller", token);
	Send(std::move(msg));
}

void Client::Rumble(int seat_index, float weak, float strong, float seconds) {
	if (session_.empty() || phase_ != Phase::Running) return;
	weak = ClampFloat(weak, 0.0f, 1.0f);
	strong = ClampFloat(strong, 0.0f, 1.0f);
	const bool quiet = weak == 0.0f && strong == 0.0f;
	// One stop is enough; repeated zeros would only flood the socket.
	const auto last = rumble_quiet_.find(seat_index);
	if (quiet && (last == rumble_quiet_.end() || last->second)) return;
	rumble_quiet_[seat_index] = quiet;
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_RUMBLE)
	    .set("session", session_)
	    .set("seat", seat_index)
	    .set("weak", static_cast<int>(weak * 65535.0f))
	    .set("strong", static_cast<int>(strong * 65535.0f))
	    .set("ms", ClampInt(static_cast<int>(seconds * 1000.0f), 0, 5000));
	Send(std::move(msg));
}

// ---- settings, actions, saves ------------------------------------------------

void Client::DeclareSettings(const Json& settings) {
	declared_settings_ = settings;
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_DECLARE_SETTINGS).set("settings", settings);
	Send(std::move(msg));
}

void Client::DeclareActions(const Json& actions) {
	declared_actions_ = actions.is_array() ? actions : Json::MakeArray();
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_DECLARE_ACTIONS).set("actions", declared_actions_);
	Send(std::move(msg));
}

void Client::SetSetting(const std::string& key, const Json& value) {
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_SET_SETTING).set("key", key).set("value", value);
	Send(std::move(msg));
}

const Json& Client::setting(const std::string& key) const {
	const auto found = settings_.find(key);
	return found == settings_.end() ? NullJson() : found->second;
}

void Client::SetPlayerSetting(const std::string& player_id, const std::string& key, const Json& value) {
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_SET_PLAYER_SETTING).set("player_id", player_id).set("key", key).set("value", value);
	Send(std::move(msg));
}

const Json& Client::player_setting(const std::string& player_id, const std::string& key) const {
	const auto found = player_settings_.find(player_id);
	return found == player_settings_.end() ? NullJson() : found->second[key];
}

const Json& Client::player_data(const std::string& player_id) const {
	const auto found = player_data_.find(player_id);
	return found == player_data_.end() ? NullJson() : found->second;
}

void Client::SavePlayerData(const std::string& player_id, const Json& data) {
	player_data_[player_id] = data;
	const auto revision = player_data_revision_.find(player_id);
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_SAVE_PLAYER_DATA)
	    .set("player_id", player_id)
	    .set("data", data)
	    .set("expected_revision", revision == player_data_revision_.end() ? int64_t(0) : revision->second);
	Send(std::move(msg));
}

Json Client::PartyUnion(const std::string& key) const {
	Json out = Json::MakeArray();
	for (const Json& entry : party_["players"].items()) {
		for (const Json& item : player_data(entry["id"].str())[key].items()) {
			bool known = false;
			for (const Json& existing : out.items()) known = known || existing == item;
			if (!known) out.push(item);
		}
	}
	return out;
}

void Client::UnlockForPresent(const Json& item, const std::string& key) {
	for (const Json& entry : party_["players"].items()) {
		const std::string id = entry["id"].str();
		if (id.empty()) continue;
		Json data = player_data(id);
		if (!data.is_object()) data = Json::MakeObject();
		Json list = data[key].is_array() ? data[key] : Json::MakeArray();
		bool known = false;
		for (const Json& existing : list.items()) known = known || existing == item;
		if (known) continue;
		list.push(item);
		data.set(key, list);
		SavePlayerData(id, data);
	}
}

// ---- phone screens -------------------------------------------------------------

void Client::DeclareCompanion(const std::string& root, const std::string& entry, const Json& app) {
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_DECLARE_COMPANION);
	if (!root.empty()) msg.set("root", root);
	if (!entry.empty()) msg.set("entry", entry);
	if (app.is_object()) msg.set("app", app);
	declared_companion_ = msg;
	Send(std::move(msg));
}

void Client::SendCompanionMessage(const Json& data, const std::string& player_id) {
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_COMPANION_MESSAGE).set("data", data);
	if (!player_id.empty()) msg.set("player_id", player_id);
	Send(std::move(msg));
}

// ---- performance ---------------------------------------------------------------

void Client::ResetPerformance() {
	perf_running_ = false;
	perf_last_ = -1.0;
	perf_frames_ = perf_elapsed_us_ = perf_slow_frames_ = perf_max_frame_us_ = perf_sent_us_ = 0;
}

void Client::SamplePerformance(double now) {
	if (!perf_running_ || session_.empty()) {
		perf_last_ = -1.0;
		return;
	}
	const double previous = perf_last_;
	perf_last_ = now;
	if (previous < 0.0) return;
	const double elapsed = (now - previous) * 1e6;
	// Skip OS suspension; report real frame intervals, not scaled game time.
	if (elapsed <= 0.0 || elapsed > 2e6) return;
	const uint64_t us = static_cast<uint64_t>(elapsed);
	perf_frames_ += 1;
	perf_elapsed_us_ += us;
	perf_slow_frames_ += us > 33333 ? 1 : 0;
	if (us > perf_max_frame_us_) perf_max_frame_us_ = us;
	if (perf_elapsed_us_ - perf_sent_us_ < 10000000) return;
	perf_sent_us_ = perf_elapsed_us_;
	Json sample = Json::MakeObject();
	sample.set("frames", perf_frames_)
	    .set("elapsed_us", perf_elapsed_us_)
	    .set("slow_frames", perf_slow_frames_)
	    .set("max_frame_us", perf_max_frame_us_)
	    .set("cpu", device_.cpu.substr(0, 128))
	    .set("gpu", device_.gpu.substr(0, 128))
	    .set("os", device_.os.substr(0, 64))
	    .set("memory_mib", device_.memory_mib)
	    .set("width", width_ > 0 ? width_ : 0)
	    .set("height", height_ > 0 ? height_ : 0);
	Json msg = Json::MakeObject();
	msg.set("type", protocol::MSG_PERFORMANCE).set("session", session_).set("sample", sample);
	Send(std::move(msg));
}

// ---- incoming ------------------------------------------------------------------

void Client::Handle(const Json& msg) {
	if (!msg.is_object()) return;
	const std::string kind = msg["type"].str();
	const std::string msg_session = msg["session"].str();
	const bool session_message = kind == protocol::MSG_START || kind == protocol::MSG_PAUSE ||
	                             kind == protocol::MSG_RESUME || kind == protocol::MSG_DISPOSE ||
	                             kind == protocol::MSG_PARTY_UPDATED || kind == protocol::MSG_PLAYERS_UPDATED;
	if (session_message && (session_.empty() || msg_session != session_)) return;

	if (kind == protocol::MSG_WELCOME) {
		welcomed_ = true;
		const int64_t version = msg["protocol_version"].integer(protocol::PROTOCOL_VERSION);
		if (version != protocol::PROTOCOL_VERSION) {
			Event warning;
			warning.text = "GameNight speaks protocol " + std::to_string(version) + ", this plugin " +
			               std::to_string(protocol::PROTOCOL_VERSION) + "; update the GameNight plugin";
			Emit(std::move(warning));
		}
		party_ = msg["party"].is_object() ? msg["party"] : Json::MakeObject();
		Event connected;
		connected.kind = Event::Kind::Connected;
		Emit(std::move(connected));
		Event party;
		party.kind = Event::Kind::PartyUpdated;
		Emit(std::move(party));
		// A reconnect: declare again so the host replays the party's values.
		if (!declared_settings_.is_null()) {
			Json again = Json::MakeObject();
			again.set("type", protocol::MSG_DECLARE_SETTINGS).set("settings", declared_settings_);
			Send(std::move(again));
		}
		if (!declared_actions_.is_null()) {
			Json again = Json::MakeObject();
			again.set("type", protocol::MSG_DECLARE_ACTIONS).set("actions", declared_actions_);
			Send(std::move(again));
		}
		if (!declared_companion_.is_null()) Send(declared_companion_);
	} else if (kind == protocol::MSG_PARTY_STATE) {
		party_ = msg["party"].is_object() ? msg["party"] : Json::MakeObject();
		Event party;
		party.kind = Event::Kind::PartyUpdated;
		Emit(std::move(party));
	} else if (kind == protocol::MSG_CONTROLLER_FRAME) {
		frames_.clear();
		frame_at_ = now_;
		for (const Json& entry : msg["controllers"].items()) {
			const std::string token = entry["controller"].str();
			if (token.empty() || frames_.count(token)) continue;
			Pad pad;
			pad.present = true;
			pad.controller = token;
			pad.buttons = static_cast<uint32_t>(entry["buttons"].integer()) & ((1u << BUTTON_COUNT) - 1u);
			for (int i = 0; i < AXIS_COUNT; ++i) pad.axes[i] = AxisValue(entry["axes"][static_cast<size_t>(i)]);
			frames_[token] = pad;
		}
	} else if (kind == protocol::MSG_PARTY_UPDATED) {
		party_.set("seats", msg["seats"].is_array() ? msg["seats"] : Json::MakeArray());
		party_.set("players", msg["players"].is_array() ? msg["players"] : Json::MakeArray());
		party_.set("presence", msg["presence"].is_array() ? msg["presence"] : Json::MakeArray());
		EmitSession(Event::Kind::RosterChanged);
		Event party;
		party.kind = Event::Kind::PartyUpdated;
		Emit(std::move(party));
	} else if (kind == protocol::MSG_PLAYERS_UPDATED) {
		Json roster = party_["players"].is_array() ? party_["players"] : Json::MakeArray();
		for (const Json& updated : msg["players"].items()) {
			bool known = false;
			for (Json& existing : roster.items()) {
				if (existing["id"].str() == updated["id"].str()) {
					existing = updated;
					known = true;
				}
			}
			if (!known) roster.push(updated);
		}
		party_.set("players", roster);
		Event event;
		event.kind = Event::Kind::PlayersUpdated;
		event.session = session_;
		event.value = msg["players"].is_array() ? msg["players"] : Json::MakeArray();
		Emit(std::move(event));
		Event party;
		party.kind = Event::Kind::PartyUpdated;
		Emit(std::move(party));
	} else if (kind == protocol::MSG_PREPARE) {
		const std::string game = msg["game"].str(config_.game_id);
		if (game != config_.game_id || msg_session.empty() || msg_session == session_) return;
		if (!session_.empty()) EmitSession(Event::Kind::Disposed);
		session_ = msg_session;
		phase_ = Phase::Preparing;
		frames_.clear();
		party_.set("seats", msg["seats"].is_array() ? msg["seats"] : Json::MakeArray());
		party_.set("players", msg["players"].is_array() ? msg["players"] : Json::MakeArray());
		ResetPerformance();
		EmitSession(Event::Kind::Prepared);
	} else if (kind == protocol::MSG_START) {
		if (phase_ != Phase::Ready) return;
		phase_ = Phase::Running;
		perf_running_ = true;
		perf_last_ = -1.0;
		HoldButtons();
		EmitSession(Event::Kind::Started);
	} else if (kind == protocol::MSG_PAUSE) {
		if (phase_ != Phase::Running) return;
		phase_ = Phase::Paused;
		perf_running_ = false;
		perf_last_ = -1.0;
		EmitSession(Event::Kind::Paused);
	} else if (kind == protocol::MSG_RESUME) {
		if (phase_ != Phase::Paused) return;
		phase_ = Phase::Running;
		perf_running_ = true;
		perf_last_ = -1.0;
		HoldButtons();
		EmitSession(Event::Kind::Resumed);
	} else if (kind == protocol::MSG_DISPOSE) {
		perf_running_ = false;
		EmitSession(Event::Kind::Disposed);
		session_.clear();
		phase_ = Phase::Idle;
		frames_.clear();
	} else if (kind == protocol::MSG_SETTING_CHANGED) {
		Event event;
		event.kind = Event::Kind::SettingChanged;
		event.key = msg["key"].str();
		event.value = msg["value"];
		settings_[event.key] = event.value;
		Emit(std::move(event));
	} else if (kind == protocol::MSG_PLAYER_SETTINGS) {
		Event event;
		event.kind = Event::Kind::PlayerSettingsChanged;
		event.player_id = msg["player_id"].str();
		event.value = msg["values"].is_object() ? msg["values"] : Json::MakeObject();
		player_settings_[event.player_id] = event.value;
		Emit(std::move(event));
	} else if (kind == protocol::MSG_PLAYER_DATA) {
		Event event;
		event.kind = Event::Kind::PlayerDataChanged;
		event.player_id = msg["player_id"].str();
		event.value = msg["data"];
		player_data_[event.player_id] = event.value;
		player_data_revision_[event.player_id] = msg["revision"].integer();
		Emit(std::move(event));
	} else if (kind == protocol::MSG_ACTION_TRIGGERED) {
		Event event;
		event.kind = Event::Kind::ActionTriggered;
		event.key = msg["key"].str();
		event.player_id = msg["player_id"].str();
		Emit(std::move(event));
	} else if (kind == protocol::MSG_COMPANION_MESSAGE) {
		Event event;
		event.kind = Event::Kind::CompanionMessage;
		event.player_id = msg["player_id"].str();
		event.value = msg["data"];
		Emit(std::move(event));
	} else if (kind == protocol::MSG_COMPANION_PRESENCE) {
		Event event;
		event.kind = Event::Kind::CompanionPresence;
		event.player_id = msg["player_id"].str();
		event.connected = msg["connected"].boolean();
		Emit(std::move(event));
	} else if (kind == protocol::MSG_ERROR) {
		Event event;
		event.text = "GameNight: " + msg["message"].str("unknown error");
		Emit(std::move(event));
	}
}

}  // namespace gamenight

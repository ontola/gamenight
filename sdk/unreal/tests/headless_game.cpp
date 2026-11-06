// The Unreal plugin's protocol core on a real socket, without Unreal: the
// same connect, read, dispatch and flush loop as UGameNightSubsystem, with a
// five-second round instead of a level. CI runs the GameNight conformance
// harness against it:
//
//   python3 scripts/test-unreal-sdk.py --headless /tmp/unreal-core
//   cargo run -p gamenight-certify -- unreal-core -- /tmp/unreal-core
//
// POSIX only; the plugin itself uses Unreal's sockets.
#include "GameNightCore.h"
#include "GameNightProtocol.h"

#include <arpa/inet.h>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0  // macOS: SIGPIPE stays on, fine for a test
#endif

namespace {

double Now() {
	using namespace std::chrono;
	return duration<double>(steady_clock::now().time_since_epoch()).count();
}

std::string Env(const char* name) {
	const char* value = std::getenv(name);
	return value ? value : "";
}

int Open(const std::string& address) {
	const size_t colon = address.rfind(':');
	if (colon == std::string::npos) return -1;
	sockaddr_in to{};
	to.sin_family = AF_INET;
	to.sin_port = htons(static_cast<uint16_t>(std::atoi(address.c_str() + colon + 1)));
	if (inet_pton(AF_INET, address.substr(0, colon).c_str(), &to.sin_addr) != 1) return -1;
	const int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) return -1;
	if (connect(fd, reinterpret_cast<sockaddr*>(&to), sizeof to) != 0) {
		close(fd);
		return -1;
	}
	int one = 1;
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
	return fd;
}

}  // namespace

int main() {
	gamenight::Config config;
	config.game_id = Env(gamenight::protocol::ENV_GAME_ID);
	config.token = Env(gamenight::protocol::ENV_TOKEN);
	config.launched = Env(gamenight::protocol::ENV_GAMENIGHT) == "1";
	const std::string address = Env(gamenight::protocol::ENV_ADDR);
	if (!config.launched || address.empty() || config.game_id.empty()) {
		std::printf("[unreal-core] not launched by GameNight; standalone\n");
		return 0;
	}
	const int fd = Open(address);
	if (fd < 0) {
		std::fprintf(stderr, "[unreal-core] cannot reach the host at %s\n", address.c_str());
		return 1;
	}
	gamenight::Client client(config);
	client.OnConnected();
	client.DeclareSettings(gamenight::Json::parse(
		R"([{"key":"round_seconds","label":"Round length","kind":"number","default":5,"min":1,"max":60}])"));

	std::string pending;
	double round_ends = 0.0;
	double round_seconds = 5.0;
	bool open = true;
	while (open) {
		client.Tick(Now());
		char buffer[65536];
		for (;;) {
			const ssize_t got = recv(fd, buffer, sizeof buffer, 0);
			if (got > 0) {
				client.Receive(buffer, static_cast<size_t>(got));
				continue;
			}
			if (got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) break;
			client.OnDisconnected();  // closed by the host
			open = false;
			break;
		}
		gamenight::Event event;
		while (client.PollEvent(event)) {
			using Kind = gamenight::Event::Kind;
			switch (event.kind) {
			case Kind::Connected: std::printf("[unreal-core] in the party\n"); break;
			case Kind::Prepared:
				std::printf("[unreal-core] warming %s for %d people and %d bots\n", event.session.c_str(),
				            client.LocalSeatCount(), client.AiSeatCount());
				client.Participation(false);
				client.Progress(50, "building the arena");
				client.Ready();
				break;
			case Kind::Started:
				std::printf("[unreal-core] GO\n");
				round_ends = Now() + round_seconds;
				break;
			case Kind::Paused:
				std::printf("[unreal-core] paused\n");
				round_ends += 1e9;
				break;
			case Kind::Resumed:
				std::printf("[unreal-core] resumed\n");
				round_ends -= 1e9;
				break;
			case Kind::Disposed: std::printf("[unreal-core] disposed\n"); break;
			case Kind::SettingChanged:
				if (event.key == "round_seconds") round_seconds = event.value.number(round_seconds);
				break;
			case Kind::Disconnected: std::printf("[unreal-core] host gone: quitting\n"); break;
			case Kind::Warning: std::fprintf(stderr, "[unreal-core] %s\n", event.text.c_str()); break;
			default: break;
			}
		}
		if (client.phase() == gamenight::Phase::Running && Now() >= round_ends) {
			// Rounds repeat until the party picks another game.
			std::printf("[unreal-core] round over\n");
			client.Finished();
			client.RoomLog("Round over");
			round_ends = Now() + round_seconds;
		}
		for (const std::string& message : client.TakeOutgoing()) pending += message + "\n";
		while (open && !pending.empty()) {
			const ssize_t sent = send(fd, pending.data(), pending.size(), MSG_NOSIGNAL);
			if (sent > 0) {
				pending.erase(0, static_cast<size_t>(sent));
				continue;
			}
			if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) break;
			open = false;
		}
		std::fflush(stdout);
		std::this_thread::sleep_for(std::chrono::milliseconds(8));
	}
	close(fd);
	std::printf("[unreal-core] good night\n");
	return 0;
}

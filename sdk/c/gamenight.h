/*
 * gamenight.h — GameNight client for C and C++ engines. Single header, no
 * dependencies, C99. Public domain (CC0), same as the rest of the SDKs:
 * vendor it, don't submodule it.
 *
 * Why this exists: the protocol is JSON over a socket, which is free in
 * Rust, Godot and JavaScript and distinctly not free in a C++ engine that
 * has neither a JSON parser nor a WebSocket client (SuperTuxKart, Raydium,
 * most of the couch classics worth adapting). This header is the whole
 * dependency: a socket, a line reader, and just enough JSON.
 *
 * It speaks the *plain* transport — one JSON object per line, no handshake,
 * no frame codec. The daemon sniffs which transport a connection is using,
 * so this is the same protocol a WebSocket client speaks, minus the
 * ceremony. See docs/protocol.md#transport.
 *
 *   #define GAMENIGHT_IMPLEMENTATION
 *   #include "gamenight.h"
 *
 *   gn_client gn;
 *   if (gn_connect_from_env(&gn, "my-game") == GN_OK) {
 *       gn_event ev;
 *       while (gn_poll(&gn, &ev) >= 0) {          // -1 once the daemon goes
 *           switch (ev.type) {                    // away: the night is over
 *           case GN_PREPARE:
 *               load_everything(ev.seats, ev.seat_count);
 *               gn_ready(&gn, ev.session);
 *               break;
 *           case GN_START:   go();      break;
 *           case GN_PAUSE:   freeze();  break;
 *           case GN_RESUME:  unfreeze();break;
 *           case GN_DISPOSE: teardown(); break;   // ...then wait for the
 *           default: break;                       //    next GN_PREPARE
 *           }
 *       }
 *   }
 *
 * gn_poll() never blocks, so it drops straight into an existing game loop.
 * Nothing here allocates: one client is ~24 KB of fixed buffers, sized for
 * the largest message the protocol defines (a party_state snapshot).
 */

#ifndef GAMENIGHT_H
#define GAMENIGHT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- sizes ------------------------------------------------------------ */

#define GN_MAX_SEATS 8
#define GN_MAX_PLAYERS 8
#define GN_ID_LEN 48   /* uuids are 36 + NUL */
#define GN_NAME_LEN 64
#define GN_BUF_LEN 16384
#define GN_MAX_TOKENS 768

/* ---- results ---------------------------------------------------------- */

typedef enum {
    GN_OK = 0,
    GN_ERR_NOT_LAUNCHED = -1, /* no GAMENIGHT=1: run standalone */
    GN_ERR_SOCKET = -2,
    GN_ERR_CONNECT = -3,
    GN_ERR_HANDSHAKE = -4
} gn_result;

/* ---- events ----------------------------------------------------------- */

typedef enum {
    GN_NOTHING = 0, /* gn_poll found no complete message this tick */
    GN_WELCOME,
    GN_PREPARE,
    GN_START,
    GN_PAUSE,
    GN_RESUME,
    GN_DISPOSE,
    GN_SETTING_CHANGED,
    GN_ERROR,
    GN_UNKNOWN /* a message type from a newer daemon: ignore it */
} gn_event_type;

typedef enum { GN_EMPTY = 0, GN_LOCAL, GN_REMOTE, GN_AI } gn_occupant;

typedef struct {
    int index;                    /* stable all night: seat 1 is seat 1 */
    gn_occupant occupant;
    char player_id[GN_ID_LEN];    /* "" unless occupant == GN_LOCAL/GN_REMOTE */
    char name[GN_NAME_LEN];       /* the person's display name, "" if unknown */
} gn_seat;

typedef struct {
    char id[GN_ID_LEN];
    char name[GN_NAME_LEN];
} gn_player;

typedef struct {
    gn_event_type type;
    char session[GN_ID_LEN];      /* set on prepare/start/pause/resume/dispose */

    /* GN_PREPARE only. Seats are always reported in index order. */
    gn_seat seats[GN_MAX_SEATS];
    int seat_count;
    gn_player players[GN_MAX_PLAYERS];
    int player_count;

    /* GN_SETTING_CHANGED: `value` is the raw JSON scalar ("true", "5",
     * "\"volcano\"") — compare or parse it as your setting's kind needs. */
    char key[GN_NAME_LEN];
    char value[GN_NAME_LEN];

    /* GN_ERROR / GN_WELCOME */
    char message[256];
    int protocol_version;
} gn_event;

/* ---- client ----------------------------------------------------------- */

typedef struct {
    int fd;
    int connected;
    char game_id[GN_NAME_LEN];
    char buf[GN_BUF_LEN]; /* inbound line assembly */
    size_t len;
} gn_client;

/* Connect using the GAMENIGHT_* environment the daemon sets when it launches
 * you. Returns GN_ERR_NOT_LAUNCHED when GAMENIGHT != "1" — that is not a
 * failure, it means "boot normally, you are a standalone game tonight".
 *
 * `fallback_game_id` is used when GAMENIGHT_GAME_ID is unset, which is the
 * dev-mode case: start your game by hand and connect to a daemon anyway. */
gn_result gn_connect_from_env(gn_client *c, const char *fallback_game_id);

/* Connect explicitly. `addr` is "host:port"; `token` may be NULL. */
gn_result gn_connect(gn_client *c, const char *addr, const char *game_id,
                     const char *token);

/* Non-blocking. Returns 1 and fills `ev` when a message arrived, 0 when
 * nothing is pending, -1 when the daemon is gone (exit: the night is over). */
int gn_poll(gn_client *c, gn_event *ev);

/* "This session can start instantly." Send it only when that is true. */
void gn_ready(gn_client *c, const char *session);

/* Optional: how far along warming is, so the party sees something truthful
 * while it waits. Send as often as is useful. */
void gn_progress(gn_client *c, const char *session, int percent,
                 const char *label);

/* Optional: the match ended. Opens the party vote; keep rendering. */
void gn_finished(gn_client *c, const char *session);

/* "Get me back to the party" — for a Back/Select button inside your game. */
void gn_request_overlay(gn_client *c);

/* Optional: declare match settings. `settings_json` is the array body, e.g.
 * "[{\"key\":\"items\",\"label\":\"Items\",\"kind\":\"toggle\",
 *    \"default\":true}]" — see docs/protocol.md#match-settings. */
void gn_declare_settings(gn_client *c, const char *settings_json);

void gn_close(gn_client *c);

#ifdef __cplusplus
}
#endif

/* ======================================================================= */
/* Implementation                                                          */
/* ======================================================================= */

#ifdef GAMENIGHT_IMPLEMENTATION

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
#define GN_CLOSE closesocket
#define GN_WOULDBLOCK (WSAGetLastError() == WSAEWOULDBLOCK)
#else
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#define GN_CLOSE close
#define GN_WOULDBLOCK (errno == EAGAIN || errno == EWOULDBLOCK)
#endif

/* ---- a very small JSON reader ----------------------------------------
 *
 * Tokenizes into a flat array with parent links (the jsmn shape). We only
 * ever read messages the daemon sent, so this is deliberately permissive
 * about things a validator would reject and strict about nothing.
 */

enum { GN_T_OBJ = 1, GN_T_ARR, GN_T_STR, GN_T_PRIM };

typedef struct {
    int type;
    int start, end; /* byte range in the source; strings exclude the quotes */
    int size;       /* child count */
    int parent;
} gn_tok;

typedef struct {
    const char *js;
    gn_tok toks[GN_MAX_TOKENS];
    int count;
} gn_doc;

static int gn__push(gn_doc *d, int type, int start, int end, int parent) {
    if (d->count >= GN_MAX_TOKENS) return -1;
    d->toks[d->count].type = type;
    d->toks[d->count].start = start;
    d->toks[d->count].end = end;
    d->toks[d->count].size = 0;
    d->toks[d->count].parent = parent;
    if (parent >= 0) d->toks[parent].size++;
    return d->count++;
}

/* Returns the number of tokens, or -1 on malformed input / token overflow. */
static int gn__parse(gn_doc *d, const char *js) {
    int i = 0, parent = -1;
    d->js = js;
    d->count = 0;
    for (; js[i]; i++) {
        char ch = js[i];
        switch (ch) {
        case '{':
        case '[': {
            int t = gn__push(d, ch == '{' ? GN_T_OBJ : GN_T_ARR, i, -1, parent);
            if (t < 0) return -1;
            parent = t;
            break;
        }
        case '}':
        case ']': {
            /* Close the nearest open container. */
            int t = parent;
            while (t >= 0 && d->toks[t].end != -1) t = d->toks[t].parent;
            if (t < 0) return -1;
            d->toks[t].end = i + 1;
            parent = d->toks[t].parent;
            /* Values sit inside their key token; unwind those too. */
            while (parent >= 0 && d->toks[parent].type == GN_T_STR &&
                   d->toks[parent].size >= 1)
                parent = d->toks[parent].parent;
            break;
        }
        case '"': {
            int start = i + 1;
            for (i++; js[i] && js[i] != '"'; i++)
                if (js[i] == '\\' && js[i + 1]) i++;
            if (!js[i]) return -1;
            if (gn__push(d, GN_T_STR, start, i, parent) < 0) return -1;
            break;
        }
        case ':':
            /* The string just read was a key: values nest under it. */
            parent = d->count - 1;
            break;
        case ',':
            /* Leave the key we were filling; back out to the container. */
            while (parent >= 0 && d->toks[parent].type != GN_T_OBJ &&
                   d->toks[parent].type != GN_T_ARR)
                parent = d->toks[parent].parent;
            break;
        case ' ':
        case '\t':
        case '\r':
        case '\n':
            break;
        default: {
            int start = i;
            while (js[i] && !strchr(" \t\r\n,]}", js[i])) i++;
            if (gn__push(d, GN_T_PRIM, start, i, parent) < 0) return -1;
            i--;
            break;
        }
        }
    }
    return d->count;
}

/* Index of the value token for `key` directly inside object token `obj`. */
static int gn__get(const gn_doc *d, int obj, const char *key) {
    size_t klen = strlen(key);
    int i;
    if (obj < 0) return -1;
    for (i = obj + 1; i < d->count; i++) {
        const gn_tok *t = &d->toks[i];
        if (t->parent != obj || t->type != GN_T_STR || t->size != 1) continue;
        if ((size_t)(t->end - t->start) == klen &&
            strncmp(d->js + t->start, key, klen) == 0) {
            int v;
            for (v = i + 1; v < d->count; v++)
                if (d->toks[v].parent == i) return v;
            return -1;
        }
    }
    return -1;
}

/* Index of the `n`th element of array token `arr`. */
static int gn__at(const gn_doc *d, int arr, int n) {
    int i, seen = 0;
    if (arr < 0 || d->toks[arr].type != GN_T_ARR) return -1;
    for (i = arr + 1; i < d->count; i++)
        if (d->toks[i].parent == arr && seen++ == n) return i;
    return -1;
}

static int gn__len(const gn_doc *d, int arr) {
    return arr < 0 ? 0 : d->toks[arr].size;
}

/* Copy token text into `dst`, unescaping the handful of escapes that can
 * appear in a player name. Always NUL-terminates. */
static void gn__str(const gn_doc *d, int tok, char *dst, size_t cap) {
    int i;
    size_t o = 0;
    dst[0] = '\0';
    if (tok < 0 || cap == 0) return;
    for (i = d->toks[tok].start; i < d->toks[tok].end && o + 1 < cap; i++) {
        char ch = d->js[i];
        if (ch == '\\' && i + 1 < d->toks[tok].end) {
            char esc = d->js[++i];
            switch (esc) {
            case 'n': ch = '\n'; break;
            case 't': ch = '\t'; break;
            case 'r': ch = '\r'; break;
            case 'u': /* keep it simple: emit '?' and skip the code point */
                i += 4;
                ch = '?';
                break;
            default: ch = esc; break;
            }
        }
        dst[o++] = ch;
    }
    dst[o] = '\0';
}

static int gn__streq(const gn_doc *d, int tok, const char *s) {
    size_t n = strlen(s);
    return tok >= 0 && (size_t)(d->toks[tok].end - d->toks[tok].start) == n &&
           strncmp(d->js + d->toks[tok].start, s, n) == 0;
}

/* ---- socket plumbing --------------------------------------------------- */

static void gn__send_raw(gn_client *c, const char *line) {
    size_t len = strlen(line), sent = 0;
    if (!c->connected) return;
    while (sent < len) {
        int n = (int)send(c->fd, line + sent, (int)(len - sent), 0);
        if (n > 0) {
            sent += (size_t)n;
        } else if (n < 0 && GN_WOULDBLOCK) {
            continue; /* the daemon reads promptly; these are tiny */
        } else {
            c->connected = 0;
            return;
        }
    }
}

static void gn__sendf(gn_client *c, const char *fmt, ...) {
    char line[1024];
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = vsnprintf(line, sizeof(line) - 2, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    line[sizeof(line) - 2] = '\0';
    strcat(line, "\n");
    gn__send_raw(c, line);
}

gn_result gn_connect(gn_client *c, const char *addr, const char *game_id,
                     const char *token) {
    char host[128], *colon;
    const char *port = "7912";
    struct addrinfo hints, *res = NULL;
    int fd;

    memset(c, 0, sizeof(*c));
    c->fd = -1;
    snprintf(c->game_id, sizeof(c->game_id), "%s", game_id ? game_id : "");

#ifdef _WIN32
    {
        WSADATA wsa;
        WSAStartup(MAKEWORD(2, 2), &wsa);
    }
#endif

    snprintf(host, sizeof(host), "%s", addr ? addr : "127.0.0.1:7912");
    colon = strrchr(host, ':');
    if (colon) {
        *colon = '\0';
        port = colon + 1;
    }

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &res) != 0 || !res)
        return GN_ERR_CONNECT;

    fd = (int)socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(res);
        return GN_ERR_SOCKET;
    }
    if (connect(fd, res->ai_addr, (int)res->ai_addrlen) != 0) {
        freeaddrinfo(res);
        GN_CLOSE(fd);
        return GN_ERR_CONNECT;
    }
    freeaddrinfo(res);

    /* Nagle would sit on our tiny `ready` for 40ms; that is the one message
     * the whole party is waiting on. */
    {
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, (const char *)&one,
                   sizeof(one));
    }
#ifdef _WIN32
    {
        u_long nb = 1;
        ioctlsocket(fd, FIONBIO, &nb);
    }
#else
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
#endif

    c->fd = fd;
    c->connected = 1;

    if (token && *token)
        gn__sendf(c,
                  "{\"type\":\"hello\",\"role\":\"game\",\"game\":\"%s\","
                  "\"token\":\"%s\"}",
                  c->game_id, token);
    else
        gn__sendf(c, "{\"type\":\"hello\",\"role\":\"game\",\"game\":\"%s\"}",
                  c->game_id);

    return c->connected ? GN_OK : GN_ERR_HANDSHAKE;
}

gn_result gn_connect_from_env(gn_client *c, const char *fallback_game_id) {
    const char *on = getenv("GAMENIGHT");
    const char *addr = getenv("GAMENIGHT_ADDR");
    const char *id = getenv("GAMENIGHT_GAME_ID");
    const char *token = getenv("GAMENIGHT_TOKEN");
    if (!on || strcmp(on, "1") != 0) {
        memset(c, 0, sizeof(*c));
        c->fd = -1;
        return GN_ERR_NOT_LAUNCHED;
    }
    return gn_connect(c, addr ? addr : "127.0.0.1:7912",
                      id ? id : fallback_game_id, token);
}

/* ---- decoding ---------------------------------------------------------- */

static gn_occupant gn__occupant(const gn_doc *d, int tok) {
    if (gn__streq(d, tok, "local")) return GN_LOCAL;
    if (gn__streq(d, tok, "remote")) return GN_REMOTE;
    if (gn__streq(d, tok, "ai")) return GN_AI;
    return GN_EMPTY;
}

static void gn__decode(const char *line, gn_event *ev) {
    static gn_doc doc; /* one message at a time; keeps gn_client small */
    int type, i;

    memset(ev, 0, sizeof(*ev));
    ev->type = GN_UNKNOWN;
    if (gn__parse(&doc, line) < 0) return;

    type = gn__get(&doc, 0, "type");
    if (type < 0) return;
    gn__str(&doc, gn__get(&doc, 0, "session"), ev->session, sizeof(ev->session));

    if (gn__streq(&doc, type, "welcome")) {
        int pv = gn__get(&doc, 0, "protocol_version");
        char n[16];
        ev->type = GN_WELCOME;
        gn__str(&doc, pv, n, sizeof(n));
        ev->protocol_version = atoi(n);
    } else if (gn__streq(&doc, type, "start")) {
        ev->type = GN_START;
    } else if (gn__streq(&doc, type, "pause")) {
        ev->type = GN_PAUSE;
    } else if (gn__streq(&doc, type, "resume")) {
        ev->type = GN_RESUME;
    } else if (gn__streq(&doc, type, "dispose")) {
        ev->type = GN_DISPOSE;
    } else if (gn__streq(&doc, type, "error")) {
        ev->type = GN_ERROR;
        gn__str(&doc, gn__get(&doc, 0, "message"), ev->message,
                sizeof(ev->message));
    } else if (gn__streq(&doc, type, "setting_changed")) {
        int v = gn__get(&doc, 0, "value");
        ev->type = GN_SETTING_CHANGED;
        gn__str(&doc, gn__get(&doc, 0, "key"), ev->key, sizeof(ev->key));
        if (v >= 0) {
            /* Hand back the raw scalar, quotes and all, so a choice setting
             * is distinguishable from a toggle that stringified. */
            int s = doc.toks[v].start, e = doc.toks[v].end;
            if (doc.toks[v].type == GN_T_STR) {
                s--;
                e++;
            }
            if (e - s < (int)sizeof(ev->value)) {
                memcpy(ev->value, doc.js + s, (size_t)(e - s));
                ev->value[e - s] = '\0';
            }
        }
    } else if (gn__streq(&doc, type, "prepare")) {
        int seats = gn__get(&doc, 0, "seats");
        int players = gn__get(&doc, 0, "players");
        ev->type = GN_PREPARE;

        ev->player_count = gn__len(&doc, players);
        if (ev->player_count > GN_MAX_PLAYERS) ev->player_count = GN_MAX_PLAYERS;
        for (i = 0; i < ev->player_count; i++) {
            int p = gn__at(&doc, players, i);
            gn__str(&doc, gn__get(&doc, p, "id"), ev->players[i].id,
                    GN_ID_LEN);
            gn__str(&doc, gn__get(&doc, p, "name"), ev->players[i].name,
                    GN_NAME_LEN);
        }

        ev->seat_count = gn__len(&doc, seats);
        if (ev->seat_count > GN_MAX_SEATS) ev->seat_count = GN_MAX_SEATS;
        for (i = 0; i < ev->seat_count; i++) {
            int s = gn__at(&doc, seats, i);
            int occ = gn__get(&doc, s, "occupant");
            char n[16];
            int j;
            gn__str(&doc, gn__get(&doc, s, "index"), n, sizeof(n));
            ev->seats[i].index = atoi(n);
            ev->seats[i].occupant = gn__occupant(&doc, gn__get(&doc, occ, "kind"));
            gn__str(&doc, gn__get(&doc, occ, "player_id"),
                    ev->seats[i].player_id, GN_ID_LEN);
            /* Resolve the name here so callers never have to join the two
             * arrays themselves — a scoreboard saying "Ada" is the point. */
            for (j = 0; j < ev->player_count; j++)
                if (ev->seats[i].player_id[0] &&
                    strcmp(ev->players[j].id, ev->seats[i].player_id) == 0) {
                    snprintf(ev->seats[i].name, GN_NAME_LEN, "%s",
                             ev->players[j].name);
                    break;
                }
        }
    }
}

int gn_poll(gn_client *c, gn_event *ev) {
    char *nl;
    if (!c->connected) return -1;

    /* Drain a complete line if we already have one buffered. */
    for (;;) {
        nl = (char *)memchr(c->buf, '\n', c->len);
        if (nl) {
            size_t used = (size_t)(nl - c->buf) + 1;
            *nl = '\0';
            if (nl > c->buf && nl[-1] == '\r') nl[-1] = '\0';
            if (c->buf[0]) {
                gn__decode(c->buf, ev);
                memmove(c->buf, c->buf + used, c->len - used);
                c->len -= used;
                return 1;
            }
            memmove(c->buf, c->buf + used, c->len - used);
            c->len -= used;
            continue; /* blank keepalive line */
        }

        if (c->len + 1 >= GN_BUF_LEN) {
            /* A message we cannot buffer is one we cannot honour. */
            c->len = 0;
            c->connected = 0;
            return -1;
        }
        {
            int n = (int)recv(c->fd, c->buf + c->len, GN_BUF_LEN - 1 - c->len, 0);
            if (n > 0) {
                c->len += (size_t)n;
                continue;
            }
            if (n == 0) { /* daemon closed: the night is over */
                c->connected = 0;
                return -1;
            }
            if (GN_WOULDBLOCK) {
                ev->type = GN_NOTHING;
                return 0;
            }
            c->connected = 0;
            return -1;
        }
    }
}

void gn_ready(gn_client *c, const char *session) {
    gn__sendf(c, "{\"type\":\"ready\",\"session\":\"%s\"}", session);
}

void gn_finished(gn_client *c, const char *session) {
    gn__sendf(c, "{\"type\":\"finished\",\"session\":\"%s\"}", session);
}

void gn_progress(gn_client *c, const char *session, int percent,
                 const char *label) {
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    if (label && *label)
        gn__sendf(c,
                  "{\"type\":\"progress\",\"session\":\"%s\",\"percent\":%d,"
                  "\"label\":\"%s\"}",
                  session, percent, label);
    else
        gn__sendf(c, "{\"type\":\"progress\",\"session\":\"%s\",\"percent\":%d}",
                  session, percent);
}

void gn_request_overlay(gn_client *c) {
    gn__sendf(c, "{\"type\":\"request_overlay\"}");
}

void gn_declare_settings(gn_client *c, const char *settings_json) {
    char line[2048];
    snprintf(line, sizeof(line) - 2,
             "{\"type\":\"declare_settings\",\"settings\":%s}", settings_json);
    strcat(line, "\n");
    gn__send_raw(c, line);
}

void gn_close(gn_client *c) {
    if (c->fd >= 0) GN_CLOSE(c->fd);
    c->fd = -1;
    c->connected = 0;
}

#endif /* GAMENIGHT_IMPLEMENTATION */
#endif /* GAMENIGHT_H */

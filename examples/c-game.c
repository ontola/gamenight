/*
 * c-game — a complete GameNight integration in C, for the engines that need
 * it most: the ones with no JSON parser and no WebSocket client.
 *
 *   cc -I sdk/c -o /tmp/c-game examples/c-game.c
 *   cargo run -p gamenight-certify -- c-game -- /tmp/c-game
 *
 * The gameplay is a five-second timer. Everything else is the real contract:
 * connect, warm on prepare, report progress while loading, start instantly,
 * finish, survive dispose, stay resident for the next session.
 */

#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#define GAMENIGHT_IMPLEMENTATION
#include "gamenight.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

#define MATCH_SECONDS 5.0

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* Stand-in for "load the level": a real game does this work for real, and
 * calls gn_progress() between chunks so the party sees a truthful bar
 * instead of a frozen screen. */
static void load_the_level(gn_client *gn, const char *session) {
    const char *steps[] = {"loading track", "spawning karts", "warming shaders"};
    int i;
    for (i = 0; i < 3; i++) {
        gn_progress(gn, session, (i + 1) * 33, steps[i]);
    }
}

int main(void) {
    gn_client gn;
    gn_event ev;
    char playing[GN_ID_LEN] = "";
    double match_ends = 0.0;
    gn_result rc = gn_connect_from_env(&gn, "c-game");

    if (rc == GN_ERR_NOT_LAUNCHED) {
        /* Nobody launched us into a party: this is where a real game boots
         * its own title screen and plays standalone. */
        printf("[c-game] no GameNight in the environment; standalone\n");
        return 0;
    }
    if (rc != GN_OK) {
        fprintf(stderr, "[c-game] could not reach the daemon (%d)\n", rc);
        return 1;
    }

    for (;;) {
        int got = gn_poll(&gn, &ev);
        if (got < 0) break; /* daemon gone: the night is over */

        if (got == 1) {
            switch (ev.type) {
            case GN_WELCOME:
                printf("[c-game] in the party (protocol v%d)\n",
                       ev.protocol_version);
                break;

            case GN_PREPARE: {
                /* Load everything for these seats. Show nothing yet. */
                int i;
                printf("[c-game] warming %s for:", ev.session);
                for (i = 0; i < ev.seat_count; i++) {
                    if (ev.seats[i].occupant == GN_EMPTY) continue;
                    printf(" %s", ev.seats[i].name[0] ? ev.seats[i].name
                                                      : "a bot");
                }
                printf("\n");
                load_the_level(&gn, ev.session);
                gn_ready(&gn, ev.session); /* a promise, not a status */
                break;
            }

            case GN_START:
                snprintf(playing, sizeof(playing), "%s", ev.session);
                match_ends = now_seconds() + MATCH_SECONDS;
                printf("[c-game] GO\n");
                break;

            case GN_PAUSE:
                printf("[c-game] paused\n");
                match_ends += 1e9; /* frozen: no clock while the party is up */
                break;

            case GN_RESUME:
                printf("[c-game] resumed\n");
                match_ends -= 1e9;
                break;

            case GN_DISPOSE:
                /* Tear down and go back to waiting. Do not exit. */
                printf("[c-game] disposed, back to the bench\n");
                playing[0] = '\0';
                break;

            case GN_ERROR:
                fprintf(stderr, "[c-game] daemon says: %s\n", ev.message);
                break;

            default:
                break; /* forward compatibility: ignore what we don't know */
            }
        }

        if (playing[0] && now_seconds() >= match_ends) {
            printf("[c-game] match over\n");
            gn_finished(&gn, playing);
            playing[0] = '\0'; /* keep rendering the scoreboard until dispose */
        }

        if (got == 0) {
            struct timespec nap = {0, 2 * 1000 * 1000}; /* 2ms, ~a frame */
            nanosleep(&nap, NULL);
        }
    }

    gn_close(&gn);
    printf("[c-game] good night\n");
    return 0;
}

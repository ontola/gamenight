// SPDX-License-Identifier: LGPL-2.1-or-later
#include "gamenight_controller.h"
#include <cassert>
#include <thread>
#include <cstdio>
#include <iostream>
int main(int argc,char **argv) {
    assert(argc==2);
#ifdef _WIN32
    _putenv_s("GAMENIGHT_CONTROLLER_FRAME",argv[1]);
#else
    setenv("GAMENIGHT_CONTROLLER_FRAME",argv[1],1);
#endif
    auto write=[&](const char *line) {std::ofstream(argv[1])<<line;std::this_thread::sleep_for(std::chrono::milliseconds(8));};
    write("1 1 1 1 100 -200 300 -400 0 500");
    auto a=gamenightHostFrame();assert(a.active && a.connected && a.buttons==1 && a.axes[1]==-200);
    write("2 0 0 0 0 0 0 0 0 0");
    auto b=gamenightHostFrame();assert(!b.active && !b.connected && b.buttons==0);
    write("3 1 1 128 0 0 0 0 0 0");
    assert(gamenightHostFrame().active);
    write("4 1 1 128 65535 0 0 0 0 0"); // invalid range cannot replace state
    assert(gamenightHostFrame().sequence==3);
    write("2 1 1 128 0 0 0 0 0 0"); // reordered frame cannot renew lease
    assert(gamenightHostFrame().sequence==3);
    std::this_thread::sleep_for(std::chrono::milliseconds(270));
    auto stale=gamenightHostFrame();assert(!stale.connected && stale.buttons==0 && stale.active);
    std::this_thread::sleep_for(std::chrono::milliseconds(1800));
    assert(!gamenightHostFrame().active);
    std::remove(argv[1]);
    std::cout<<"Host-frame validation, ordering and fail-safe expiry passed\n";
}

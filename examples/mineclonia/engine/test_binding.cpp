// SPDX-License-Identifier: LGPL-2.1-or-later
#include "gamenight_controller.h"
#include <cassert>
#include <iostream>
int main() {
    GameNightControllerBinding a, b;
    a.path="pad-a"; b.path="pad-b";
    assert(!a.attach(8,"pad-b",true));
    assert(a.attach(17,"pad-a",false));
    assert(b.attach(8,"pad-b",true));
    assert(!a.accept(8,true)); assert(b.accept(8,false));
    assert(!a.accept(17,false)); // held during connection
    assert(!a.accept(17,true)); // neutral arms without firing
    assert(a.accept(17,false));
    assert(!a.attach(99,"pad-a",true)); // no duplicate binding
    assert(!a.detach(8)); assert(a.accept(17,false));
    assert(a.detach(17)); assert(!a.accept(17,true));
    assert(!a.attach(17,"pad-b",true)); // never borrow another pad
    assert(a.attach(51,"pad-a",false)); // new instance after reconnect
    assert(!a.accept(17,true)); assert(!a.accept(51,false));
    assert(!a.accept(51,true)); assert(a.accept(51,false));
    assert(b.accept(8,false));
    std::cout << "Controller isolation, release and reconnect policy passed\n";
}

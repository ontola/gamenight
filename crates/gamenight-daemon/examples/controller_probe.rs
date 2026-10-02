//! Read-only hardware diagnostic. Never binds players or injects input.
fn main() {
    let mut input = gilrs::Gilrs::new().expect("controller backend");
    for (id, pad) in input.gamepads() {
        println!("Connected {:?}: {}", id, pad.name());
    }
    let until = std::time::Instant::now() + std::time::Duration::from_secs(8);
    while std::time::Instant::now() < until {
        while let Some(event) = input.next_event() {
            println!("{event:?}");
        }
        input.inc();
        std::thread::sleep(std::time::Duration::from_millis(16));
    }
}

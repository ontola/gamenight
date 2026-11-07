fn main() {
    println!("cargo:rerun-if-changed=branding/gamenight.ico");
    #[cfg(windows)]
    {
        winres::WindowsResource::new()
            .set_icon("branding/gamenight.ico")
            .set("ProductName", "Gamepad Party")
            .set("FileDescription", "Gamepad Party")
            .set("InternalName", "GameNight")
            .set("CompanyName", "Ontola")
            .compile()
            .expect("compile Gamepad Party Windows branding");
        // The launcher links the daemon library for local shelf loading. Cargo
        // carries its native branding resource; linking it twice duplicates VERSION.
    }
}

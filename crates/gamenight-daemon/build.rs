fn main() {
    println!("cargo:rerun-if-changed=../lobby/branding/gamenight.ico");
    #[cfg(windows)]
    {
        winres::WindowsResource::new()
            .set_icon("../lobby/branding/gamenight.ico")
            .set("ProductName", "GameNight")
            .set("FileDescription", "GameNight")
            .set("InternalName", "GameNight")
            .set("CompanyName", "Ontola")
            .compile()
            .expect("compile GameNight Windows branding");
        // The launcher links the daemon library for local shelf loading. Cargo
        // carries its native branding resource; linking it twice duplicates VERSION.
    }
}

fn main() -> shadow_rs::SdResult<()> {
    println!("cargo:rerun-if-changed=branding/gamenight.ico");
    #[cfg(windows)]
    {
        winres::WindowsResource::new()
            .set_icon("branding/gamenight.ico")
            .set("ProductName", "GameNight")
            .set("FileDescription", "GameNight")
            .set("InternalName", "GameNight Lobby")
            .compile()
            .expect("compile GameNight Windows branding");
    }
    shadow_rs::new()
}

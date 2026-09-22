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
        // The standalone launcher does not link the daemon library, so Cargo's
        // native-library metadata alone does not carry its resource into the EXE.
        #[cfg(target_env = "msvc")]
        println!(
            "cargo:rustc-link-arg-bin=gamenight-launcher={}/resource.lib",
            std::env::var("OUT_DIR").unwrap()
        );
    }
}

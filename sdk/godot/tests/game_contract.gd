extends SceneTree
var failed := false
func _initialize(): call_deferred("run")
func check(ok: bool, label: String):
	if not ok: failed=true; push_error(label)
func run():
	var sdk = load("res://addons/gamenight/gamenight.gd").new()
	sdk.game_id="test"
	sdk._handle({"type":"prepare","game":"test","session":"s1","seats":[{"index":0,"controller":"pad:B"},{"index":1,"controller":"pad:A"}],"players":[]})
	sdk.notify_ready("s1")
	sdk._handle({"type":"start","session":"s1"})
	sdk._handle({"type":"controller_frame","controllers":[{"controller":"pad:A","axes":[32767,0,0,0,0,0],"buttons":4},{"controller":"pad:B","axes":[-32767,0,0,0,0,0],"buttons":1}]})
	check(sdk.axis(sdk.frame_for_seat(0),0)==-1.,"seat 0 follows its opaque token, not enumeration")
	check(sdk.button(sdk.frame_for_seat(1),2),"seat 1 gets its own buttons")
	sdk._handle({"type":"pause","session":"stale"})
	check(sdk.phase=="running","stale lifecycle rejected")
	sdk._handle({"type":"pause","session":"s1"})
	check(sdk.frame_for_seat(0).is_empty(),"pause yields neutral input")
	sdk._handle({"type":"resume","session":"s1"})
	sdk._handle({"type":"party_updated","session":"s1","seats":[{"index":0,"controller":"pad:A"}],"players":[{"name":"Updated"}],"presence":[]})
	check(sdk.axis(sdk.frame_for_seat(0),0)==1.,"live seat changes remap immediately")
	check(sdk.party.players[0].name=="Updated","live profiles delivered")
	sdk._frame_at=Time.get_ticks_msec()-251
	check(sdk.frame_for_seat(0).is_empty(),"lost input times out")
	sdk._handle({"type":"dispose","session":"s1"})
	check(sdk.session.is_empty() and sdk.phase=="idle","dispose clears session")
	sdk.free()
	var screen = load("res://addons/gamenight/screen.gd").new()
	screen._on_focus_in()
	check(screen._epoch==0,"focus has no lifecycle side effect")
	screen.free()
	var art = load("res://addons/gamenight/artwork.gd").new()
	root.add_child(art)
	var base: String = OS.get_environment("ART_TEST_URL")
	check(art.texture(base+"/cover.png")==null,"remote artwork does not block")
	art.texture(base+"/missing.png")
	var deadline := Time.get_ticks_msec()+8000
	while (not art.cache.has(base+"/cover.png") or not art.cache.has(base+"/missing.png")) and Time.get_ticks_msec()<deadline:
		await create_timer(.02).timeout
	check(art.texture(base+"/cover.png")!=null,"HTTP artwork appears after loading")
	check(art.cache.has(base+"/missing.png") and art.texture(base+"/missing.png")==null,"failed download caches title fallback")
	art.queue_free()
	print("GAME_SDK_PASS" if not failed else "GAME_SDK_FAIL")
	quit(1 if failed else 0)
